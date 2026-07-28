# frozen_string_literal: true

require 'parallel'

require_relative '../errors'
require_relative '../http_client'
require_relative '../package'

module SOUP
  class BaseParser
    NOASSERTION_LICENSE = 'NOASSERTION'
    public_constant :NOASSERTION_LICENSE

    UNLICENSE_PATTERN = 'Unlicense'
    private_constant :UNLICENSE_PATTERN

    NPM_REGISTRY_ROOT = 'https://registry.npmjs.org'
    private_constant :NPM_REGISTRY_ROOT

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

    # Token-boundary test for "is this dependency declared directly in the
    # manifest". A bare String#include? misclassifies a package whose name is a
    # substring of another manifest token (e.g. coordinate androidx.core:core
    # matching androidx.core:core-ktx, or repo Alamofire matching AlamofireImage).
    # `token` matches only when it is not flanked by identifier characters
    # (letters, digits, '_', '-'); '.', ':', '/', and quotes therefore act as
    # boundaries, so Gradle "group:artifact" still matches "group:artifact:1.2.3"
    # and a Swift repo name still matches ".../Alamofire.git".
    #
    # Used only by parsers whose manifest is source code (Gradle build scripts,
    # Swift Package.swift/pbxproj) and so cannot be parsed into an exact
    # dependency set the way the npm/yarn/composer/bundler manifests can.
    def manifest_mentions?(main_file, token)
      main_file.match?(/(?<![\w-])#{Regexp.escape(token)}(?![\w-])/)
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

    # Coerce an npm-registry `license` field to a plain string. The registry
    # returns it as a String ("MIT") for modern packages but as the legacy
    # object form `{ "type": "MIT", "url": "..." }` for older versions. Left
    # untouched, a Hash flows through normalize_license and reaches
    # Application#validate_license, where `license.downcase` raises
    # NoMethodError and aborts the whole run. Shared by the NPM, Yarn, and
    # Importmap parsers, which consume the identical registry.npmjs.org
    # per-version payload.
    def npm_registry_license(raw_license)
      raw_license.is_a?(Hash) ? raw_license['type'].to_s : raw_license.to_s
    end

    # Packument URL for an npm package name.
    def npm_registry_url(name)
      "#{NPM_REGISTRY_ROOT}/#{name}"
    end

    # GET a registry URL, absorbing the timeout HttpClient re-raises once its
    # retries are exhausted. Parallel.map propagates the first exception and
    # aborts every other in-flight lookup, so one unreachable registry must not
    # kill the whole scan. Returns nil on timeout, so callers guard with
    # `return if response.nil?` -- or, for a multi-source loop, fall through to
    # the next source. Every parser that talks to a registry routes through here.
    #
    # `label` names what is being skipped: the package for the single-source
    # parsers, the URL itself for gradle's mirror loop. `outcome` states what
    # happens next, because a timeout omits the package for most parsers but for
    # gradle only advances to the next repository -- claiming omission there
    # would be false whenever a later mirror resolves the coordinate.
    #
    # Deliberately stops short of the non-200 branch: the parsers disagree on
    # whether that warns-and-skips or raises, and unifying it is CONS-001.
    def registry_response(url, label:, outcome: 'package omitted from SOUP', **)
      HttpClient.get(url, **)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      warn("Skipping #{label}: network timeout after retries (#{e.message}); #{outcome}")
      nil
    end

    # Convenience wrapper for the three npm consumers (NPM, Yarn, Importmap),
    # which all resolve the same packument URL from a package name. NPM and Yarn
    # know the version up front and pass "name@version"; Importmap resolves the
    # version from this very response and so can only name the package.
    def npm_registry_response(name:, label: name)
      registry_response(npm_registry_url(name), label: label)
    end

    # Build a Package from an npm-registry per-version payload. The three npm
    # consumers share the JS language tag and the license/description/website
    # extraction; they differ only in how the version became known and whether
    # the package is a direct dependency.
    def build_npm_registry_package(file:, name:, version:, package_details:, dependency:)
      build_package(
        name: name,
        file: file,
        language: 'JS',
        version: version,
        license: npm_registry_license(package_details['license']),
        description: Package.sanitize_description(package_details['description'], strip_markdown: true),
        website: package_details['homepage'],
        dependency: dependency
      )
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
