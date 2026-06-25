#!/usr/bin/env ruby
# Moves Runner's "Embed App Extensions" copy-files phase to run BEFORE Flutter's
# "Thin Binary" script phase. Appended at the end (xcodeproj's default), it forms
# a build cycle: Thin Binary signature-scans Runner.app, which depends on the
# embedded .appex, which depends on Thin Binary. Running embed first breaks it.
# Idempotent. Run from app/ios:  ruby reorder_embed_phase.rb
require 'xcodeproj'

project = Xcodeproj::Project.open('Runner.xcodeproj')
runner = project.targets.find { |t| t.name == 'Runner' }
raise 'Runner target not found' unless runner

embed = runner.build_phases.find do |p|
  p.respond_to?(:symbol_dst_subfolder_spec) && p.symbol_dst_subfolder_spec == :plug_ins
end
raise 'Embed App Extensions phase not found' unless embed

ordered = runner.build_phases.to_a
thin_idx = ordered.index { |p| p.display_name.to_s.include?('Thin Binary') }
raise 'Thin Binary phase not found' unless thin_idx

if ordered.index(embed) < thin_idx
  puts '[skip] embed phase already runs before Thin Binary'
  exit 0
end

ordered.delete(embed)
thin_idx = ordered.index { |p| p.display_name.to_s.include?('Thin Binary') }
ordered.insert(thin_idx, embed) # place embed immediately before Thin Binary

# Rewrite the phase list in the new order (delete refs, re-add in sequence).
list = runner.build_phases
list.to_a.each { |p| list.delete(p) }
ordered.each { |p| list << p }

project.save
puts "[ok] moved Embed App Extensions before Thin Binary (#{ordered.map { |p| p.display_name }.join(' | ')})"
