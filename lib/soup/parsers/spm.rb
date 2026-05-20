# frozen_string_literal: true

require 'json'

require_relative 'base'

module SOUP
  class SPMParser < BaseParser
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

      token = ENV.fetch('GITHUB_TOKEN', '')

      parallel_each(lock_file['pins'], packages) do |pin|
        fetch_package(file, main_file, token, pin)
      end
    end

    private

    def fetch_package(file, main_file, token, pin)
      puts("Checking #{pin['identity'] || pin['package']} #{pin['state']['version']}...")
      location = pin['location'] || pin['repositoryURL']
      url = "https://api.github.com/repos/#{location.gsub('git@github.com:', '').gsub('https://github.com/', '').gsub('.git', '')}"

      response =
        if token.empty?
          HttpClient.get(url)
        else
          HttpClient.get(url, headers: { Authorization: "token #{token}" })
        end

      raise("Error: #{response.message}! Please set GITHUB_TOKEN.") if response.message.include?('rate limit') || response.message.include?('Bad credentials')

      return unless response.code == 200

      package_details = JSON.parse(response.body)

      return if package_details['private']

      build_package(
        name: package_details['name'],
        file: file,
        language: 'Swift',
        version: pin['state']['version']&.strip,
        license: package_details.dig('license', 'spdx_id')&.strip,
        description: Package.sanitize_description(package_details['description'], first_sentence: true),
        website: package_details['html_url']&.strip,
        dependency: !main_file.include?(package_details['name'])
      )
    end
  end
end
