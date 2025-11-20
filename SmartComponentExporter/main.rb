# encoding: UTF-8
require 'sketchup.rb'
require 'fileutils'
require 'json'

module SmartComponentExporter
  PLUGIN_NAME        = "Smart Component Exporter"
  ATTR_KEY           = "SaveOut"
  ATTR_PATH          = "file_path"
  SOURCE_FOLDER_NAME = "kaynak"
  BACKUP_FOLDER_NAME = "yedek"
  NOTES_DICT         = "SCE_NOTES"
  CONFIG_DICT        = "SCE_CONFIG"

  extend self

  # ---------------- Settings on model (persistent with SKP) ----------------
  def read_setting(key); Sketchup.active_model.get_attribute(CONFIG_DICT, key, "").to_s; end
  def write_setting(key, value); Sketchup.active_model.set_attribute(CONFIG_DICT, key, value.to_s); end
  def read_all_settings
    { render_path: read_setting("render_path"),
      offer_path: read_setting("offer_path"),
      project_path: read_setting("project_path") }
  end

  # ---------------- Open in OS (like Smart Notes) ----------------
  def to_file_uri(path)
    s = path.to_s
    if Sketchup.platform == :platform_win
      if s.start_with?('\\\\')
        "file:" + s.gsub("\\\\", "/")
      else
        "file:///" + s.gsub("\\\\", "/")
      end
    else
      "file://" + s
    end
  end

  def open_path_with_system(path, reveal: false)
    s = path.to_s
    return if s.strip.empty?
    if s.start_with?('http://','https://')
      UI.openURL(s); return
    end
    if Sketchup.platform == :platform_win
      if reveal
        safe = s.gsub('"','\\"')
        if File.exist?(s) && !File.directory?(s)
          system(%Q{explorer.exe /select,"%s"} % safe)
        else
          system(%Q{explorer.exe "%s"} % safe)
        end
      else
        UI.openURL(to_file_uri(s))
      end
    else
      UI.openURL(to_file_uri(s))
    end
  end

  # ---------------- FS helpers ----------------
  def model_directory(model)
    return nil if model.path.to_s.empty?
    File.dirname(model.path)
  end

  def source_dir_for_model(model)
    dir = model_directory(model)
    return nil unless dir
    File.join(dir, SOURCE_FOLDER_NAME)
  end

  def ensure_source_dir(model)
    source_dir = source_dir_for_model(model)
    return nil unless source_dir
    begin
      Dir.mkdir(source_dir) unless Dir.exist?(source_dir)
    rescue => e
      UI.messagebox("⚠ Kaynak klasörü oluşturulamadı:\n#{e.message}")
    end
    source_dir
  end

  def backup_path_for(file_path)
    dir        = File.dirname(file_path)
    backup_dir = File.join(dir, BACKUP_FOLDER_NAME)
    File.join(backup_dir, File.basename(file_path))
  end

  def ensure_backup_dir_for(file_path)
    backup_dir = File.dirname(backup_path_for(file_path))
    FileUtils.mkdir_p(backup_dir) unless Dir.exist?(backup_dir)
    backup_dir
  end

  def save_definition_with_backup(definition, file_path, backup_before: false)
    if backup_before && File.exist?(file_path)
      begin
        ensure_backup_dir_for(file_path)
        FileUtils.cp(file_path, backup_path_for(file_path))
      rescue => e
        puts "Yedek alınamadı: #{e.message}"
      end
    end

    definition.save_as(file_path)

    unless backup_before
      begin
        ensure_backup_dir_for(file_path)
        FileUtils.cp(file_path, backup_path_for(file_path))
      rescue => e
        puts "İlk yedek oluşturulamadı: #{e.message}"
      end
    end
  end

  def format_time_tr(time)
    days = %w[Pazar Pazartesi Salı Çarşamba Perşembe Cuma Cumartesi]
    day_name = days[time.wday]
    time.strftime("%Y-%m-%d %H:%M ") + day_name
  end

  def find_definition_by_path(file_path)
    Sketchup.active_model.definitions.to_a.find { |d| d.get_attribute(ATTR_KEY, ATTR_PATH) == file_path }
  end

  # ---------------- Notes key (definition-tied if possible) ----------------
  def note_key_for(file_path)
    path = file_path.to_s
    return "" if path.empty?
    defn = find_definition_by_path(path)
    if defn && defn.respond_to?(:persistent_id)
      "def:#{defn.persistent_id}"
    else
      path
    end
  end

  # ---------------- TSN auto-attach ----------------
  def auto_attach_tsn_components(model)
    source_dir = ensure_source_dir(model)
    return unless source_dir && !source_dir.to_s.strip.empty?
    files = Dir.glob(File.join(source_dir, "TSN*.skp"))
    return if files.empty?
    defs = model.definitions.to_a
    files.each do |fp|
      base = File.basename(fp, ".skp")
      d = defs.find { |x| x.name.to_s == base }
      next unless d
      cur = d.get_attribute(ATTR_KEY, ATTR_PATH).to_s.strip
      next unless cur.empty?
      d.set_attribute(ATTR_KEY, ATTR_PATH, fp) rescue nil
    end
  end

  # ---------------- Note counts ----------------
  def get_note_counts
    counts = {}
    model = Sketchup.active_model
    model.definitions.to_a.each do |d|
      file_path = d.get_attribute(ATTR_KEY, ATTR_PATH)
      next if !file_path || file_path.to_s.strip.empty?
      notes = read_notes_for(file_path)
      counts[file_path] = notes.length if notes.length > 0
    end
    counts
  end

  # ---------------- Panel list ----------------
  def list_source_components
    model = Sketchup.active_model
    auto_attach_tsn_components(model) rescue nil
    entries, seen = [], {}
    note_counts = get_note_counts
    model.definitions.to_a.each do |d|
      file_path = d.get_attribute(ATTR_KEY, ATTR_PATH)
      next if !file_path || file_path.to_s.strip.empty?
      next if seen[file_path]
      next unless File.exist?(file_path)
      stat = File.stat(file_path) rescue nil
      base = File.basename(file_path, ".skp")
      name = d.name.to_s.strip.empty? ? base : d.name
      entries << { name: name, file_path: file_path,
                   updated_at: (stat ? format_time_tr(stat.mtime) : ""),
                   backup_exists: File.exist?(backup_path_for(file_path)),
                   note_count: note_counts[file_path] || 0 }
      seen[file_path] = true
    end
    entries.sort_by { |e| e[:name].downcase }
  end

  # ---------------- Ops by path ----------------
  def update_component_by_path(file_path)
    d = find_definition_by_path(file_path)
    return UI.messagebox("⚠ Bu dosyaya bağlı bileşen sahnede bulunamadı.\n#{file_path}") unless d
    save_definition_with_backup(d, file_path, backup_before: File.exist?(file_path))
    UI.messagebox("✔ Güncellendi: #{file_path}")
    refresh_panel_if_open
  rescue => e
    UI.messagebox("❌ Hata: #{e.message}")
  end

  def reload_component_by_path(file_path)
    model = Sketchup.active_model
    d = find_definition_by_path(file_path)
    return UI.messagebox("⚠ Bu dosyaya bağlı bileşen sahnede bulunamadı.\n#{file_path}") unless d
    inst = model.entities.grep(Sketchup::ComponentInstance).find { |i| i.definition == d } ||
           model.active_entities.grep(Sketchup::ComponentInstance).find { |i| i.definition == d }
    return UI.messagebox("⚠ Bu bileşenden sahnede örnek bulunamadı.") unless inst
    reload_component(inst)
    refresh_panel_if_open
  end

  def restore_backup_file(file_path)
    b = backup_path_for(file_path)
    return UI.messagebox("⚠ Yedek dosya bulunamadı.\n#{b}") unless File.exist?(b)
    ensure_backup_dir_for(file_path)
    FileUtils.cp(b, file_path)
    UI.messagebox("✔ Yedekten geri yüklendi: #{file_path}")
    refresh_panel_if_open
  rescue => e
    UI.messagebox("❌ Yedekten geri yükleme hatası: #{e.message}")
  end

  def open_component_file_by_path(file_path)
    return UI.messagebox("⚠ Dosya yolu tanımlı değil.") if file_path.to_s.strip.empty?
    open_path_with_system(file_path)
  end

  def parse_payload(p)
    return {} unless p
    return JSON.parse(p) rescue {} if p.is_a?(String)
    p.is_a?(Hash) ? p : {}
  end

  # ---------------- Notes ----------------
  def read_notes_for(file_path)
    key = note_key_for(file_path)
    return [] if key.empty?
    raw = Sketchup.active_model.get_attribute(NOTES_DICT, key)
    return [] unless raw.is_a?(String) && !raw.empty?
    JSON.parse(raw) rescue []
  end

  def write_notes_for(file_path, arr)
    key = note_key_for(file_path); return if key.empty?
    Sketchup.active_model.set_attribute(NOTES_DICT, key, JSON.generate(arr))
  end

  def append_note_for(file_path, text)
    t = text.to_s.strip; return [] if t.empty?
    arr = read_notes_for(file_path)
    arr.unshift({ "text" => t, "at" => format_time_tr(Time.now) })
    write_notes_for(file_path, arr)
    arr
  end

  def update_note_for(file_path, idx, text)
    arr = read_notes_for(file_path)
    i = idx.to_i
    return arr unless i >= 0 && i < arr.length
    arr[i]["text"] = text.to_s
    write_notes_for(file_path, arr)
    arr
  end

  def show_notes_dialog(file_path, name)
    file_path = file_path.to_s; return if file_path.empty?
    title = name.to_s.strip; title = "Notlar" if title.empty?
    @notes_dialog = UI::HtmlDialog.new(
      dialog_title: "Notlar — #{title}", preferences_key: "SmartComponentExporterNotes",
      scrollable: true, resizable: true, width: 480, height: 520, style: UI::HtmlDialog::STYLE_DIALOG
    )
    html = <<-HTML
