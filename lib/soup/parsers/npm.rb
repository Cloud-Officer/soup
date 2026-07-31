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
                     raise(
                       UnsupportedFormatError,
                       "Unsupported package-lock.json at #{file}: lockfileVersion 2+ (with 'packages' key) is required"
                     )

      work_items = all_packages.reject { |key, value| key.empty? || value['dev'] }

      parallel_each(work_items, packages) do |key, value|
        fetch_package(file, direct_deps, key, value)
      end
    end

    private

    def fetch_package(file, direct_deps, key, value)
      name = key.split('node_modules/').last
      version = value['version']
      label = "#{name}@#{version}"
      dependency = !direct_deps.include?(name)

      response = npm_registry_response(name: name, label: label)
      return unresolved_package(name: name, file: file, language: 'JS', version: version, dependency: dependency) if empty_response?(response)

      if response.code != 200
        warn(http_error_message(response, url: npm_registry_url(name), package: label))
        return unresolved_package(name: name, file: file, language: 'JS', version: version, dependency: dependency)
      end

      package_details = lookup_npm_registry_version(JSON.parse(response.body), name: name, version: version)
      return unresolved_package(name: name, file: file, language: 'JS', version: version, dependency: dependency) if package_details.nil?

      build_npm_registry_package(
        file: file,
        name: name,
        version: version,
        package_details: package_details,
        dependency: dependency
      )
    end
  end
end
