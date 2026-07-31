# frozen_string_literal: true

require 'json'
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
      main_file_json = JSON.parse(File.read(sibling_file(file, 'package.json')))
      # Map each declared package.json dependency to its version spec, using
      # exact names. direct_deps drives the dependency flag; the spec lets us
      # reject locally vendored packages (file:vendor/...) by exact lookup
      # instead of a substring scan of the raw package.json text.
      manifest_deps = manifest_dependency_specs(main_file_json)
      direct_deps = manifest_deps.keys

      work_items = lock_file.reject { |js_package| manifest_deps[js_package[:name]].to_s.start_with?('file:vendor') }

      parallel_each(work_items, packages) do |js_package|
        fetch_package(file, direct_deps, js_package)
      end
    end

    private

    DEPENDENCY_SECTIONS = %w[dependencies devDependencies optionalDependencies peerDependencies].freeze
    private_constant :DEPENDENCY_SECTIONS

    def manifest_dependency_specs(main_file_json)
      DEPENDENCY_SECTIONS
        .filter_map { |section| main_file_json[section] }
        .reduce({}, :merge)
    end

    def fetch_package(file, direct_deps, js_package)
      name = js_package[:name]
      version = js_package[:version]
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
