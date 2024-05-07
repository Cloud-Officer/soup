# frozen_string_literal: true

require_relative '../package'

module SOUP
  class NPMParser
    def parse(file, packages)
      lock_file = JSON.parse(File.read(file))
      main_file = File.read(file.gsub('package-lock.json', 'package.json'))
      all_packages = lock_file['packages']

      all_packages.each do |key, value|
        next if key.empty?

        name = key.split('node_modules/').last
        puts("Checking #{name} #{value['version']}...")
        response = HTTParty.get("https://registry.npmjs.org/#{name}")

        if response.code != 200
          puts("Error: #{response.message}!")
          next
        end

        package_details = JSON.parse(response.body)['versions'][value['version']]

        if package_details.nil?
          puts("Error: Package #{name} version #{value['version']} not found!")
          next
        end

        package = Package.new(name)
        package.file = file
        package.language = 'JS'
        package.version = value['version']
        package.license = package_details['license']
        package.license = 'NOASSERTION' if package.license&.include?('Unlicense')
        package.description = package_details['description']&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')&.gsub('_', '')&.gsub('[', '')&.gsub(']', '')&.gsub('!', '')&.gsub('|', '')
        package.website = package_details['homepage']
        package.dependency = !main_file.include?(name)
        packages[package.package] = package
      end
    end
  end
end
