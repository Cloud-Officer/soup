# frozen_string_literal: true

require 'bundler'
require 'httparty'
require 'json'

require_relative '../package'

module SOUP
  class BundlerParser
    def parse(file, packages)
      lock_file = Bundler::LockfileParser.new(Bundler.read_file(file))
      main_file = File.read(file.sub(/\.lock$/, ''))

      lock_file.specs.each do |spec|
        puts("Checking #{spec.name} #{spec.version}...")
        response = HTTParty.get("https://api.rubygems.org/api/v2/rubygems/#{spec.name}/versions/#{spec.version}.json")

        raise(response.message) unless response.code == 200

        package_details = JSON.parse(response.body)
        package = Package.new(spec.name)
        package.file = file
        package.language = 'Ruby'
        package.version = spec.version&.to_s&.strip
        package.license = package_details['licenses']&.first&.strip
        package_info = package_details['info']&.split(/\n|\. /)&.first
        package.description = package_info&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
        package.website = package_details['homepage_uri']&.strip
        package.dependency = !main_file.include?(package.package)
        packages[package.package] = package
      end
    end
  end
end
