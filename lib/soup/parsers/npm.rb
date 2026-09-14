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

      work_items = all_packages.select { |key, value| third_party_entry?(key, value) }

      parallel_each(work_items, packages) do |key, value|
        fetch_package(file, direct_deps, key, value)
      end
    end

    private

    def third_party_entry?(key, value)
      return false unless key.include?('node_modules/')
      return false if value['dev'] || value['link']

      !value['resolved'].to_s.start_with?('file:')
    end

    def fetch_package(file, direct_deps, key, value)
      name = key.split('node_modules/').last
      resolve_npm_package(file: file, name: name, version: value['version'], dependency: !direct_deps.include?(name))
    end
  end
end
