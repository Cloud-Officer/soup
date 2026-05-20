# frozen_string_literal: true

require 'bundler'
require 'json'

require_relative 'base'

module SOUP
  class BundlerParser < BaseParser
    def parse(file, packages)
      lock_file = Bundler::LockfileParser.new(Bundler.read_file(file))
      main_file = File.read(file.sub(/\.lock$/, ''))

      parallel_each(lock_file.specs, packages) do |spec|
        fetch_package(file, main_file, spec)
      end
    end

    private

    def fetch_package(file, main_file, spec)
      puts("Checking #{spec.name} #{spec.version}...")
      version_url = "https://api.rubygems.org/api/v2/rubygems/#{spec.name}/versions/#{spec.version}.json"
      response = HttpClient.get(version_url)

      if response.code != 200
        latest_url = "https://api.rubygems.org/api/v1/versions/#{spec.name}/latest.json"
        response = HttpClient.get(latest_url)

        raise(http_error_message(response, url: latest_url, package: "#{spec.name} #{spec.version}")) unless response.code == 200

        latest_version = JSON.parse(response.body)['version']
        fallback_url = "https://api.rubygems.org/api/v2/rubygems/#{spec.name}/versions/#{latest_version}.json"
        response = HttpClient.get(fallback_url)

        raise(http_error_message(response, url: fallback_url, package: "#{spec.name} #{latest_version}")) unless response.code == 200
      end

      package_details = JSON.parse(response.body)

      build_package(
        name: spec.name,
        file: file,
        language: 'Ruby',
        version: spec.version&.to_s&.strip,
        license: package_details['licenses']&.first&.strip,
        description: Package.sanitize_description(package_details['info'], first_sentence: true),
        website: package_details['homepage_uri']&.strip,
        dependency: !main_file.include?(spec.name)
      )
    end
  end
end
