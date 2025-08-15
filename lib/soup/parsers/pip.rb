# frozen_string_literal: true

require 'httparty'
require 'json'

require_relative '../package'

module SOUP
  class PIPParser
    def parse(file, packages)
      main_file =
        if File.exist?(file.gsub('.txt', '.in'))
          File.read(file.gsub('.txt', '.in'))
        else
          ''
        end

      File.open(file, 'r').each_line do |line|
        next if line.strip.empty?

        next if line.include?('#')

        line = line.slice(0, line.index(';')) if line.include?(';')
        pip_package, version = line.strip.split('==')

        next if pip_package&.strip&.empty?

        puts("Checking #{pip_package} #{version}...")
        response = RequestWithTimeoutAndRetries.get_with_retries("https://pypi.python.org/pypi/#{pip_package.sub(/\[[^\]]+\]/, '')}/json")

        raise(response.message) unless response.code == 200

        package_details = JSON.parse(response.body)
        package = Package.new(pip_package)
        package.file = file
        package.language = 'Python'
        package.version = version
        description = package_details['info']['summary']&.split(/\n|\. /)&.first
        description = description&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
        package.description = description
        package.website = package_details['info']['home_page']&.strip
        package.dependency = !main_file.include?(package.package)

        package_details['info']['classifiers'].each do |classifier|
          if classifier.include?('License') and classifier.split('::').length > 2
            classifier_license = classifier.split('::').last.strip.split("\n").first
            package.license = "#{package.license} #{classifier_license}".strip
          end
        end

        if package.license.nil? or package.license.empty?
          license = package_details['info']['license']&.strip&.split("\n")
          package.license = license&.first
        end

        packages[package.package] = package
      end
    end
  end

  class RequestWithTimeoutAndRetries
    include HTTParty

    default_options.update(timeout: 5)

    def self.get_with_retries(url, options = {}, max_retries = 3)
      retries = 0
      begin
        get(url, options)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise(e) if retries >= max_retries

        retries += 1
        retry
      end
    end
  end
end
