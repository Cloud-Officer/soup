# frozen_string_literal: true

require_relative 'base'

module SOUP
  # Parses a Rails importmap pin file (config/importmap.rb). Only pins that
  # resolve to an http(s) CDN URL are treated as third-party SOUP; pins that map
  # to a bare local/vendored asset (application, @hotwired/*, *.js files under
  # vendor/) are first-party or covered by the manual register and are skipped.
  #
  # The npm package name and version are derived from the CDN URL (esm.sh,
  # jspm.io, jsdelivr), then license/description/website are looked up from the
  # npm registry, reusing the same lookup the NPM parser uses. Unpinned "latest"
  # pins (no @version in the URL) resolve to the registry's latest dist-tag.
  class ImportmapParser < BaseParser
    PIN_REGEX = /\bpin\s+["']([^"']+)["']\s*,\s*to:\s*["']([^"']+)["']/
    private_constant :PIN_REGEX

    REGISTRY_ROOT = 'https://registry.npmjs.org'
    private_constant :REGISTRY_ROOT

    def parse(file, packages)
      work_items =
        File.foreach(file).filter_map do |line|
          match = line.match(PIN_REGEX)
          next unless match

          url = match[2]
          next unless url.start_with?('http')

          name, version = name_and_version_from_url(url)
          next if name.nil?

          [name, version]
        end

      parallel_each(work_items, packages) do |name, version|
        fetch_package(file, name, version)
      end
    end

    private

    # Strip the protocol/host and CDN routing prefixes, then read the npm
    # package name (scoped or plain) and the optional @version that follows it.
    def name_and_version_from_url(url)
      path = url.sub(%r{\Ahttps?://[^/]+/}, '')
      path = path.sub(%r{\Anpm[:/]}, '')
      match = path.match(%r{\A(@[^/@]+/[^/@]+|[^/@]+)(?:@([^/]+))?})
      return [nil, nil] unless match

      [match[1], match[2]]
    end

    def fetch_package(file, name, version)
      url = "#{REGISTRY_ROOT}/#{name}"

      begin
        response = HttpClient.get(url)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        warn("Skipping #{name}: network timeout after retries (#{e.message}); package omitted from SOUP")
        return
      end

      if response.code != 200
        warn(http_error_message(response, url: url, package: name))
        return
      end

      payload = JSON.parse(response.body)
      resolved_version = version || payload.dig('dist-tags', 'latest')
      package_details = lookup_npm_registry_version(payload, name: name, version: resolved_version)
      return if package_details.nil?

      raw_license = package_details['license']
      license = raw_license.is_a?(Hash) ? raw_license['type'].to_s : raw_license.to_s

      build_package(
        name: name,
        file: file,
        language: 'JS',
        version: resolved_version,
        license: license,
        description: Package.sanitize_description(package_details['description'], strip_markdown: true),
        website: package_details['homepage'],
        dependency: false
      )
    end
  end
end
