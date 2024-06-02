# frozen_string_literal: true

require 'yarn_lock_parser'

require_relative '../package'

module SOUP
  class YarnParser
    def parse(file, packages)
      lock_file = YarnLockParser::Parser.parse(file)
      main_file = File.read(file.gsub('yarn.lock', 'package.json'))
      all_packages = lock_file

      all_packages.each do |js_package|
        puts("Checking #{js_package[:name]} #{js_package[:version]}...")

        next if main_file.include?("#{js_package[:name]}\": \"file:vendor")

        response = HTTParty.get("https://registry.npmjs.org/#{js_package[:name]}")

        raise(response.message) unless response.code == 200

        package_details = JSON.parse(response.body)['versions'][js_package[:version]]
        package = Package.new(js_package[:name])
        package.file = file
        package.language = 'JS'
        package.version = js_package[:version]
        package.license = package_details['license']
        package.license = 'NOASSERTION' if package.license&.include?('Unlicense')
        package.description = package_details['description']&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')&.delete('_')&.delete('[')&.delete(']')&.delete('!')&.delete('|')
        package.website = package_details['homepage']
        package.dependency = !main_file.include?(js_package[:name])
        packages[package.package] = package
      end
    end
  end
end
