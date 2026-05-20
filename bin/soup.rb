#!/usr/bin/env ruby

# frozen_string_literal: true

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require_relative '../lib/soup/application'

TOP_FRAMES_TO_SHOW = 5

begin
  exit(SOUP::Application.new(ARGV).execute)
rescue StandardError => e
  warn("Error: #{e.message}")
  backtrace = Array(e.backtrace)
  if ENV['DEBUG']
    warn(backtrace.join("\n"))
  elsif !backtrace.empty?
    backtrace.first(TOP_FRAMES_TO_SHOW).each { |frame| warn("  #{frame}") }
    warn('  ... (set DEBUG=1 for full backtrace)') if backtrace.length > TOP_FRAMES_TO_SHOW
  end
  exit(1)
end
