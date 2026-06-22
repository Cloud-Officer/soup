# frozen_string_literal: true

require 'json'

require_relative 'base'

module SOUP
  class ComposerParser < BaseParser
    def parse(file, packages)
      lock_file = JSON.parse(File.read(file))
      main_file_json = JSON.parse(File.read(sibling_file(file, 'composer.json')))
      # require / require-dev keys are exact "vendor/name" strings (direct deps);
      # match those instead of substring-scanning the raw composer.json text.
      direct_deps = (main_file_json['require'] || {}).keys |
                    (main_file_json['require-dev'] || {}).keys
      all_packages = (lock_file['packages'] || []) + (lock_file['packages-dev'] || [])

      all_packages.each do |php_package|
        package = build_package(
          name: php_package['name'],
          file: file,
          language: 'PHP',
          version: php_package['version']&.strip,
          license: extract_composer_license(php_package['license']),
          description: Package.sanitize_description(php_package['description'], first_sentence: true),
          website: php_package['homepage']&.strip,
          dependency: !direct_deps.include?(php_package['name'])
        )
        packages[package.package] = package
      end
    end

    private

    # Composer schema permits `license` to be a single string (e.g. "MIT") or an
    # Array of SPDX-style strings (for disjunctive 'OR' combinations). Wrap with
    # Array() so a String input behaves the same as a single-element Array
    # instead of crashing on .first (plain Ruby) or returning the first char
    # (when ActiveSupport's String#first is loaded).
    def extract_composer_license(raw)
      license = Array(raw).first
      license = license&.tr('()', '  ')
      license = license&.strip
      license&.split&.first
    end
  end
end
