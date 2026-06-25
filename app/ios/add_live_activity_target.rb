#!/usr/bin/env ruby
# Adds the CCLiveActivity Widget Extension target to Runner.xcodeproj and wires
# it for Live Activities. Idempotent: re-running after the target exists is a
# no-op. Run from app/ios:  ruby add_live_activity_target.rb
require 'xcodeproj'

EXT_NAME = 'CCLiveActivity'
EXT_BUNDLE_ID = 'dev.cchandoff.app.LiveActivity'
proj_path = 'Runner.xcodeproj'
project = Xcodeproj::Project.open(proj_path)

runner = project.targets.find { |t| t.name == 'Runner' }
raise 'Runner target not found' unless runner

if project.targets.any? { |t| t.name == EXT_NAME }
  puts "[skip] target #{EXT_NAME} already exists"
  exit 0
end

# Config names the Runner project uses (Debug/Release/Profile) — the extension
# must mirror all of them or Flutter profile/release builds fail to resolve one.
config_names = project.build_configurations.map(&:name)
puts "[info] project configs: #{config_names.join(', ')}"

ext = project.new_target(:app_extension, EXT_NAME, :ios, '16.2', nil, :swift)

# Ensure the extension has every project config (new_target may only add
# Debug/Release). Profile mirrors Release settings.
existing = ext.build_configurations.map(&:name)
(config_names - existing).each do |name|
  base = name == 'Debug' ? :debug : :release
  ext.add_build_configuration(name, base)
  puts "[info] added missing config to extension: #{name}"
end

ext.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = EXT_BUNDLE_ID
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['INFOPLIST_FILE'] = 'CCLiveActivity/Info.plist'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '16.2'
  s['SWIFT_VERSION'] = '5.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['SKIP_INSTALL'] = 'YES'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['MARKETING_VERSION'] = '1.0'
  s['LD_RUNPATH_SEARCH_PATHS'] =
    ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
end

# Source group + file references (paths are relative to ios/).
ext_group = project.main_group.find_subpath(EXT_NAME, true)
ext_group.set_source_tree('SOURCE_ROOT')
ext_group.set_path(EXT_NAME)
attrs_ref = ext_group.new_file('CCAgentActivityAttributes.swift')
activity_ref = ext_group.new_file('CCAgentLiveActivity.swift')
bundle_ref = ext_group.new_file('CCLiveActivityBundle.swift')
ext_group.new_file('Info.plist') # for navigation only; not in any build phase

# Extension compiles all three Swift files; the attributes file is ALSO compiled
# into Runner so the app and the widget share the same ActivityAttributes type.
ext.add_file_references([attrs_ref, activity_ref, bundle_ref])
runner.add_file_references([attrs_ref])

# The Live Activity controller + MethodChannel plugin lives in the Runner group.
runner_group = project.main_group.find_subpath('Runner', false)
raise 'Runner group not found' unless runner_group
ctrl_ref = runner_group.new_file('LiveActivityController.swift')
runner.add_file_references([ctrl_ref])

# Runner depends on the extension and embeds it in PlugIns (dstSubfolderSpec 13).
runner.add_dependency(ext)
embed = runner.new_copy_files_build_phase('Embed App Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
bf = embed.add_file_reference(ext.product_reference, true)
bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "[ok] added #{EXT_NAME} target, shared attributes, controller, embed phase"
