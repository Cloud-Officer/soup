# frozen_string_literal: true

require 'parallel'

require_relative '../errors'
require_relative '../http_client'
require_relative '../package'

module SOUP
  class BaseParser
    NOASSERTION_LICENSE = 'NOASSERTION'
    public_constant :NOASSERTION_LICENSE

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

    # Record a package whose registry lookup failed -- a timeout, a 404 for a
    # package that is simply not in the public registry, or a 403 for a private
    # one. A SOUP register must enumerate every component, so a failed lookup is
    # a metadata gap, not evidence the dependency is absent: dropping the entry
    # would understate the register, and aborting the run would discard every
    # other package resolved so far.
    #
    # The entry carries everything the lockfile already told us (name, version,
    # direct/transitive) and marks the license NOASSERTION, which
    # Application#validate_license reports without failing the build. When a
    # previous run resolved this package, Application restores the richer
    # metadata from .soup.json, so a transient outage never blanks the register.
    def unresolved_package(name:, file:, language:, version:, dependency:)
      package = build_package(
        name: name,
        file: file,
        language: language,
        version: version,
        license: NOASSERTION_LICENSE,
        description: nil,
        website: nil,
        dependency: dependency
      )
      package.unresolved = true
      package
    end

    # Downgrade a license value that carries no usable identity to NOASSERTION.
    #
    # Only a URL qualifies: registries let publishers point at a licence file
    # instead of naming one ("https://github.com/x/y/blob/main/LICENSE"), and a
    # URL states nothing Application#validate_license can match against the
    # allowlist -- NOASSERTION is the honest SPDX answer.
    #
    # Everything else passes through verbatim, "Unlicense" included. It is a
    # real SPDX identifier (the public-domain dedication) and config/licenses.json
    # allowlists it, so rewriting it here made that entry unreachable and warned
    # "Invalid license NOASSERTION" on every run for a licence the project had
    # deliberately accepted.
    def normalize_license(license)
      return license if license.nil?
      return license if license.respond_to?(:empty?) && license.empty?
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
        warn("Skipping #{name}@#{version}: registry response has no versions key; recorded without registry metadata")
        return
      end

      package_details = versions[version]

      if package_details.nil?
        warn("Skipping #{name}@#{version}: version not present in registry; recorded without registry metadata")
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

    # GET a registry URL, absorbing the network fault HttpClient re-raises once
    # its retries are exhausted. Parallel.map propagates the first exception and
    # aborts every other in-flight lookup, so one unreachable registry must not
    # kill the whole scan. Returns nil on failure, so callers guard with
    # `return if empty_response?(response)` -- or, for a multi-source loop, fall
    # through to the next source. Every parser that talks to a registry routes
    # through here.
    #
    # `label` names what is being skipped: the package for the single-source
    # parsers, the URL itself for gradle's mirror loop. `outcome` states what
    # happens next, because most parsers record the package without registry
    # metadata while gradle only advances to the next repository -- claiming
    # either outcome for the other would be false.
    #
    # A nil return and a non-200 are handled the same way by every caller: warn,
    # then record the package via unresolved_package. Only SPM's rate-limit and
    # bad-credentials responses still abort, because those are global conditions
    # that would fail every remaining lookup identically.
    #
    # The rescue list is HttpClient::TRANSIENT_ERRORS itself rather than a
    # hand-copied set, so it can never again fall behind what `.get` retries --
    # the drift that let a connection reset abort an entire scan. The warning
    # names the exception class because "timeout" was previously claimed for
    # every fault, which misdescribed resets, DNS failures and TLS errors.
    def registry_response(url, label:, outcome: 'recorded without registry metadata', **)
      HttpClient.get(url, **)
    rescue *HttpClient::TRANSIENT_ERRORS => e
      warn("Skipping #{label}: network error after retries (#{e.class}: #{e.message}); #{outcome}")
      nil
    end

    # True when a registry lookup produced nothing worth parsing: either no
    # response at all (registry_response above swallowed a network fault), or a
    # response whose body is empty, which JSON.parse would only reject. Both
    # mean the same thing to every caller -- record the package via
    # unresolved_package.
    #
    # This guard used to be spelled `response.nil?`, which covered both cases
    # only because HTTParty::Response overrides #nil? to mean "body is nil or
    # empty". That override is deprecated: it prints a [DEPRECATION] line on
    # every single registry lookup, and once HTTParty drops it the same call
    # would silently narrow to a plain object check, letting an empty body reach
    # JSON.parse and abort the scan with a JSON::ParserError. Asking both
    # questions explicitly preserves today's behaviour past that removal.
    #
    # Note the `unless response` rather than `response.nil?` -- calling #nil? on
    # the Response is itself the deprecated call, so it cannot appear here.
    def empty_response?(response)
      return true unless response

      body = response.body
      body.nil? || body.empty?
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
