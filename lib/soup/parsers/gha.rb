# frozen_string_literal: true

require 'date'
require 'json'
require 'yaml'

require_relative 'base'

module SOUP
  class GHAParser < BaseParser
    LANGUAGE = 'GHA'
    private_constant :LANGUAGE

    LOCAL_REFERENCE_PREFIXES = ['./', 'docker://'].freeze
    private_constant :LOCAL_REFERENCE_PREFIXES

    USES_REFERENCE = %r{\A(?<repository>[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+)(?:/[^@\s]*)?@(?<ref>\S+)\z}
    private_constant :USES_REFERENCE

    def parse(files, packages)
      references = collect_references(files)

      parallel_each(references.values, packages) do |occurrences|
        fetch_package(occurrences)
      end
    end

    private

    def collect_references(files)
      references = Hash.new { |hash, key| hash[key] = [] }

      files.sort.each do |file|
        uses_values(load_workflow(file)).each do |uses|
          next if uses.start_with?(*LOCAL_REFERENCE_PREFIXES)

          match = USES_REFERENCE.match(uses)

          if match.nil?
            warn("Skipping unrecognized uses reference #{uses} in #{file}")
            next
          end

          repository = match[:repository].downcase
          references[repository] << { repository: repository, ref: match[:ref], file: file }
        end
      end

      references
    end

    def load_workflow(file)
      YAML.safe_load_file(file, permitted_classes: [Date, Time], aliases: true)
    rescue Psych::Exception => e
      raise(InvalidLockfileError, "Invalid YAML in #{file}: #{e.message}")
    end

    def uses_values(node)
      case node
      when Hash
        node.flat_map { |key, value| key == 'uses' && value.is_a?(String) ? [value.strip] : uses_values(value) }
      when Array
        node.flat_map { |value| uses_values(value) }
      else
        []
      end
    end

    def fetch_package(occurrences)
      name = occurrences.first[:repository]
      refs = occurrences.map { |occurrence| occurrence[:ref] }
      refs.uniq!
      refs.sort!
      version = refs.join(', ')
      file = occurrences.first[:file]
      response = github_repository_response(name, label: name)

      return unresolved_package(name: name, file: file, language: LANGUAGE, version: version, dependency: false) unless response

      package_details = JSON.parse(response.body)

      build_package(
        name: name,
        file: file,
        language: LANGUAGE,
        version: version,
        license: package_details.dig('license', 'spdx_id')&.strip,
        description: Package.sanitize_description(package_details['description'], first_sentence: true),
        website: package_details['html_url']&.strip,
        dependency: false
      )
    end
  end
end
