# frozen_string_literal: true

require 'bundler'
require 'json'
require 'parallel'

require_relative '../http_client'
require_relative '../package'

module SOUP
  class BundlerParser
    def parse(file, packages)
      lock_file = Bundler::LockfileParser.new(Bundler.read_file(file))
      main_file = File.read(file.sub(/\.lock$/, ''))

      results =
        Parallel.map(lock_file.specs, in_threads: HttpClient::THREAD_COUNT) do |spec|
          fetch_package(file, main_file, spec)
        end

      results.compact.each { |package| packages[package.package] = package }
    end

    private

    def fetch_package(file, main_file, spec)
      puts("Checking #{spec.name} #{spec.version}...")
      response = HttpClient.get("https://api.rubygems.org/api/v2/rubygems/#{spec.name}/versions/#{spec.version}.json")

      if response.code != 200
        response = HttpClient.get("https://api.rubygems.org/api/v1/versions/#{spec.name}/latest.json")

        raise(response.message) unless response.code == 200

        latest_version = JSON.parse(response.body)['version']
        response = HttpClient.get("https://api.rubygems.org/api/v2/rubygems/#{spec.name}/versions/#{latest_version}.json")

        raise(response.message) unless response.code == 200
      end

      package_details = JSON.parse(response.body)
      package = Package.new(spec.name)
      package.file = file
      package.language = 'Ruby'
      package.version = spec.version&.to_s&.strip
      package.license = package_details['licenses']&.first&.strip
      package.description = Package.sanitize_description(package_details['info'], first_sentence: true)
      package.website = package_details['homepage_uri']&.strip
      package.dependency = !main_file.include?(package.package)
      package
    end
  end
end
