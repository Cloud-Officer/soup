# frozen_string_literal: true

require 'json'

require_relative 'base'

module SOUP
  class PIPParser < BaseParser
    LOOSE_CONSTRAINT_PATTERN = /[<>!~]/
    private_constant :LOOSE_CONSTRAINT_PATTERN

    def parse(file, packages)
      main_file =
        if File.exist?(file.gsub('.txt', '.in'))
          File.read(file.gsub('.txt', '.in'))
        else
          ''
        end

      work_items = []
      File.foreach(file) do |line|
        next if line.strip.empty?

        next if line.include?('#')

        line = line.slice(0, line.index(';')) if line.include?(';')
        pip_package, version = line.strip.split('==', 2)

        next if pip_package&.strip&.empty?

        if version.nil? || version.strip.empty?
          warn("Skipping `#{line.strip}` in #{file}: only exact `==` version pins are supported (loose constraints like >=/~=/!= are not supported)")
          next
        end

        next if pip_package.match?(LOOSE_CONSTRAINT_PATTERN)

        work_items << [pip_package, version]
      end

      parallel_each(work_items, packages) do |pip_package, version|
        fetch_package(file, main_file, pip_package, version)
      end
    end

    private

    def fetch_package(file, main_file, pip_package, version)
      puts("Checking #{pip_package} #{version}...")
      url = "https://pypi.python.org/pypi/#{pip_package.sub(/\[[^\]]+\]/, '')}/json"
      response = HttpClient.get(url)

      raise(RegistryError, http_error_message(response, url: url, package: "#{pip_package}==#{version}")) unless response.code == 200

      package_details = JSON.parse(response.body)
      info = package_details['info']

      build_package(
        name: pip_package,
        file: file,
        language: 'Python',
        version: version,
        license: extract_pip_license(info),
        description: Package.sanitize_description(info['summary'], first_sentence: true),
        website: info['home_page']&.strip,
        dependency: !main_file.include?(pip_package)
      )
    end

    def extract_pip_license(info)
      license = ''

      Array(info['classifiers']).each do |classifier|
        next unless classifier.include?('License') && classifier.split('::').length > 2

        classifier_license = classifier.split('::').last.strip.split("\n").first
        license = "#{license} #{classifier_license}".strip
      end

      return license unless license.empty?

      raw = info['license']
      return raw if raw.nil?

      raw.strip.split("\n").first
    end
  end
end
