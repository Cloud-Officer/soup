#!/usr/bin/env ruby

# frozen_string_literal: true

require_relative '../lib/soup/application'

begin
  exit(SOUP::Application.new(ARGV).execute)
rescue StandardError => e
  puts(e)
  puts(e.backtrace)
  exit(1)
end
