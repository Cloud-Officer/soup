# frozen_string_literal: true

require 'json'

require_relative 'base'

module SOUP
  class ComposerParser < BaseParser
    def parse(file, packages)
      lock_file = JSON.parse(File.read(file))
      main_file = File.read(file.gsub('lock', 'json'))
      all_packages = lock_file['packages'] + lock_file['packages-dev']

      all_packages.each do |php_package|
        puts("Checking #{php_package['name']} #{php_package['version']}...")

        package = build_package(
          name: php_package['name'],
          file: file,
          language: 'PHP',
          version: php_package['version']&.strip,
          license: extract_composer_license(php_package['license']),
          description: Package.sanitize_description(php_package['description'], first_sentence: true),
          website: php_package['homepage']&.strip,
          dependency: !main_file.include?(php_package['name'])
        )
        packages[package.package] = package
      end
    end

    private

    def extract_composer_license(raw)
      license = raw&.first
      license = license&.tr('()', '  ')
      license = license&.strip
      license&.split&.first
    end
  end
end
