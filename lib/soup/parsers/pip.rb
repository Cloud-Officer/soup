# frozen_string_literal: true

require 'json'

require_relative 'base'

module SOUP
  class PIPParser < BaseParser
    LOOSE_CONSTRAINT_PATTERN = /[<>!~]/
    private_constant :LOOSE_CONSTRAINT_PATTERN

    # Leading distribution name of a requirement line, before any extras,
    # version constraint, or environment marker (PEP 508).
    REQUIREMENT_NAME_PATTERN = /\A[A-Za-z0-9._-]+/
    private_constant :REQUIREMENT_NAME_PATTERN

    def parse(file, packages)
      direct_deps = read_direct_dependencies(file)

      work_items = []
      File.foreach(file) do |line|
        # Strip inline/full-line comments first (mirrors read_direct_dependencies)
        # so pinned packages with trailing comments such as
        # `requests==2.31.0  # security pin` are not silently dropped.
        line = line.split('#', 2).first.to_s
        next if line.strip.empty?

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
        fetch_package(file, direct_deps, pip_package, version)
      end
    end

    private

    # Direct dependencies are the names declared in the sibling requirements.in
    # (the compiled-from source). Returns PEP 503-normalized names for exact
    # comparison; an empty list (no .in file) leaves every package transitive,
    # matching the previous empty-main_file behavior.
    def read_direct_dependencies(file)
      in_file = file.gsub('.txt', '.in')
      return [] unless File.exist?(in_file)

      File.read(in_file).each_line.filter_map do |line|
        line = line.split('#', 2).first.to_s.strip
        next if line.empty?
        next if line.start_with?('-') # pip directives such as -r, -c, --hash

        match = line.match(REQUIREMENT_NAME_PATTERN)
        normalize_pip_name(match.to_s) if match
      end
    end

    # PEP 503 name normalization: lowercase, with runs of -, _ and . collapsed
    # to a single -, so e.g. "Foo.Bar" and "foo_bar" compare equal.
    def normalize_pip_name(name)
      name.downcase.gsub(/[-_.]+/, '-')
    end

    def fetch_package(file, direct_deps, pip_package, version)
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
        dependency: !direct_deps.include?(normalize_pip_name(pip_package.sub(/\[[^\]]+\]/, '')))
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
