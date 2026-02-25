# frozen_string_literal: true

require 'nokogiri'

require_relative '../package'

module SOUP
  class GradleParser
    REPOSITORY_URLS = %w[https://maven.google.com https://jcenter.bintray.com https://plugins.gradle.org/m2/ https://jitpack.io https://oss.sonatype.org/content/repositories/snapshots/ https://maven.pkg.github.com/skgmn/].freeze
    private_constant :REPOSITORY_URLS

    def parse(file, packages)
      lock_file = File.readlines(file)
      main_file = File.read(file.gsub('buildscript-gradle.lockfile', 'build.gradle'))

      lock_file.each do |line|
        next if line.strip.start_with?('#')

        package_name, type = line.strip.split('=')

        next unless type == 'classpath'

        group_id, artifact_id, version = package_name.split(':')
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
          puts("Could not find #{group_id}:#{artifact_id} #{version}...")
          next
        end

        package = Package.new("#{group_id}:#{artifact_id}")
        package.file = file
        package.language = 'Kotlin'
        package.version = version
        package.license = license
        package.description = description
        package.website = website
        package.dependency = !main_file.include?("#{group_id}:#{artifact_id}")
        packages[package.package] = package
      end
    end
  end
end
