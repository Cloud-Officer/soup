# frozen_string_literal: true

require 'bundler'
require 'json'

require_relative 'base'

module SOUP
  class BundlerParser < BaseParser
    def parse(file, packages)
      lock_file = Bundler::LockfileParser.new(Bundler.read_file(file))
      # The lockfile's DEPENDENCIES section lists exactly the gems declared in
      # the Gemfile (direct deps); everything else in specs is transitive. This
      # is an exact name match, unlike a String#include? scan of the Gemfile.
      direct_deps = lock_file.dependencies.keys

      parallel_each(lock_file.specs, packages) do |spec|
        fetch_package(file, direct_deps, spec)
      end
    end

    private

    def fetch_package(file, direct_deps, spec)
      label = "#{spec.name} #{spec.version}"
      version_url = "https://api.rubygems.org/api/v2/rubygems/#{spec.name}/versions/#{spec.version}.json"
      # A timeout means rubygems.org is unreachable after every retry, so the
      # remaining fallbacks would time out too -- skip the gem rather than walk
      # the rest of the chain. CONS-002.
      response = registry_response(version_url, label: label)
      return if response.nil?

      if response.code != 200
        latest_url = "https://api.rubygems.org/api/v1/versions/#{spec.name}/latest.json"
        response = registry_response(latest_url, label: label)
        return if response.nil?

        raise(RegistryError, http_error_message(response, url: latest_url, package: label)) unless response.code == 200

        latest_version = JSON.parse(response.body)['version']
        fallback_url = "https://api.rubygems.org/api/v2/rubygems/#{spec.name}/versions/#{latest_version}.json"
        response = registry_response(fallback_url, label: "#{spec.name} #{latest_version}")
        return if response.nil?

        raise(RegistryError, http_error_message(response, url: fallback_url, package: "#{spec.name} #{latest_version}")) unless response.code == 200
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
        dependency: !direct_deps.include?(spec.name)
      )
    end
  end
end
