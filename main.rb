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
  NOTES_DICT        = "SCE_NOTES"

  SETTINGS_SECTION = "SmartComponentExporter"

  #-------------------------
  # AYAR YARDIMCILARI
  #-------------------------
  def read_setting(key)
    Sketchup.read_default(SETTINGS_SECTION, key, "").to_s
  end

  def write_setting(key, value)
    Sketchup.write_default(SETTINGS_SECTION, key, value.to_s)
  end

  def read_all_settings
    {
      render_path:  read_setting("render_path"),
      offer_path:   read_setting("offer_path"),
      project_path: read_setting("project_path")
    }
  end

  #-------------------------
  # DOSYA / KLASÖR AÇMA
  #  (Smart Notes mantığına yakın)
  #-------------------------
  def open_path_with_system(path)
    s = path.to_s.strip
    return if s.empty?

    # URL ise doğrudan tarayıcıya gönder
    if s =~ /^https?:/i
      UI.openURL(s)
      return
    end

    # Dosya / klasör / UNC ne olursa olsun OS'e bırak
    normalized = s.gsub("\\", "/")
    if Sketchup.platform == :platform_win
      if normalized.start_with?("//")
        UI.openURL("file:" + normalized)
      else
        UI.openURL("file:///?" + normalized)
      end
    else
      UI.openURL("file://" + normalized)
    end
  end


  extend self

  #--------------------------------------------
  # YARDIMCI METOTLAR
  #--------------------------------------------
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

  # definition.save_as işlemini tek noktadan yönetelim
  # backup_before: true => mevcut dosya varsa önce yedeğe kopyala (güncelle senaryosu)
  # backup_before: false => ilk kayıtta, kaydettikten sonra kopyala (ilk yedek)
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
    model = Sketchup.active_model
    model.definitions.to_a.find { |d| d.get_attribute(ATTR_KEY, ATTR_PATH) == file_path }
  end

  #--------------------------------------------
  # TSN* OTOMATİK BAĞLAMA
  #--------------------------------------------
  def auto_attach_tsn_components(model)
    source_dir = ensure_source_dir(model)
    return unless source_dir && !source_dir.to_s.strip.empty?

    pattern = File.join(source_dir, "TSN*.skp")
    files   = Dir.glob(pattern)
    return if files.empty?

    defs = model.definitions.to_a

    files.each do |fp|
      base_name = File.basename(fp, ".skp")
      definition = defs.find { |d| d.name.to_s == base_name }
      next unless definition

      current_path = definition.get_attribute(ATTR_KEY, ATTR_PATH).to_s.strip
      next unless current_path.empty?

      begin
        definition.set_attribute(ATTR_KEY, ATTR_PATH, fp)
      rescue => e
        puts "TSN auto-attach error: #{e.message}"
      end
    end
  end

  #--------------------------------------------
  # PANELDE GÖRÜNECEK BİLEŞEN LİSTESİ
  #--------------------------------------------
  def list_source_components
    model   = Sketchup.active_model

    # TSN* dosyalarını kaynak klasörden bul ve sahnedeki aynı isimli bileşenlere otomatik bağla
    auto_attach_tsn_components(model) rescue nil

    defs    = model.definitions.to_a
    entries = []
    seen    = {}

    defs.each do |definition|
      file_path = definition.get_attribute(ATTR_KEY, ATTR_PATH)
      next unless file_path && !file_path.to_s.strip.empty?
      next if seen[file_path]
      next unless File.exist?(file_path)

      begin
        stat      = File.stat(file_path)
        base_name = File.basename(file_path, ".skp")
        name      = definition.name.to_s.strip.empty? ? base_name : definition.name
        entries << {
          name:          name,
          file_path:     file_path,
          updated_at:    format_time_tr(stat.mtime),
          backup_exists: File.exist?(backup_path_for(file_path))
        }
        seen[file_path] = true
      rescue
        next
      end
    end

    entries.sort_by { |e| e[:name].downcase }
  end

  #--------------------------------------------
  # DOSYA YOLUNA GÖRE GÜNCELLE / YENİDEN YÜKLE
  #--------------------------------------------
  def update_component_by_path(file_path)
    definition = find_definition_by_path(file_path)
    unless definition
      UI.messagebox("⚠ Bu dosyaya bağlı bileşen sahnede bulunamadı.\n#{file_path}")
      return
    end

    begin
      save_definition_with_backup(definition, file_path, backup_before: File.exist?(file_path))
      UI.messagebox("✔ Güncellendi: #{file_path}")
      refresh_panel_if_open
    rescue => e
      UI.messagebox("❌ Hata: #{e.message}")
    end
  end

  def reload_component_by_path(file_path)
    model      = Sketchup.active_model
    definition = find_definition_by_path(file_path)
    unless definition
      UI.messagebox("⚠ Bu dosyaya bağlı bileşen sahnede bulunamadı.\n#{file_path}")
      return
    end

    instance = model.entities.grep(Sketchup::ComponentInstance).find { |i| i.definition == definition }
    unless instance
      instance = model.active_entities.grep(Sketchup::ComponentInstance).find { |i| i.definition == definition }
    end

    unless instance
      UI.messagebox("⚠ Bu bileşenden sahnede örnek bulunamadı.")
      return
    end

    reload_component(instance)
    refresh_panel_if_open
  end

  def restore_backup_file(file_path)
    backup = backup_path_for(file_path)
    unless File.exist?(backup)
      UI.messagebox("⚠ Yedek dosya bulunamadı.\n#{backup}")
      return
    end

    begin
      ensure_backup_dir_for(file_path)
      FileUtils.cp(backup, file_path)
      UI.messagebox("✔ Yedekten geri yüklendi: #{file_path}")
      refresh_panel_if_open
    rescue => e
      UI.messagebox("❌ Yedekten geri yükleme hatası: #{e.message}")
    end
  end

  # Modeli Aç: doğrudan işletim sistemine bırak (varsayılan .skp uygulaması)
  def open_component_file_by_path(file_path)
    unless file_path && !file_path.to_s.strip.empty?
      UI.messagebox("⚠ Dosya yolu tanımlı değil.")
      return
    end
    open_path_with_system(file_path)
  end

  def parse_payload(payload)
    return {} unless payload
    if payload.is_a?(String) && !payload.empty?
      JSON.parse(payload)
    elsif payload.is_a?(Hash)
      payload
    else
      {}
    end
  rescue
    {}
  end

  #--------------------------------------------
  # NOTLAR
  #--------------------------------------------
  def read_notes_for(file_path)
    key = file_path.to_s
    return [] if key.empty?
    model = Sketchup.active_model
    raw   = model.get_attribute(NOTES_DICT, key)
    return [] unless raw.is_a?(String) && !raw.empty?
    JSON.parse(raw) rescue []
  end

  def write_notes_for(file_path, notes_array)
    key = file_path.to_s
    return if key.empty?
    model = Sketchup.active_model
    model.set_attribute(NOTES_DICT, key, JSON.generate(notes_array))
  end

  def append_note_for(file_path, text)
    text = text.to_s.strip
    return [] if text.empty?
    notes     = read_notes_for(file_path)
    timestamp = format_time_tr(Time.now)
    # Yeni notlar en üstte gözüksün diye başa ekliyoruz
    notes.unshift({ "text" => text, "at" => timestamp })
    write_notes_for(file_path, notes)
    notes
  end

  def update_note_for(file_path, index, text)
    text  = text.to_s
    notes = read_notes_for(file_path)
    idx   = index.to_i
    return notes unless idx >= 0 && idx < notes.length
    notes[idx]["text"] = text
    write_notes_for(file_path, notes)
    notes
  end


  def show_notes_dialog(file_path, name)
    file_path = file_path.to_s
    return if file_path.empty?

    title = name.to_s.strip
    title = "Notlar" if title.empty?

    @notes_dialog = UI::HtmlDialog.new(
      dialog_title:   "Notlar — #{title}",
      preferences_key: "SmartComponentExporterNotes",
      scrollable:     true,
      resizable:      true,
      width:          420,
      height:         480,
      style:          UI::HtmlDialog::STYLE_DIALOG
    )

    html = <<-HTML
