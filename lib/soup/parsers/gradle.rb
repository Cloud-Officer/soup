# frozen_string_literal: true

require 'net/http'
require 'nokogiri'

require_relative 'base'

module SOUP
  class GradleParser < BaseParser
    # Maven mirrors tried (in order) when search.maven.org has no matching docs.
    # jcenter.bintray.com (sunset 2022) and the third-party maven.pkg.github.com/skgmn
    # vendor repo were dropped from the list. Neither served a generic SOUP scan.
    REPOSITORY_URLS = %w[
      https://maven.google.com
      https://plugins.gradle.org/m2/
      https://jitpack.io
      https://oss.sonatype.org/content/repositories/snapshots/
    ].freeze
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

      raise(InvalidLockfileError, "No build.gradle or build.gradle.kts found alongside #{file}")
    end

    def fetch_package(file, main_file, group_id, artifact_id, version)
      last_url = "https://search.maven.org/solrsearch/select?q=g:%22#{group_id}%22+AND+a:%22#{artifact_id}%22+AND+v:%22#{version}%22&rows=1&wt=json"
      # search.maven.org's solrsearch endpoint is chronically flaky and regularly
      # stops responding entirely (Net::ReadTimeout). When that happens we must
      # still try the per-repository POM fallbacks below (maven.google.com et al.
      # serve the Android/AndroidX artifacts that dominate a Gradle scan), so a
      # dead primary is treated as "no match" rather than aborting the whole run.
      response = safe_get(last_url)

      parsed = JSON.parse(response.body) if response&.code == 200
      docs = parsed&.dig('response', 'docs')

      resolved = false

      if response&.code == 200 && docs&.length == 1
        license = docs[0]['l']
        description = docs[0]['p']
        website = docs[0]['home_page']
        resolved = true
      else
        REPOSITORY_URLS.each do |url|
          last_url = "#{url}/#{group_id.tr('.', '/')}/#{artifact_id}/#{version}/#{artifact_id}-#{version}.pom"
          response = safe_get(last_url)

          next unless response&.code == 200

          xml_doc = Nokogiri::XML(response.body)
          xml_doc.remove_namespaces!
          license = xml_doc.xpath('//licenses/license/name').text
          description = xml_doc.xpath('//description').text
          website = xml_doc.xpath('/project/url').text
          resolved = true
          break
        end
      end

      unless resolved
        warn(unresolved_message(response, url: last_url, package: "#{group_id}:#{artifact_id} #{version}"))
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
        dependency: !manifest_mentions?(main_file, "#{group_id}:#{artifact_id}")
      )
    end

    # HttpClient.get re-raises Net::OpenTimeout/Net::ReadTimeout once its retries
    # are exhausted. For a multi-mirror parser an unreachable mirror should not
    # kill the scan (Parallel.map propagates the first exception and aborts every
    # other in-flight lookup), so we swallow the timeout, warn, and return nil so
    # the caller falls through to the next source.
    def safe_get(url)
      HttpClient.get(url)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      warn("Error: #{e.message}. Skipping #{url} after retries.")
      nil
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
