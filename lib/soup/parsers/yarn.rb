# frozen_string_literal: true

require 'yarn_lock_parser'

require_relative '../package'

module SOUP
  class YarnParser
    MAX_RETRIES = 3
    private_constant :MAX_RETRIES

    def parse(file, packages)
      lock_file = YarnLockParser::Parser.parse(file)
      main_file = File.read(file.gsub('yarn.lock', 'package.json'))
      all_packages = lock_file

      all_packages.each do |js_package|
        puts("Checking #{js_package[:name]} #{js_package[:version]}...")

        next if main_file.include?("#{js_package[:name]}\": \"file:vendor")

        response = nil
        retries = 0

        begin
          response = HTTParty.get("https://registry.npmjs.org/#{js_package[:name]}")
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

        raise(response.message) unless response.code == 200

        package_details = JSON.parse(response.body)['versions'][js_package[:version]]
        package = Package.new(js_package[:name])
        package.file = file
        package.language = 'JS'
        package.version = js_package[:version]
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
        package.dependency = !main_file.include?(js_package[:name])
        packages[package.package] = package
      end
    end
  end
end
