# frozen_string_literal: true

require 'yarn_lock_parser'

require_relative 'base'

module SOUP
  class YarnParser < BaseParser
    def parse(file, packages)
      lock_file = YarnLockParser::Parser.parse(file) ||
                  raise(
                    UnsupportedFormatError,
                    "Unsupported yarn.lock format at #{file}: only Yarn v1 lockfiles are supported by yarn_lock_parser"
                  )
      main_file = File.read(sibling_file(file, 'package.json'))

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

      raise(RegistryError, http_error_message(response, url: url, package: "#{name}@#{version}")) unless response.code == 200

      package_details = lookup_npm_registry_version(JSON.parse(response.body), name: name, version: version)
      return if package_details.nil?

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
