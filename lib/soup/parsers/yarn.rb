# frozen_string_literal: true

require 'parallel'
require 'yarn_lock_parser'

require_relative '../http_client'
require_relative '../package'

module SOUP
  class YarnParser
    def parse(file, packages)
      lock_file = YarnLockParser::Parser.parse(file)
      main_file = File.read(file.gsub('yarn.lock', 'package.json'))

      work_items = lock_file.reject { |js_package| main_file.include?("#{js_package[:name]}\": \"file:vendor") }

      results =
        Parallel.map(work_items, in_threads: HttpClient::THREAD_COUNT) do |js_package|
          fetch_package(file, main_file, js_package)
        end

      results.compact.each { |package| packages[package.package] = package }
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
      package = Package.new(js_package[:name])
      package.file = file
      package.language = 'JS'
      package.version = js_package[:version]
      package.license = package_details['license']
      package.license = 'NOASSERTION' if package.license&.include?('Unlicense')
      package.description = Package.sanitize_description(package_details['description'], strip_markdown: true)
      package.website = package_details['homepage']
      package.dependency = !main_file.include?(js_package[:name])
      package
    end
  end
end
