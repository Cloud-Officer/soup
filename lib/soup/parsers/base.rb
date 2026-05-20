# frozen_string_literal: true

require 'parallel'

require_relative '../http_client'
require_relative '../package'

module SOUP
  class BaseParser
    NOASSERTION_LICENSE = 'NOASSERTION'
    public_constant :NOASSERTION_LICENSE

    UNLICENSE_PATTERN = 'Unlicense'
    private_constant :UNLICENSE_PATTERN

    def parse(_file, _packages)
      raise(NotImplementedError, "#{self.class} must implement #parse")
    end

    protected

    def parallel_each(work_items, packages, &)
      results = Parallel.map(work_items, in_threads: HttpClient::THREAD_COUNT, &)
      collect_packages(results, packages)
    end

    def collect_packages(results, packages)
      results.compact.each { |package| packages[package.package] = package }
    end

    def build_package(name:, file:, language:, version:, license:, description:, website:, dependency:)
      package = Package.new(name)
      package.file = file
      package.language = language
      package.version = version
      package.license = normalize_license(license)
      package.description = description
      package.website = website
      package.dependency = dependency
      package
    end

    def normalize_license(license)
      return license if license.nil?
      return license if license.respond_to?(:empty?) && license.empty?
      return NOASSERTION_LICENSE if license.to_s.include?(UNLICENSE_PATTERN)
      return NOASSERTION_LICENSE if license.to_s.start_with?('http')

      license
    end

    # Return the path of a sibling file next to `file` (in the same directory).
    # Uses dirname/basename so a path containing the substring of the lockfile
    # name (e.g. /Users/blocker/composer.lock) is not corrupted, and preserves
    # the caller's "relative or absolute" shape: a bare 'composer.lock' yields
    # 'composer.json' (not './composer.json') so File.read stubs and callers
    # that pass bare basenames keep working.
    def sibling_file(file, suffix)
      dir = File.dirname(file)
      return suffix if dir.nil? || dir.empty? || dir == '.'

      File.join(dir, suffix)
    end

    # Look up a specific package version inside an npm-style registry payload
    # (whose shape is `{ "versions": { "<version>": { ... } } }`). Returns the
    # per-version hash, or nil + a stderr warn if the registry response is
    # malformed or the version is missing. Shared by NPM and Yarn parsers.
    def lookup_npm_registry_version(payload, name:, version:)
      versions = payload['versions']

      if versions.nil?
        warn("Skipping #{name}@#{version}: registry response has no versions key; package omitted from SOUP")
        return
      end

      package_details = versions[version]

      if package_details.nil?
        warn("Skipping #{name}@#{version}: version not present in registry; package omitted from SOUP")
        return
      end

      package_details
    end

    # Build an actionable error message for a non-2xx response.
    #
    # Includes status code, reason phrase, URL, the package being processed (when
    # known), and a truncated body snippet so registry-side failures can be
    # diagnosed without rerunning under DEBUG.
    def http_error_message(response, url:, package: nil)
      parts = ["HTTP #{response.code} #{response.message}"]
      parts << "package=#{package}" if package
      parts << "url=#{url}"
      body = response.body.to_s.strip
      parts << "body=#{body[0, 200]}" unless body.empty?
      parts.join(' | ')
    end
  end
end
