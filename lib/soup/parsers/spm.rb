# frozen_string_literal: true

require 'json'

require_relative 'base'

module SOUP
  class SPMParser < BaseParser
    def parse(file, packages)
      lock_file = JSON.parse(File.read(file))
      lock_file = lock_file['object'] if lock_file['object']
      main_file = read_main_swift_file(file)

      raise('No main file found!') if main_file.nil?

      token = ENV.fetch('GITHUB_TOKEN', '')

      parallel_each(lock_file['pins'], packages) do |pin|
        fetch_package(file, main_file, token, pin)
      end
    end

    private

    # Locate the Swift manifest associated with a Package.resolved file.
    # Tries, in order: the sibling Package.swift (or matching <Name>.swift),
    # the enclosing Tuist/Dependencies.swift if the resolved file lives under a
    # Tuist directory, and finally the sibling <Name>.xcodeproj/project.pbxproj.
    # Path joining uses File.dirname + File.basename so directories containing
    # dots in their name do not corrupt the candidate paths.
    def read_main_swift_file(file)
      dir = File.dirname(file)
      base = File.basename(file, '.*')

      package_swift = path_join(dir, "#{base}.swift")
      return File.read(package_swift) if File.exist?(package_swift)

      tuist_deps = tuist_dependencies_path(dir)
      return File.read(tuist_deps) if tuist_deps && File.exist?(tuist_deps)

      xcodeproj = path_join(dir, "#{base}.xcodeproj/project.pbxproj")
      return File.read(xcodeproj) if File.exist?(xcodeproj)

      nil
    end

    # Drop the leading "./" that File.join would introduce when dir == '.' so
    # downstream File.exist?/File.read receive the same path callers use.
    def path_join(dir, suffix)
      return suffix if dir.nil? || dir.empty? || dir == '.'

      "#{dir}/#{suffix}"
    end

    # If the resolved file lives anywhere inside a Tuist/ directory, return the
    # path to Dependencies.swift inside that same Tuist directory. Returns nil
    # otherwise so a non-Tuist project never invents a synthetic path.
    def tuist_dependencies_path(dir)
      parts = dir.split('/')
      tuist_idx = parts.index('Tuist')
      return if tuist_idx.nil?

      tuist_root = parts[0..tuist_idx].join('/')
      "#{tuist_root}/Dependencies.swift"
    end

    def fetch_package(file, main_file, token, pin)
      pin_id = pin['identity'] || pin['package']
      version = pin_version(pin)
      puts("Checking #{pin_id} #{version}...")
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
        version: version,
        license: package_details.dig('license', 'spdx_id')&.strip,
        description: Package.sanitize_description(package_details['description'], first_sentence: true),
        website: package_details['html_url']&.strip,
        dependency: !main_file.include?(package_details['name'])
      )
    end

    # Resolve the pinned identifier for a Swift Package.resolved entry.
    # Pins can be version-, branch-, or revision-based; the SOUP record needs
    # to capture whichever identifier is present rather than silently falling
    # back to empty string for non-version pins.
    def pin_version(pin)
      state = pin['state'] || {}
      raw = state['version'] || state['branch'] || state['revision']
      raw&.to_s&.strip
    end
  end
end
