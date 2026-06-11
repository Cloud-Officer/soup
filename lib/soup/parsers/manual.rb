# frozen_string_literal: true

require_relative 'base'

module SOUP
  # Reads manually-declared SOUP entries from a JSON file (default
  # config/soup-manual.json). These cover third-party components that no package
  # manager or registry can resolve: vendored files committed to the repo and
  # proprietary/commercial components with no public registry entry.
  #
  # Each entry is an object: package (required), plus language, version, license,
  # description, website and an optional `file` path. The `file` path lets the
  # vendored-file enumerator (Application) match a committed file to its entry.
  # Verification fields (risk/requirements/reasoning) are filled the same way as
  # for every other package - from the cache or the prompt.
  class ManualParser < BaseParser
    REQUIRED_KEY = 'package'
    private_constant :REQUIRED_KEY

    def parse(file, packages)
      entries = JSON.parse(File.read(file))

      raise(InvalidLockfileError, "#{file} must contain a JSON array of entries") unless entries.is_a?(Array)

      entries.each do |entry|
        valid_entry = entry.is_a?(Hash) && !entry[REQUIRED_KEY].to_s.empty?
        raise(InvalidLockfileError, "Each entry in #{file} must be an object with a non-empty \"package\"") unless valid_entry

        package = build_entry(file, entry)
        packages[package.package] = package
      end
    end

    private

    def build_entry(file, entry)
      package = build_package(
        name: entry[REQUIRED_KEY],
        file: entry['file'].to_s.empty? ? file : entry['file'],
        language: entry['language'].to_s.empty? ? 'JS' : entry['language'],
        version: entry['version'].to_s,
        license: entry['license'].to_s,
        description: Package.sanitize_description(entry['description'].to_s, strip_markdown: true).to_s,
        website: entry['website'].to_s,
        dependency: false
      )
      # Let an entry pre-declare its verification fields so a project can fully
      # describe a proprietary component in one place; otherwise they fall back
      # to the cache/prompt like any other package.
      package.risk_level = entry['risk_level'].to_s
      package.requirements = entry['requirements'].to_s
      package.verification_reasoning = entry['verification_reasoning'].to_s
      package
    end
  end
end
