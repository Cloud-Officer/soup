# frozen_string_literal: true

require_relative 'base'

module SOUP
  class NPMParser < BaseParser
    def parse(file, packages)
      lock_file = JSON.parse(File.read(file))
      main_file_json = JSON.parse(File.read(sibling_file(file, 'package.json')))
      direct_deps = (main_file_json['dependencies'] || {}).keys |
                    (main_file_json['devDependencies'] || {}).keys
      all_packages = lock_file['packages'] ||
                     raise("Unsupported package-lock.json at #{file}: lockfileVersion 2+ (with 'packages' key) is required")

      work_items = all_packages.reject { |key, value| key.empty? || value['dev'] }

      parallel_each(work_items, packages) do |key, value|
        fetch_package(file, direct_deps, key, value)
      end
    end

    private

    def fetch_package(file, direct_deps, key, value)
      name = key.split('node_modules/').last
      puts("Checking #{name} #{value['version']}...")
      url = "https://registry.npmjs.org/#{name}"

      begin
        response = HttpClient.get(url)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        warn("Skipping #{name}@#{value['version']}: network timeout after retries (#{e.message}); package omitted from SOUP")
        return
      end

      if response.code != 200
        warn(http_error_message(response, url: url, package: "#{name}@#{value['version']}"))
        return
      end

      package_details = lookup_npm_registry_version(JSON.parse(response.body), name: name, version: value['version'])
      return if package_details.nil?

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
