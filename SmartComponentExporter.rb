# encoding: UTF-8
require 'sketchup.rb'
begin
  plugin_dir = File.join(File.dirname(__FILE__), "SmartComponentExporter")
  main_rb    = File.join(plugin_dir, "main.rb")
  if File.exist?(main_rb)
    load main_rb
  else
    puts "SmartComponentExporter main.rb not found at #{main_rb}"
  end
rescue => e
  puts "SmartComponentExporter root loader error: #{e.message}"
end
