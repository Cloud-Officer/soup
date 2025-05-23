# frozen_string_literal: true

require 'httparty'
require 'json'

require_relative '../package'

module SOUP
  class SPMParser
    def parse(file, packages)
      lock_file = JSON.parse(File.read(file))
      lock_file = lock_file['object'] if lock_file['object']
      main_file =
        if File.exist?(file.gsub('resolved', 'swift'))
          File.read(file.gsub('resolved', 'swift'))
        elsif File.exist?("#{file.split('Tuist').first}Tuist/Dependencies.swift")
          File.read("#{file.split('Tuist').first}Tuist/Dependencies.swift")
        elsif File.exist?("#{file.split('.').first}.xcodeproj/project.pbxproj")
          File.read("#{file.split('.').first}.xcodeproj/project.pbxproj")
        end

      raise('No main file found!') if main_file.nil?

      headers =
        if ENV.fetch('GITHUB_TOKEN', '').empty?
          nil
        else
          {
            headers: { Authorization: "token #{ENV.fetch('GITHUB_TOKEN', '')}" }
          }
        end

      lock_file['pins'].each do |pin|
        puts("Checking #{pin['identity'] || pin['package']} #{pin['state']['version']}...")
        location = pin['location'] || pin['repositoryURL']
        url = "https://api.github.com/repos/#{location.gsub('git@github.com:', '').gsub('https://github.com/', '').gsub('.git', '')}"

        response =
          if headers
            HTTParty.get(url, headers)
          else
            HTTParty.get(url)
          end

        raise("Error: #{response.message}! Please set GITHUB_TOKEN.") if response.message.include?('rate limit') || response.message.include?('Bad credentials')

        next unless response.code == 200

        package_details = JSON.parse(response.body)

        next if package_details['private']

        package = Package.new(package_details['name'])
        package.file = file
        package.language = 'Swift'
        package.version = pin['state']['version']&.strip
        package.license = package_details['license']['spdx_id']&.strip
        description = package_details['description']&.split(/\n|\. /)&.first
        description = description&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
        package.description = description
        package.website = package_details['html_url']&.strip
        package.dependency = !main_file.include?(package.package)
        packages[package.package] = package
      end
    end
  end
end
