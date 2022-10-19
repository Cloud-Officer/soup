# frozen_string_literal: true

require 'httparty'
require 'json'

require_relative '../package'

module SOUP
  class PIPParser
    def parse(file, packages)
      File.open(file, 'r').each_line do |line|
        next if line.include?('#')

        pip_package, version = line.split(/==/)

        next if pip_package.strip.empty?

        puts("Checking #{pip_package} #{version&.strip}...")
        response = HTTParty.get("https://pypi.python.org/pypi/#{pip_package}/json")

        raise(response.message) unless response.code == 200

        package_details = JSON.parse(response.body)
        package = Package.new(pip_package)
        package.file = file
        package.language = 'Python'
        package.version = version&.strip
        package.description = package_details['info']['summary']&.split(/\n|\. /)&.first&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
        package.website = package_details['info']['home_page']&.strip
        package.dependency = false

        package_details['info']['classifiers'].each do |classifier|
          package.license = "#{package.license} #{classifier.split('::').last}".strip if classifier.include?('License')
        end

        package.license = package_details['info']['license']&.strip if package.license.nil? or package.license.empty?
        packages[package.package] = package
      end
    end
  end
end
