# frozen_string_literal: true

require 'json'

require_relative 'base'

module SOUP
  class SPMParser < BaseParser
    def parse(file, packages)
      lock_file = JSON.parse(File.read(file))
      lock_file = lock_file['object'] if lock_file['object']
      main_file = read_main_swift_file(file)

      raise(InvalidLockfileError, "No Swift main file found alongside #{file}") if main_file.nil?

      parallel_each(lock_file['pins'], packages) do |pin|
        fetch_package(file, main_file, pin)
      end
    end

    private

    # Locate the Swift manifest associated with a Package.resolved file.
    # Tries, in order: the sibling Package.swift (or matching <Name>.swift),
    # the enclosing Tuist/Dependencies.swift if the resolved file lives under a
    # Tuist directory, the sibling <Name>.xcodeproj/project.pbxproj, and finally
    # the project.pbxproj of an enclosing *.xcodeproj higher up the tree.
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

      enclosing_pbxproj = enclosing_xcodeproj_pbxproj(dir)
      return File.read(enclosing_pbxproj) if enclosing_pbxproj

      nil
    end

    # Standard Xcode-managed SPM places Package.resolved deep inside the project
    # bundle, e.g. <Name>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
    # (or under a sibling .xcworkspace). None of the adjacent-file checks match
    # that layout, so walk up the ancestors and return the project.pbxproj of the
    # first enclosing *.xcodeproj. That pbxproj names the direct package
    # dependencies, which is all read_main_swift_file is consulted for.
    def enclosing_xcodeproj_pbxproj(dir)
      current = File.expand_path(dir)

      while current != File.dirname(current)
        if File.extname(current) == '.xcodeproj'
          pbxproj = File.join(current, 'project.pbxproj')
          return pbxproj if File.exist?(pbxproj)
        end

        current = File.dirname(current)
      end

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

    def fetch_package(file, main_file, pin)
      repo_path = github_repo_path(pin['location'] || pin['repositoryURL'])
      name = pin_repo_name(repo_path, pin['identity'] || pin['package'])
      version = pin_version(pin)
      response = github_repository_response(repo_path, label: name)

      return unresolved_package(name: name, file: file, language: 'Swift', version: version, dependency: !manifest_mentions?(main_file, name)) unless response

      package_details = JSON.parse(response.body)

      # A private repository is still a SOUP component, so it is recorded rather
      # than dropped. The lookup succeeded, so its real metadata is used.
      warn("#{name} resolves to a private repository; recording it with the metadata GitHub returned") if package_details['private']

      build_package(
        name: package_details['name'],
        file: file,
        language: 'Swift',
        version: version,
        license: package_details.dig('license', 'spdx_id')&.strip,
        description: Package.sanitize_description(package_details['description'], first_sentence: true),
        website: package_details['html_url']&.strip,
        dependency: !manifest_mentions?(main_file, package_details['name'])
      )
    end

    # Extract the GitHub owner/repo path from a Package.resolved location URL,
    # which can appear in three forms:
    #   - https://github.com/<owner>/<repo>.git
    #   - https://github.com/<owner>/<repo>
    #   - git@github.com:<owner>/<repo>.git
    # Single regex replaces the previous triple-chained gsub.
    GITHUB_URL_NOISE = %r{\A(?:git@github\.com:|https?://github\.com/)|\.git\z}
    private_constant :GITHUB_URL_NOISE

    def github_repo_path(location)
      location.to_s.gsub(GITHUB_URL_NOISE, '')
    end

    # The repository name matches the name a successful lookup records, so both paths share one cache key.
    def pin_repo_name(repo_path, pin_id)
      repo_path[%r{\A[^/:\s]+/([^/:\s]+)\z}, 1] || pin_id
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
