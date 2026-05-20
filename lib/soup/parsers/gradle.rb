# frozen_string_literal: true

require 'nokogiri'

require_relative 'base'

module SOUP
  class GradleParser < BaseParser
    REPOSITORY_URLS = %w[https://maven.google.com https://jcenter.bintray.com https://plugins.gradle.org/m2/ https://jitpack.io https://oss.sonatype.org/content/repositories/snapshots/ https://maven.pkg.github.com/skgmn/].freeze
    private_constant :REPOSITORY_URLS

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

      raise("No build.gradle or build.gradle.kts found alongside #{file}")
    end

    def fetch_package(file, main_file, group_id, artifact_id, version)
      puts("Checking #{group_id}:#{artifact_id} #{version}...")
      response = HttpClient.get("https://search.maven.org/solrsearch/select?q=g:%22#{group_id}%22+AND+a:%22#{artifact_id}%22+AND+v:%22#{version}%22&rows=1&wt=json")

      parsed = JSON.parse(response.body) if response.code == 200
      docs = parsed&.dig('response', 'docs')

      if response.code == 200 && docs&.length == 1
        license = docs[0]['l']
        description = docs[0]['p']
        website = docs[0]['home_page']
      else
        REPOSITORY_URLS.each do |url|
          response = HttpClient.get("#{url}/#{group_id.tr('.', '/')}/#{artifact_id}/#{version}/#{artifact_id}-#{version}.pom")

          next unless response.code == 200

          xml_doc = Nokogiri::XML(response.body)
          xml_doc.remove_namespaces!
          license = xml_doc.xpath('//licenses/license/name').text
          description = xml_doc.xpath('//description').text
          website = xml_doc.xpath('/project/url').text
          break
        end
      end

      if response.code != 200
        warn("Could not find #{group_id}:#{artifact_id} #{version}...")
        return
      end

      build_package(
        name: "#{group_id}:#{artifact_id}",
        file: file,
        language: 'Kotlin',
        version: version,
        license: license,
        description: Package.sanitize_description(description),
        website: website,
        dependency: !main_file.include?("#{group_id}:#{artifact_id}")
      )
    end
  end
end
