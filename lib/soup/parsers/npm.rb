# frozen_string_literal: true

require 'parallel'

require_relative '../http_client'
require_relative '../package'

module SOUP
  class NPMParser
    def parse(file, packages)
      lock_file = JSON.parse(File.read(file))
      main_file_json = JSON.parse(File.read(file.gsub('package-lock.json', 'package.json')))
      direct_deps = (main_file_json['dependencies'] || {}).keys |
                    (main_file_json['devDependencies'] || {}).keys
      all_packages = lock_file['packages']

      work_items = all_packages.reject { |key, value| key.empty? || value['dev'] }

      results =
        Parallel.map(work_items, in_threads: HttpClient::THREAD_COUNT) do |key, value|
          fetch_package(file, direct_deps, key, value)
        end

      results.compact.each { |package| packages[package.package] = package }
    end

    private

    def fetch_package(file, direct_deps, key, value)
      name = key.split('node_modules/').last
      puts("Checking #{name} #{value['version']}...")

      begin
        response = HttpClient.get("https://registry.npmjs.org/#{name}")
      rescue Net::OpenTimeout, Net::ReadTimeout
        return
      end

      if response.code != 200
        puts("Error: #{response.message}!")
        return
      end

      versions = JSON.parse(response.body)['versions']

      if versions.nil?
        puts("Error: Package #{name} has no versions on registry!")
        return
      end

      package_details = versions[value['version']]

      if package_details.nil?
        puts("Error: Package #{name} version #{value['version']} not found!")
        return
      end

      package = Package.new(name)
      package.file = file
      package.language = 'JS'
      package.version = value['version']
      raw_license = package_details['license']
      package.license = raw_license.is_a?(Hash) ? raw_license['type'].to_s : raw_license.to_s
      package.license = 'NOASSERTION' if package.license.include?('Unlicense')
      package.description = Package.sanitize_description(package_details['description'], strip_markdown: true)
      package.website = package_details['homepage']
      package.dependency = !direct_deps.include?(name)
      package
    end
  end
end
