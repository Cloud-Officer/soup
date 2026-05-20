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
      name = js_package[:name]
      version = js_package[:version]
      puts("Checking #{name} #{version}...")
      url = "https://registry.npmjs.org/#{name}"

      begin
        response = HttpClient.get(url)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        warn("Skipping #{name}@#{version}: network timeout after retries (#{e.message}); package omitted from SOUP")
        return
      end

      raise(http_error_message(response, url: url, package: "#{name}@#{version}")) unless response.code == 200

      versions = JSON.parse(response.body)['versions']

      if versions.nil?
        warn("Skipping #{name}@#{version}: registry response has no versions key; package omitted from SOUP")
        return
      end

      package_details = versions[version]

      if package_details.nil?
        warn("Skipping #{name}@#{version}: version not present in registry; package omitted from SOUP")
        return
      end

      build_package(
        name: name,
        file: file,
        language: 'JS',
        version: version,
        license: package_details['license'],
        description: Package.sanitize_description(package_details['description'], strip_markdown: true),
        website: package_details['homepage'],
        dependency: !main_file.include?(name)
      )
    end
  end
end
