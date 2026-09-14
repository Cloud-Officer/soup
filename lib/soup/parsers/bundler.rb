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

      parallel_each(lock_file.specs + declared_bundler(lock_file, direct_deps), packages) do |spec|
        fetch_package(file, direct_deps, spec)
      end
    end

    private

    LockedGem = Data.define(:name, :version)
    private_constant :LockedGem

    # Bundler never lists itself under specs, so its BUNDLED WITH version stands in when the Gemfile declares it.
    def declared_bundler(lock_file, direct_deps)
      return [] unless direct_deps.include?('bundler')
      return [] if lock_file.specs.any? { |spec| spec.name == 'bundler' }

      bundler_version = lock_file.bundler_version
      bundler_version ? [LockedGem.new(name: 'bundler', version: bundler_version)] : []
    end

    def fetch_package(file, direct_deps, spec)
      version = spec.version&.to_s&.strip
      dependency = !direct_deps.include?(spec.name)
      response = rubygems_response(spec)
      return unresolved_package(name: spec.name, file: file, language: 'Ruby', version: version, dependency: dependency) unless response

      package_details = JSON.parse(response.body)

      build_package(
        name: spec.name,
        file: file,
        language: 'Ruby',
        version: version,
        license: package_details['licenses']&.first&.strip,
        description: Package.sanitize_description(package_details['info'], first_sentence: true),
        website: package_details['homepage_uri']&.strip,
        dependency: dependency
      )
    end

    # The pinned version's 200 response, else the latest version's when the pinned one is not published; nil otherwise.
    def rubygems_response(spec)
      rubygems_candidates(spec).each do |url, label, final|
        response = registry_response(url, label: label)
        # An unreachable registry would fail every remaining candidate identically.
        break if empty_response?(response)
        return response if response.code == 200

        warn(http_error_message(response, url: url, package: label)) if final
      end

      nil
    end

    # Yields [url, label, final]; the latest version is looked up only once the pinned version has failed.
    def rubygems_candidates(spec)
      Enumerator.new do |candidates|
        label = "#{spec.name} #{spec.version}"
        candidates << [rubygems_version_url(spec.name, spec.version), label, false]

        latest = successful_registry_response("https://api.rubygems.org/api/v1/versions/#{spec.name}/latest.json", label: label)
        next unless latest

        latest_version = JSON.parse(latest.body)['version']
        candidates << [rubygems_version_url(spec.name, latest_version), "#{spec.name} #{latest_version}", true]
      end
    end

    def rubygems_version_url(name, version)
      "https://api.rubygems.org/api/v2/rubygems/#{name}/versions/#{version}.json"
    end
  end
end
