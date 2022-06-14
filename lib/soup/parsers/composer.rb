# frozen_string_literal: true

require 'json'

require_relative '../package'

module SOUP
  class ComposerParser
    def parse(file, packages)
      lock_file = JSON.parse(File.read(file))
      main_file = File.read(file.gsub('lock', 'json'))

      lock_file['packages'].each do |php_package|
        puts("Checking #{php_package['name']} #{php_package['version']}...")
        package = Package.new(php_package['name'])
        package.file = file
        package.language = 'PHP'
        package.version = php_package['version']&.strip
        package.license = php_package['license']&.first&.tr('()', '  ')&.strip&.split&.first
        package.description = php_package['description']&.split(/\n|\. /)&.first&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
        package.website = php_package['homepage']&.strip
        package.dependency = !main_file.include?(package.package)
        packages[package.package] = package
      end
    end
  end
end
