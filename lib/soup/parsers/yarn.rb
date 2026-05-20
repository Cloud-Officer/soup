# frozen_string_literal: true

require 'yarn_lock_parser'

require_relative 'base'

module SOUP
  class YarnParser < BaseParser
    def parse(file, packages)
      lock_file = YarnLockParser::Parser.parse(file)
      main_file = File.read(file.gsub('yarn.lock', 'package.json'))

      work_items = lock_file.reject { |js_package| main_file.include?("#{js_package[:name]}\": \"file:vendor") }

      parallel_each(work_items, packages) do |js_package|
        fetch_package(file, main_file, js_package)
      end
    end

    private

    def fetch_package(file, main_file, js_package)
      puts("Checking #{js_package[:name]} #{js_package[:version]}...")

      begin
        response = HttpClient.get("https://registry.npmjs.org/#{js_package[:name]}")
      rescue Net::OpenTimeout, Net::ReadTimeout
        return
      end

      raise(response.message) unless response.code == 200

      package_details = JSON.parse(response.body)['versions'][js_package[:version]]

      build_package(
        name: js_package[:name],
        file: file,
        language: 'JS',
        version: js_package[:version],
        license: package_details['license'],
        description: Package.sanitize_description(package_details['description'], strip_markdown: true),
        website: package_details['homepage'],
        dependency: !main_file.include?(js_package[:name])
      )
    end
  end
end