<!doctype html><html lang="tr"><head><meta charset="utf-8">
<title>Notlar</title>
<style>
 body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;background:#fff;color:#111827}
 .wrap{display:flex;flex-direction:column;height:100vh;padding:10px 12px;box-sizing:border-box}
 .header{font-size:13px;font-weight:600;margin-bottom:6px}
 .list{flex:1;overflow:auto;display:flex;flex-direction:column;gap:6px;border:1px solid #e5e7eb;border-radius:8px;padding:8px;background:#fafafa}
 .note{border:1px solid #e5e7eb;border-radius:6px;padding:6px 8px;background:#fff}
 .meta{font-size:10px;color:#6b7280;margin-top:2px;display:flex;justify-content:space-between;align-items:center}
 .empty{font-size:12px;color:#9ca3af}
 .row{display:flex;gap:6px;margin-top:8px}
 .row input{flex:1;padding:6px 8px;border:1px solid #d1d5db;border-radius:8px;font-size:12px}
 .row button{padding:6px 12px;border:none;border-radius:999px;background:#4c1d95;color:#fff;font-size:12px;cursor:pointer}
 .row button:hover{opacity:.95}
</style></head><body>
<div class="wrap">
  <div class="header">Notlar</div>
  <div id="list" class="list"><div class="empty">Henüz not yok.</div></div>
  <div class="row">
    <input id="inp" type="text" placeholder="Yeni not yazın..." />
    <button onclick="onSave()">Kaydet</button>
  </div>
</div>
<script>
 var PATH=null, EDIT=null;
 function bridge(n,p){ 
   console.log('bridge call:', n, p);
   if(window.sketchup&&window.sketchup[n]){ 
     try{ 
       window.sketchup[n](JSON.stringify(p||{})); 
     }catch(e){
       console.error('bridge error:', e);
     } 
   } 
 }
 function render(arr){
   console.log('render called with', arr);
   var list = document.getElementById('list'); list.innerHTML='';
   if(!arr||!arr.length){ list.innerHTML='<div class="empty">Henüz not yok.</div>'; return; }
   arr.forEach(function(n,i){
     var d=document.createElement('div'); d.className='note';
     d.innerHTML='<div>'+ (n.text||'') +'</div><div class="meta"><span>'+(n.at||'')+'</span><a href="#" data-i="'+i+'">Düzenle</a></div>';
     d.querySelector('a').addEventListener('click', function(ev){ ev.preventDefault(); var i=+this.dataset.i; var inp=document.getElementById('inp'); inp.value=(arr[i].text||''); inp.focus(); EDIT=i; console.log('Edit mode:', i); });
     list.appendChild(d);
   });
 }
 window.NOTES_setData=function(payload){
   console.log('NOTES_setData called with:', payload);
   try{ if(typeof payload==='string') payload=JSON.parse(payload); }catch(e){ console.error('parse error:', e); return; }
   PATH = payload.file_path || null;
   console.log('PATH set to:', PATH);
   render(payload.notes||[]);
 };
 function onSave(){
   console.log('onSave called, PATH:', PATH, 'EDIT:', EDIT);
   var inp=document.getElementById('inp'); if(!inp||!PATH) return;
   var t=(inp.value||'').trim(); if(!t) return;
   if(EDIT==null){ 
     console.log('Adding new note:', t);
     bridge('add_note', {file_path: PATH, text: t}); 
   }
   else{ 
     console.log('Updating note at index:', EDIT, 'with text:', t);
     bridge('update_note', {file_path: PATH, index: EDIT, text: t}); 
     EDIT=null; 
   }
   inp.value=''; inp.focus();
 }
 document.addEventListener('DOMContentLoaded', function(){ console.log('DOM ready, requesting notes data'); bridge('request_notes_data', {}); });
</script>
</body></html>
    HTML
    @notes_dialog.set_html(html)
    @notes_dialog.add_action_callback("request_notes_data"){ |dlg,_|
      puts "DEBUG: request_notes_data called for #{file_path}"
      payload = { file_path: file_path, name: name.to_s, notes: read_notes_for(file_path) }
      puts "DEBUG: Sending notes payload: #{payload.inspect}"
      dlg.execute_script("window.NOTES_setData(#{JSON.generate(payload)})")
    }
    @notes_dialog.add_action_callback("add_note"){ |dlg,p|
      puts "DEBUG: add_note called with payload: #{p}"
      d = parse_payload(p)
      arr = append_note_for(file_path, d["text"].to_s)
      puts "DEBUG: Note added, new array length: #{arr.length}"
      dlg.execute_script("window.NOTES_setData(#{JSON.generate({file_path: file_path, name: name.to_s, notes: arr})})")
      refresh_panel_if_open
    }
    @notes_dialog.add_action_callback("update_note"){ |dlg,p|
      puts "DEBUG: update_note called with payload: #{p}"
      d = parse_payload(p)
      arr = update_note_for(file_path, d["index"].to_i, d["text"].to_s)
      puts "DEBUG: Note updated, array length: #{arr.length}"
      dlg.execute_script("window.NOTES_setData(#{JSON.generate({file_path: file_path, name: name.to_s, notes: arr})})")
      refresh_panel_if_open
    }
    @notes_dialog.show
  end

  # ---------------- Panel data push ----------------
  def send_panel_data(dialog)
    dialog.execute_script("window.SMART_EXPORTER_setData(#{JSON.generate(list_source_components)})")
    dialog.execute_script("window.SMART_EXPORTER_setSettings(#{JSON.generate(read_all_settings)})")
  end

  def refresh_panel_if_open
    return unless defined?(@source_panel_dialog) && @source_panel_dialog && @source_panel_dialog.visible?
    send_panel_data(@source_panel_dialog)
  end

  def show_source_panel
    model = Sketchup.active_model
    return UI.messagebox("Önce modeli kaydedin.\nKaynak klasörü, model dosyasının yanında oluşturulacaktır.") if model.path.to_s.empty?
    if defined?(@source_panel_dialog) && @source_panel_dialog && @source_panel_dialog.visible?
      @source_panel_dialog.bring_to_front; return
    end
    @source_panel_dialog = UI::HtmlDialog.new(dialog_title: "Smart Component Exporter — Kaynak Paneli",
      preferences_key: "SmartComponentExporterSourcePanel", scrollable: true, resizable: true, width: 820, height: 460, style: UI::HtmlDialog::STYLE_DIALOG)
    html_path = File.join(File.dirname(__FILE__), "panel.html")
    html = File.exist?(html_path) ? File.read(html_path, encoding: "UTF-8") : "<html><body><p>panel.html bulunamadı.</p></body></html>"
    @source_panel_dialog.set_html(html)

    @source_panel_dialog.add_action_callback("request_data"){ |d,_| send_panel_data(d) }
    @source_panel_dialog.add_action_callback("update_from_panel"){ |d,p| h=parse_payload(p); update_component_by_path(h["file_path"]) if h["file_path"] }
    @source_panel_dialog.add_action_callback("reload_from_panel"){ |d,p| h=parse_payload(p); reload_component_by_path(h["file_path"]) if h["file_path"] }
    @source_panel_dialog.add_action_callback("restore_backup"){ |d,p| h=parse_payload(p); restore_backup_file(h["file_path"]) if h["file_path"] }
    @source_panel_dialog.add_action_callback("open_from_panel"){ |d,p| h=parse_payload(p); open_component_file_by_path(h["file_path"]) if h["file_path"] }
    @source_panel_dialog.add_action_callback("open_notes"){ |d,p| h=parse_payload(p); show_notes_dialog(h["file_path"].to_s, h["name"].to_s) }

    # --- FIX: Project path must be a FOLDER picker (UI.select_directory) ---
    @source_panel_dialog.add_action_callback("choose_project_path"){ |d,_|
      puts "DEBUG: choose_project_path called"
      folder = UI.select_directory("Proje klasörünü seç")
      if folder
        puts "DEBUG: Selected project folder: #{folder}"
        write_setting("project_path", folder)
        settings = read_all_settings
        puts "DEBUG: Sending settings: #{settings.inspect}"
        d.execute_script("window.SMART_EXPORTER_setSettings(#{JSON.generate(settings)})")
      end
    }
    @source_panel_dialog.add_action_callback("choose_render_path"){ |d,_|
      puts "DEBUG: choose_render_path called"
      default_dir = File.dirname(Sketchup.active_model.path) rescue Dir.home
      existing = read_setting("render_path")
      default_dir = File.dirname(existing) if !existing.to_s.empty? && File.exist?(File.dirname(existing))
      file = UI.openpanel("Render dosyasını seç", default_dir, "Tüm Dosyalar|*.*||")
      if file
        puts "DEBUG: Selected render file: #{file}"
        write_setting("render_path", file)
        settings = read_all_settings
        puts "DEBUG: Sending settings: #{settings.inspect}"
        d.execute_script("window.SMART_EXPORTER_setSettings(#{JSON.generate(settings)})")
      end
    }
    @source_panel_dialog.add_action_callback("choose_offer_path"){ |d,_|
      puts "DEBUG: choose_offer_path called"
      default_dir = File.dirname(Sketchup.active_model.path) rescue Dir.home
      existing = read_setting("offer_path")
      default_dir = File.dirname(existing) if !existing.to_s.empty? && File.exist?(File.dirname(existing))
      file = UI.openpanel("Teklif dosyasını seç", default_dir, "Tüm Dosyalar|*.*||")
      if file
        puts "DEBUG: Selected offer file: #{file}"
        write_setting("offer_path", file)
        settings = read_all_settings
        puts "DEBUG: Sending settings: #{settings.inspect}"
        d.execute_script("window.SMART_EXPORTER_setSettings(#{JSON.generate(settings)})")
      end
    }

    @source_panel_dialog.add_action_callback("open_render_target"){ |d,_|
      p = read_setting("render_path"); p.to_s.empty? ? UI.messagebox("Render dosyası ayarlardan seçilmemiş.") : open_path_with_system(p)
    }
    @source_panel_dialog.add_action_callback("open_offer_target"){ |d,_|
      p = read_setting("offer_path"); p.to_s.empty? ? UI.messagebox("Teklif dosyası ayarlardan seçilmemiş.") : open_path_with_system(p)
    }
    @source_panel_dialog.add_action_callback("open_project_folder"){ |d,_|
      p = read_setting("project_path"); p.to_s.empty? ? UI.messagebox("Proje klasörü ayarlardan seçilmemiş.") : open_path_with_system(p)
    }

    @source_panel_dialog.show
    UI.start_timer(0.1, false){ send_panel_data(@source_panel_dialog) if @source_panel_dialog && @source_panel_dialog.visible? }
  end

  # ---------------- Component ops ----------------
  def export_component(inst)
    d = inst.definition
    file_path = d.get_attribute(ATTR_KEY, ATTR_PATH)
    unless file_path && File.exist?(file_path)
      name = d.name.empty? ? "Component" : d.name
      default_dir = ensure_source_dir(Sketchup.active_model) || (Sketchup.active_model.path.to_s.empty? ? Dir.home : File.dirname(Sketchup.active_model.path))
      file_path = UI.savepanel("Bileşeni Kaydet (.skp)", default_dir, "#{name}.skp")
      return unless file_path
      file_path += ".skp" unless file_path.downcase.end_with?(".skp")
      d.set_attribute(ATTR_KEY, ATTR_PATH, file_path)
    end
    save_definition_with_backup(d, file_path, backup_before: false)
    UI.messagebox("✔ Kaydedildi: #{file_path}")
    refresh_panel_if_open
  rescue => e
    UI.messagebox("❌ Hata: #{e.message}")
  end

  def update_component(inst)
    d = inst.definition
    file_path = d.get_attribute(ATTR_KEY, ATTR_PATH)
    return UI.messagebox("⚠ Bileşen daha önce dışa aktarılmamış.") unless file_path
    save_definition_with_backup(d, file_path, backup_before: File.exist?(file_path))
    UI.messagebox("✔ Güncellendi: #{file_path}")
    refresh_panel_if_open
  rescue => e
    UI.messagebox("❌ Hata: #{e.message}")
  end

  def reload_component(inst)
    d = inst.definition
    file_path = d.get_attribute(ATTR_KEY, ATTR_PATH)
    return UI.messagebox("⚠ Dosya bulunamadı. Lütfen önce kaydedin.") unless file_path && File.exist?(file_path)
    model = Sketchup.active_model
    new_def = model.definitions.load(file_path)
    if new_def
      t = inst.transformation
      layer = inst.layer
      model.entities.erase_entities(inst) rescue inst.erase! rescue nil
      new_inst = model.active_entities.add_instance(new_def, t)
      new_inst.layer = layer
      UI.messagebox("🔄 Yeniden yüklendi: #{file_path}")
      refresh_panel_if_open
    else
      UI.messagebox("❌ Yeniden yükleme başarısız.")
    end
  rescue => e
    UI.messagebox("❌ Hata: #{e.message}")
  end

  def open_component_file(inst)
    file_path = inst.definition.get_attribute(ATTR_KEY, ATTR_PATH)
    return UI.messagebox("⚠ Dosya bulunamadı.") if file_path.to_s.strip.empty?
    open_component_file_by_path(file_path)
  end

  def show_info
    UI.messagebox("Smart Component Exporter — Notlar tanımı bileşen (definition) bazlıdır. © Ozan")
  end

  # ---------------- UI wiring ----------------
  def context_menu_handler(menu)
    sel = Sketchup.active_model.selection
    if sel.count == 1 && sel.first.is_a?(Sketchup::ComponentInstance)
      menu.add_separator
      menu.add_item("🗂 Hazırla ve Kaydet"){ export_component(sel.first) }
      menu.add_item("💾 Güncelle"){ update_component(sel.first) }
      menu.add_item("🔄 Yeniden Yükle"){ reload_component(sel.first) }
      menu.add_item("📂 Modeli Aç"){ open_component_file(sel.first) }
    end
    menu.add_separator
    menu.add_item("📋 Kaynak Paneli"){ show_source_panel }
  end

  def add_menu_and_toolbar
    UI.add_context_menu_handler { |m| context_menu_handler(m) }
    submenu = UI.menu("Plugins").add_submenu(PLUGIN_NAME)
    {
      "🗂 Hazırla ve Kaydet" => :export_component,
      "💾 Güncelle"         => :update_component,
      "🔄 Yeniden Yükle"    => :reload_component,
      "📂 Modeli Aç"        => :open_component_file,
      "📋 Kaynak Paneli"    => :show_source_panel,
      "ℹ Bilgi"             => :show_info
    }.each do |label, m|
      submenu.add_item(label) do
        case m
        when :show_info then show_info
        when :show_source_panel then show_source_panel
        else
          sel = Sketchup.active_model.selection.first
          sel.is_a?(Sketchup::ComponentInstance) ? send(m, sel) : UI.messagebox("Bileşen seçin.")
        end
      end
    end
    tb = UI::Toolbar.new(PLUGIN_NAME)
    {
      "Hazırla ve Kaydet" => :export_component,
      "Güncelle"          => :update_component,
      "Yeniden Yükle"     => :reload_component,
      "Modeli Aç"         => :open_component_file,
      "Kaynak Paneli"     => :show_source_panel,
      "Bilgi"             => :show_info
    }.each do |name, m|
      c = UI::Command.new(name) do
        case m
        when :show_info then show_info
        when :show_source_panel then show_source_panel
        else
          sel = Sketchup.active_model.selection.first
          sel.is_a?(Sketchup::ComponentInstance) ? send(m, sel) : UI.messagebox("Bileşen seçin.")
        end
      end
      c.tooltip = name
      c.status_bar_text = name
      icon = File.join(File.dirname(__FILE__), "icons", "#{m}.png")
      c.small_icon = c.large_icon = icon
      tb.add_item(c)
    end
    tb.show
  end

  unless file_loaded?(__FILE__)
    add_menu_and_toolbar
    file_loaded(__FILE__)
  end
end
