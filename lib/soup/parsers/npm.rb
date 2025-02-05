# frozen_string_literal: true

require_relative '../package'

module SOUP
  class NPMParser
    MAX_RETRIES = 3
    private_constant :MAX_RETRIES

    def parse(file, packages)
      lock_file = JSON.parse(File.read(file))
      main_file = File.read(file.gsub('package-lock.json', 'package.json'))
      all_packages = lock_file['packages']

      all_packages.each do |key, value|
        next if key.empty?

        next if value['dev']

        name = key.split('node_modules/').last
        puts("Checking #{name} #{value['version']}...")
        response = nil
        retries = 0

        begin
          response = HTTParty.get("https://registry.npmjs.org/#{name}")
        rescue Net::OpenTimeout => e
          retries += 1

          if retries <= MAX_RETRIES
            puts("Error: #{e.message}. Retrying (#{retries}/#{MAX_RETRIES})...")
            retry
          else
            puts("Error: #{e.message}. Aborting after #{MAX_RETRIES} retries.")
            next
          end
        end

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
        description = package_details['description']
        description = description&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
        description = description&.delete('_')
        description = description&.delete('[')
        description = description&.delete(']')
        description = description&.delete('!')
        description = description&.delete('|')
        package.description = description
        package.website = package_details['homepage']
        package.dependency = !main_file.include?(name)
        packages[package.package] = package
      end
    end
  end
end
