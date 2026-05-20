# frozen_string_literal: true

require_relative 'base'

module SOUP
  class NPMParser < BaseParser
    def parse(file, packages)
      lock_file = JSON.parse(File.read(file))
      main_file_json = JSON.parse(File.read(file.gsub('package-lock.json', 'package.json')))
      direct_deps = (main_file_json['dependencies'] || {}).keys |
                    (main_file_json['devDependencies'] || {}).keys
      all_packages = lock_file['packages']

      work_items = all_packages.reject { |key, value| key.empty? || value['dev'] }

      parallel_each(work_items, packages) do |key, value|
        fetch_package(file, direct_deps, key, value)
      end
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

      raw_license = package_details['license']
      license = raw_license.is_a?(Hash) ? raw_license['type'].to_s : raw_license.to_s

      build_package(
        name: name,
        file: file,
        language: 'JS',
        version: value['version'],
        license: license,
        description: Package.sanitize_description(package_details['description'], strip_markdown: true),
        website: package_details['homepage'],
        dependency: !direct_deps.include?(name)
      )
    end
  end
end