<!DOCTYPE html>
<html lang="tr">
<head>
  <meta charset="UTF-8" />
  <title>Notlar</title>
  <style>
    body {
      margin: 0;
      font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;
      background: #ffffff;
      color: #111827;
    }
    .wrap {
      display: flex;
      flex-direction: column;
      height: 100vh;
      padding: 8px 10px;
      box-sizing: border-box;
    }
    .header {
      font-size: 13px;
      font-weight: 600;
      margin-bottom: 4px;
    }
    .target {
      font-size: 11px;
      color: #6b7280;
      margin-bottom: 8px;
    }
    .list {
      flex: 1;
      overflow: auto;
      display: flex;
      flex-direction: column;
      gap: 4px;
      padding-right: 2px;
    }
    .note-row {
      border-radius: 6px;
      border: 1px solid #e5e7eb;
      padding: 4px 6px;
      font-size: 12px;
      background: #f9fafb;
    }
    .note-text {
      margin-bottom: 2px;
    }
    .note-meta {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 10px;
      color: #6b7280;
    }
    .note-date {
      white-space: nowrap;
    }
    .note-edit-btn {
      border: none;
      background: none;
      color: #4f46e5;
      cursor: pointer;
      padding: 0;
      font-size: 10px;
      text-decoration: underline;
    }
    .empty {
      font-size: 11px;
      color: #9ca3af;
      padding: 4px 2px;
    }
    .input-row {
      border-top: 1px solid #e5e7eb;
      padding-top: 6px;
      margin-top: 6px;
      display: flex;
      gap: 4px;
      align-items: center;
    }
    .input-row input {
      flex: 1;
      font-size: 12px;
      padding: 4px 6px;
      border-radius: 4px;
      border: 1px solid #d1d5db;
    }
    .input-row button {
      font-size: 12px;
      padding: 4px 10px;
      border-radius: 999px;
      border: none;
      cursor: pointer;
      background: #4f46e5;
      color: #ffffff;
    }
    .input-row button:hover {
      background: #4338ca;
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="header">Notlar</div>
    <div class="target" id="notesTarget"></div>
    <div class="list" id="notesList"></div>
    <div class="input-row">
      <input id="noteInput" type="text" placeholder="Yeni not yazın veya düzenleyin..." />
      <button type="button" onclick="onSaveNote()">Kaydet</button>
    </div>
  </div>
  <script>
    var NOTES_FILE_PATH = null;
    var NOTES_NAME      = "";
    var EDIT_INDEX      = null;

    function sendAction(name, payload) {
      if (window.sketchup && window.sketchup[name]) {
        try {
          window.sketchup[name](JSON.stringify(payload || {}));
        } catch(e) {
          console.log("Bridge error:", e);
        }
      }
    }

    window.NOTES_setData = function(payload) {
      try {
        if (typeof payload === "string") {
          payload = JSON.parse(payload);
        }
      } catch(e) {
        console.log("JSON parse error in NOTES_setData", e);
        return;
      }
      if (!payload) return;

      NOTES_FILE_PATH = payload.file_path || null;
      NOTES_NAME      = payload.name || "";
      var notes       = payload.notes || [];

      var targetEl = document.getElementById("notesTarget");
      if (targetEl) targetEl.textContent = NOTES_NAME || "";

      var listEl = document.getElementById("notesList");
      listEl.innerHTML = "";
      if (!notes.length) {
        var empty = document.createElement("div");
        empty.className = "empty";
        empty.textContent = "Bu bileşen için henüz not yok.";
        listEl.appendChild(empty);
        return;
      }

      notes.forEach(function(n, idx) {
        var row  = document.createElement("div");
        row.className = "note-row";

        var textEl = document.createElement("div");
        textEl.className = "note-text";
        textEl.textContent = n.text || "";

        var meta  = document.createElement("div");
        meta.className = "note-meta";

        var dateEl = document.createElement("div");
        dateEl.className = "note-date";
        dateEl.textContent = n.at || "";

        var editBtn = document.createElement("button");
        editBtn.className = "note-edit-btn";
        editBtn.textContent = "Düzenle";
        editBtn.addEventListener("click", function() {
          var input = document.getElementById("noteInput");
          if (!input) return;
          input.value = n.text || "";
          input.focus();
          EDIT_INDEX = idx;
        });

        meta.appendChild(dateEl);
        meta.appendChild(editBtn);

        row.appendChild(textEl);
        row.appendChild(meta);

        listEl.appendChild(row);
      });
    };

    function onSaveNote() {
      var input = document.getElementById("noteInput");
      if (!input || !NOTES_FILE_PATH) return;
      var text = (input.value || "").trim();
      if (!text) return;

      if (EDIT_INDEX === null) {
        sendAction("add_note", { file_path: NOTES_FILE_PATH, text: text });
      } else {
        sendAction("update_note", { file_path: NOTES_FILE_PATH, index: EDIT_INDEX, text: text });
        EDIT_INDEX = null;
      }
      input.value = "";
      input.focus();
    }

    document.addEventListener("DOMContentLoaded", function() {
      sendAction("request_notes_data", {});
      var input = document.getElementById("noteInput");
      if (input) input.focus();
    });
  </script>
</body>
</html>
    HTML

    @notes_dialog.set_html(html)

    @notes_dialog.add_action_callback("request_notes_data") do |dlg, _|
      notes = read_notes_for(file_path)
      payload = {
        file_path: file_path,
        name:      name.to_s,
        notes:     notes
      }
      dlg.execute_script("window.NOTES_setData(#{JSON.generate(payload)})")
    end

    @notes_dialog.add_action_callback("add_note") do |dlg, payload|
      data  = parse_payload(payload)
      text  = data["text"].to_s
      notes = append_note_for(file_path, text)
      payload = {
        file_path: file_path,
        name:      name.to_s,
        notes:     notes
      }
      dlg.execute_script("window.NOTES_setData(#{JSON.generate(payload)})")
    end

    @notes_dialog.add_action_callback("update_note") do |dlg, payload|
      data  = parse_payload(payload)
      idx   = data["index"].to_i
      text  = data["text"].to_s
      notes = update_note_for(file_path, idx, text)
      payload = {
        file_path: file_path,
        name:      name.to_s,
        notes:     notes
      }
      dlg.execute_script("window.NOTES_setData(#{JSON.generate(payload)})")
    end

    @notes_dialog.show
  end

  #--------------------------------------------
  # PANEL VERİSİ GÖNDERME
  #--------------------------------------------
  def send_panel_data(dialog)
    entries  = list_source_components
    settings = read_all_settings
    json_entries  = JSON.generate(entries)
    json_settings = JSON.generate(settings)
    dialog.execute_script("window.SMART_EXPORTER_setData(#{json_entries})")
    dialog.execute_script("window.SMART_EXPORTER_setSettings(#{json_settings})")
  end

  def refresh_panel_if_open
    return unless defined?(@source_panel_dialog) && @source_panel_dialog
    return unless @source_panel_dialog.visible?
    send_panel_data(@source_panel_dialog)
  end

  def show_source_panel
    model = Sketchup.active_model
    if model.path.to_s.empty?
      UI.messagebox("Önce modeli kaydedin.\nKaynak klasörü, model dosyasının yanında oluşturulacaktır.")
      return
    end

    if defined?(@source_panel_dialog) && @source_panel_dialog && @source_panel_dialog.visible?
      @source_panel_dialog.bring_to_front
      return
    end

    @source_panel_dialog = UI::HtmlDialog.new(
      dialog_title:   "Smart Component Exporter — Kaynak Paneli",
      preferences_key: "SmartComponentExporterSourcePanel",
      scrollable:     true,
      resizable:      true,
      width:          820,
      height:         460,
      style:          UI::HtmlDialog::STYLE_DIALOG
    )

    html_path = File.join(File.dirname(__FILE__), "panel.html")
    if File.exist?(html_path)
      html = File.read(html_path, encoding: "UTF-8")
    else
      html = "<html><body><p>panel.html bulunamadı.</p></body></html>"
    end

    @source_panel_dialog.set_html(html)

    @source_panel_dialog.add_action_callback("request_data") do |dlg, _|
      send_panel_data(dlg)
    end

    @source_panel_dialog.add_action_callback("update_from_panel") do |dlg, payload|
      data = parse_payload(payload)
      if data["file_path"]
        update_component_by_path(data["file_path"])
      end
    end

    @source_panel_dialog.add_action_callback("reload_from_panel") do |dlg, payload|
      data = parse_payload(payload)
      if data["file_path"]
        reload_component_by_path(data["file_path"])
      end
    end

    @source_panel_dialog.add_action_callback("restore_backup") do |dlg, payload|
      data = parse_payload(payload)
      if data["file_path"]
        restore_backup_file(data["file_path"])
      end
    end

    @source_panel_dialog.add_action_callback("open_from_panel") do |dlg, payload|
      data = parse_payload(payload)
      if data["file_path"]
        open_component_file_by_path(data["file_path"])
      end
    end

    @source_panel_dialog.add_action_callback("open_notes") do |dlg, payload|
      data = parse_payload(payload)
      file = data["file_path"].to_s
      name = data["name"].to_s
      show_notes_dialog(file, name)
    end

    @source_panel_dialog.add_action_callback("choose_render_path") do |dlg, _|
      model = Sketchup.active_model
      default_dir = if model.path.to_s.empty?
                      Dir.home
                    else
                      File.dirname(model.path)
                    end
      existing = read_setting("render_path")
      if existing && !existing.empty? && File.exist?(File.dirname(existing))
        default_dir = File.dirname(existing)
      end
      file = UI.openpanel("Render dosyasını seç", default_dir, "Tüm Dosyalar|*.*||")
      if file
        write_setting("render_path", file)
        settings = read_all_settings
        dlg.execute_script("window.SMART_EXPORTER_setSettings(#{JSON.generate(settings)})")
      end
    end

    @source_panel_dialog.add_action_callback("choose_offer_path") do |dlg, _|
      model = Sketchup.active_model
      default_dir = if model.path.to_s.empty?
                      Dir.home
                    else
                      File.dirname(model.path)
                    end
      existing = read_setting("offer_path")
      if existing && !existing.empty? && File.exist?(File.dirname(existing))
        default_dir = File.dirname(existing)
      end
      file = UI.openpanel("Teklif dosyasını seç", default_dir, "Tüm Dosyalar|*.*||")
      if file
        write_setting("offer_path", file)
        settings = read_all_settings
        dlg.execute_script("window.SMART_EXPORTER_setSettings(#{JSON.generate(settings)})")
      end
    end

    @source_panel_dialog.add_action_callback("choose_project_path") do |dlg, _|
      folder = UI.select_directory("Proje klasörünü seç")
      if folder
        write_setting("project_path", folder)
        settings = read_all_settings
        dlg.execute_script("window.SMART_EXPORTER_setSettings(#{JSON.generate(settings)})")
      end
    end

    @source_panel_dialog.add_action_callback("open_render_target") do |dlg, _|
      path = read_setting("render_path")
      if path.to_s.empty?
        UI.messagebox("Render dosyası ayarlardan seçilmemiş.")
      else
        open_path_with_system(path)
      end
    end

    @source_panel_dialog.add_action_callback("open_offer_target") do |dlg, _|
      path = read_setting("offer_path")
      if path.to_s.empty?
        UI.messagebox("Teklif dosyası ayarlardan seçilmemiş.")
      else
        open_path_with_system(path)
      end
    end

    @source_panel_dialog.add_action_callback("open_project_folder") do |dlg, _|
      path = read_setting("project_path")
      if path.to_s.empty?
        UI.messagebox("Proje klasörü ayarlardan seçilmemiş.")
      else
        open_path_with_system(path)
      end
    end

    @source_panel_dialog.show

    # Panel ilk açıldığında veriyi Ruby tarafından tetikle
    UI.start_timer(0.1, false) do
      if defined?(@source_panel_dialog) && @source_panel_dialog && @source_panel_dialog.visible?
        send_panel_data(@source_panel_dialog)
      end
    end
  end

  #--------------------------------------------
  # MEVCUT İŞLEVLER (GÜNCELLENMİŞ)
  #--------------------------------------------
  def export_component(component_instance)
    definition = component_instance.definition
    file_path  = definition.get_attribute(ATTR_KEY, ATTR_PATH)

    unless file_path && File.exist?(file_path)
      default_name = definition.name.empty? ? "Component" : definition.name
      model        = Sketchup.active_model
      default_dir  = ensure_source_dir(model) || (model.path.to_s.empty? ? Dir.home : File.dirname(model.path))
      file_path    = UI.savepanel("Bileşeni Kaydet (.skp)", default_dir, "#{default_name}.skp")
      return unless file_path
      file_path += ".skp" unless file_path.downcase.end_with?(".skp")
      definition.set_attribute(ATTR_KEY, ATTR_PATH, file_path)
    end

    begin
      save_definition_with_backup(definition, file_path, backup_before: false)
      UI.messagebox("✔ Kaydedildi: #{file_path}")
      refresh_panel_if_open
    rescue => e
      UI.messagebox("❌ Hata: #{e.message}")
    end
  end

  def update_component(component_instance)
    definition = component_instance.definition
    file_path  = definition.get_attribute(ATTR_KEY, ATTR_PATH)

    unless file_path
      UI.messagebox("⚠ Bileşen daha önce dışa aktarılmamış.")
      return
    end

    begin
      save_definition_with_backup(definition, file_path, backup_before: File.exist?(file_path))
      UI.messagebox("✔ Güncellendi: #{file_path}")
      refresh_panel_if_open
    rescue => e
      UI.messagebox("❌ Hata: #{e.message}")
    end
  end

  def reload_component(component_instance)
    definition = component_instance.definition
    file_path  = definition.get_attribute(ATTR_KEY, ATTR_PATH)

    unless file_path && File.exist?(file_path)
      UI.messagebox("⚠ Dosya bulunamadı. Lütfen önce kaydedin.")
      return
    end

    begin
      model       = Sketchup.active_model
      definitions = model.definitions
      new_def     = definitions.load(file_path)

      if new_def
        t     = component_instance.transformation
        layer = component_instance.layer
        model.entities.erase_entities(component_instance)
        new_instance       = model.active_entities.add_instance(new_def, t)
        new_instance.layer = layer
        UI.messagebox("🔄 Yeniden yüklendi: #{file_path}")
        refresh_panel_if_open
      else
        UI.messagebox("❌ Yeniden yükleme başarısız.")
      end
    rescue => e
      UI.messagebox("❌ Hata: #{e.message}")
    end
  end

  def open_component_file(component_instance)
    definition = component_instance.definition
    file_path  = definition.get_attribute(ATTR_KEY, ATTR_PATH)

    unless file_path && !file_path.to_s.strip.empty?
      UI.messagebox("⚠ Dosya bulunamadı.")
      return
    end

    open_component_file_by_path(file_path)
  end

  def show_info
    UI.messagebox("Bu eklenti bazı güzel insanların ponçik elleriyle tasarlanmış bir bileşen kaydetme & güncelleme aracıdır. İlk çıkış tarihi: 26.09.2025 · Ozan Sert")
  end

  #--------------------------------------------
  # CONTEXT MENU / MENÜ / TOOLBAR
  #--------------------------------------------
  def context_menu_handler(menu)
    model = Sketchup.active_model
    sel   = model.selection

    if sel.count == 1 && sel.first.is_a?(Sketchup::ComponentInstance)
      menu.add_separator
      menu.add_item("🗂 Hazırla ve Kaydet") { export_component(sel.first) }
      menu.add_item("💾 Güncelle")         { update_component(sel.first) }
      menu.add_item("🔄 Yeniden Yükle")    { reload_component(sel.first) }
      menu.add_item("📂 Modeli Aç")        { open_component_file(sel.first) }
    end

    menu.add_separator
    menu.add_item("📋 Kaynak Paneli") { show_source_panel }
  end

  def add_menu_and_toolbar
    UI.add_context_menu_handler { |menu| context_menu_handler(menu) }

    submenu = UI.menu("Plugins").add_submenu(PLUGIN_NAME)
    {
      "🗂 Hazırla ve Kaydet" => :export_component,
      "💾 Güncelle"         => :update_component,
      "🔄 Yeniden Yükle"    => :reload_component,
      "📂 Modeli Aç"        => :open_component_file,
      "📋 Kaynak Paneli"    => :show_source_panel,
      "ℹ Bilgi"             => :show_info
    }.each do |label, method|
      submenu.add_item(label) do
        case method
        when :show_info
          show_info
        when :show_source_panel
          show_source_panel
        else
          sel = Sketchup.active_model.selection.first
          if sel.is_a?(Sketchup::ComponentInstance)
            send(method, sel)
          else
            UI.messagebox("Bileşen seçin.")
          end
        end
      end
    end

    toolbar = UI::Toolbar.new(PLUGIN_NAME)
    {
      "Hazırla ve Kaydet" => :export_component,
      "Güncelle"          => :update_component,
      "Yeniden Yükle"     => :reload_component,
      "Modeli Aç"         => :open_component_file,
      "Kaynak Paneli"     => :show_source_panel,
      "Bilgi"             => :show_info
    }.each do |name, method|
      cmd = UI::Command.new(name) do
        case method
        when :show_info
          show_info
        when :show_source_panel
          show_source_panel
        else
          sel = Sketchup.active_model.selection.first
          if sel.is_a?(Sketchup::ComponentInstance)
            send(method, sel)
          else
            UI.messagebox("Bileşen seçin.")
          end
        end
      end
      cmd.tooltip         = name
      cmd.status_bar_text = name
      icon_file           = File.join(File.dirname(__FILE__), "icons", "#{method}.png")
      cmd.small_icon      = cmd.large_icon = icon_file
      toolbar.add_item(cmd)
    end
    toolbar.show
  end

  unless file_loaded?(__FILE__)
    add_menu_and_toolbar
    file_loaded(__FILE__)
  end
end
