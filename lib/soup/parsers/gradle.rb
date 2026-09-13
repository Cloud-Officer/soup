# frozen_string_literal: true

require 'net/http'
require 'nokogiri'

require_relative 'base'

module SOUP
  class GradleParser < BaseParser
    # Maven repositories tried (in order) for each coordinate's POM.
    REPOSITORY_URLS = %w[
      https://repo1.maven.org/maven2
      https://maven.google.com
      https://plugins.gradle.org/m2
      https://jitpack.io
      https://oss.sonatype.org/content/repositories/snapshots
    ].freeze
    private_constant :REPOSITORY_URLS

    # POMs inspected for <licenses>: the artifact's own plus up to four <parent> ancestors.
    MAX_POM_DEPTH = 5
    private_constant :MAX_POM_DEPTH

    MAIN_FILE_NAMES = %w[build.gradle build.gradle.kts].freeze
    private_constant :MAIN_FILE_NAMES

    def parse(file, packages)
      lock_file = File.readlines(file)
      main_file = read_main_gradle_file(file)
      is_buildscript = File.basename(file) == 'buildscript-gradle.lockfile'

      work_items =
        lock_file.filter_map do |line|
          next if line.strip.start_with?('#')

          package_name, type = line.strip.split('=')

          if is_buildscript
            next unless type == 'classpath'
          else
            next unless type&.split(',')&.any? do |config|
              lower = config.downcase
              lower.end_with?('runtimeclasspath') && !lower.include?('test') && !lower.include?('debug')
            end
          end

          package_name.split(':')
        end

      parallel_each(work_items, packages) do |group_id, artifact_id, version|
        fetch_package(file, main_file, group_id, artifact_id, version)
      end
    end

    private

    # Try Groovy DSL first then Kotlin DSL. Kotlin DSL (build.gradle.kts) is the
    # Gradle 8.x+ default for new Android/Kotlin projects, so a parser that only
    # tries build.gradle would crash on modern projects.
    def read_main_gradle_file(file)
      MAIN_FILE_NAMES.each do |name|
        candidate = file.sub(/(?:buildscript-)?gradle\.lockfile\z/, name)
        return File.read(candidate)
      rescue Errno::ENOENT
        next
      end

      raise(InvalidLockfileError, "No build.gradle or build.gradle.kts found alongside #{file}")
    end

    def fetch_package(file, main_file, group_id, artifact_id, version)
      coordinate = "#{group_id}:#{artifact_id}"
      dependency = !manifest_mentions?(main_file, coordinate)
      pom = fetch_pom(group_id, artifact_id, version, REPOSITORY_URLS)

      unless pom[:document]
        warn(unresolved_message(pom[:response], url: pom[:url], package: "#{coordinate} #{version}"))
        return unresolved_package(name: coordinate, file: file, language: 'Kotlin', version: version, dependency: dependency)
      end

      document = pom[:document]

      build_package(
        name: coordinate,
        file: file,
        language: 'Kotlin',
        version: version,
        license: pom_license(document, pom[:repository]),
        description: Package.sanitize_description(document.xpath('/project/description').text.strip),
        website: document.xpath('/project/url').text.strip,
        dependency: dependency
      )
    end

    def fetch_pom(group_id, artifact_id, version, repositories)
      result = {}

      repositories.each do |repository|
        url = "#{repository}/#{group_id.tr('.', '/')}/#{artifact_id}/#{version}/#{artifact_id}-#{version}.pom"
        response = registry_response(url, label: url, outcome: 'trying the next repository')
        result = { url: url, response: response }

        next unless response&.code == 200

        document = Nokogiri::XML(response.body)
        document.remove_namespaces!
        return result.merge(repository: repository, document: document)
      end

      result
    end

    def pom_license(document, repository, depth = 1)
      names =
        document.xpath('/project/licenses/license/name').filter_map do |node|
          name = node.text.strip
          name unless name.empty?
        end
      return names.join(', ') unless names.empty?
      return NOASSERTION_LICENSE if depth >= MAX_POM_DEPTH

      parent = parent_pom(document, repository)
      parent ? pom_license(parent, repository, depth + 1) : NOASSERTION_LICENSE
    end

    def parent_pom(document, repository)
      parent = document.at_xpath('/project/parent')
      return unless parent

      group_id, artifact_id, version = %w[groupId artifactId version].map { |field| parent.at_xpath(field)&.text.to_s.strip }
      return if [group_id, artifact_id, version].any?(&:empty?)

      fetch_pom(group_id, artifact_id, version, [repository, REPOSITORY_URLS.first].uniq)[:document]
    end

    # Build the "could not resolve this coordinate" warning. With a final
    # response in hand we surface its status/url/body via http_error_message;
    # when every source timed out (response is nil) there is no HTTP status to
    # report, so we note that instead.
    def unresolved_message(response, url:, package:)
      return http_error_message(response, url: url, package: package) if response

      "Skipping #{package}: all Maven lookups timed out (last url=#{url})"
    end
  end
end
