# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'nokogiri'
require 'tty-prompt'

require_relative '../soup'
require_relative 'errors'
require_relative 'http_client'
require_relative 'options'
require_relative 'parsers/bundler'
# require_relative 'parsers/cocoapods'
require_relative 'parsers/composer'
require_relative 'parsers/generic'
require_relative 'parsers/gradle'
require_relative 'parsers/npm'
require_relative 'parsers/pip'
require_relative 'parsers/spm'
require_relative 'parsers/yarn'
require_relative 'status'

DEPENDENCY_TEXT = 'Dependency'

module SOUP
  PARSER_REGISTRY = {
    'buildscript-gradle.lockfile': { parser: GradleParser, skip: :skip_gradle },
    'composer.lock': { parser: ComposerParser, skip: :skip_composer },
    'Gemfile.lock': { parser: BundlerParser, skip: :skip_bundler },
    'gradle.lockfile': { parser: GradleParser, skip: :skip_gradle },
    'Package.resolved': { parser: SPMParser, skip: :skip_spm },
    'package-lock.json': { parser: NPMParser, skip: :skip_npm },
    'Podfile.lock': { parser: nil, skip: :skip_cocoapods }, # Disabled: cocoapods-core requires activesupport < 8
    'requirements.txt': { parser: PIPParser, skip: :skip_pip },
    'yarn.lock': { parser: YarnParser, skip: :skip_yarn }
  }.freeze

  private_constant :PARSER_REGISTRY

  # Represents an instance of a soup application. This is the entry point for all invocations of soup from the command line.
  class Application
    def initialize(argv)
      @options = configure_options(argv)
      @cached_packages = {}
      @detected_packages = {}
      @markdown = ''
      @exit_code = Status::SUCCESS_EXIT_CODE
    end

    def execute
      validate_config!
      detect_packages
      read_cached_packages
      check_packages
      save_files
      @exit_code
    ensure
      save_files if @options&.soup_check
    end

    private

    def validate_config!
      [@options.licenses_file, @options.exceptions_file].each do |file|
        raise(ConfigurationError, "Configuration file not found: #{file}") unless File.exist?(file)

        begin
          JSON.parse(File.read(file))
        rescue JSON::ParserError => e
          raise(ConfigurationError, "Invalid JSON in configuration file #{file}: #{e.message}")
        end
      end
    end

    def markdown_cell(value)
      value = value.to_s
      return ' ' if value.strip.empty?

      # Collapse any whitespace run (including embedded newlines and tabs) to a single
      # space so a multi-line package description does not break the markdown table.
      value = value.gsub(/\s+/, ' ')
      # Strip leading/trailing spaces inside backtick code spans (MD038 lint rule)
      # Using [^`]* instead of \s*(.*?)\s* to avoid ReDoS vulnerability
      value = value.strip.gsub(/`([^`]*)`/) { "`#{Regexp.last_match(1).strip}`" }
      " #{value} "
    end

    def configure_options(argv)
      Options.new(argv).parse
    rescue OptionParser::ParseError => e
      warn("Error: #{e}")
      exit(Status::ERROR_EXIT_CODE)
    end

    def detect_packages
      generic_parser = GenericParser.new

      PARSER_REGISTRY.each do |package_file, config|
        Dir.glob("#{Dir.pwd}/**/#{package_file}").each do |file|
          next if file.include?('/node_modules/')

          next if file.include?('/vendor/')

          if @options.ignored_folders.any? { |folder| File.fnmatch?(File.join(File.expand_path(folder), '**'), file) }
            puts("Skipping file #{file} because it is in an ignored folder.")
            next
          end

          puts("Reading file #{file}...")
          next if @options.public_send(config[:skip])
          next if config[:parser].nil?

          generic_parser.parse(config[:parser].new, file, @detected_packages)
        end
      end
    end

    def read_cached_packages
      return unless @options.soup_check

      @cached_packages =
        if File.exist?(@options.cache_file)
          JSON.parse(File.read(@options.cache_file))
        else
          {}
        end

      @markdown = "# Software of Unknown Provenance\n\n| **Language** | **Package** | **Version** | **License** | **Description** | **Website** | **Last Verified** | **Risk Level** | **Requirements** | **Verification Reasoning** |\n| :---: | :--- | :---: | :---: | :--- | :--- | :---: | :---: | :--- | :--- |\n"
    end

    def check_packages
      licenses = JSON.parse(File.read(@options.licenses_file)).map!(&:downcase)
      exceptions = JSON.parse(File.read(@options.exceptions_file))
      prompt = TTY::Prompt.new

      @detected_packages.each do |name, package|
        validate_license(package, licenses, exceptions)

        next unless @options.soup_check

        apply_cached_metadata(name, package)
        apply_dependency_defaults(package)
        prompt_for_metadata(package, prompt)
        ensure_metadata_complete!(package)

        package.last_verified_at = Time.now.strftime('%Y-%m-%d').to_s if package.last_verified_at.empty?

        append_markdown_row(package)
      end
    end

    def validate_license(package, licenses, exceptions)
      return unless @options.licenses_check
      return if package.license.nil? || package.license.empty?
      return if licenses.any? { |license| package.license.downcase.include?(license) }
      return if exceptions.include?(package.package)

      warn("Invalid license #{package.license} found in #{package.file} in package #{package.package}!")
      @exit_code = Status::ERROR_EXIT_CODE if package.license != 'NOASSERTION'
    end

    def apply_cached_metadata(name, package)
      cached = @cached_packages[name]
      return unless cached

      package.last_verified_at = cached['last_verified_at']
      package.risk_level = cached['risk_level']
      package.requirements = cached['requirements']
      package.verification_reasoning = cached['verification_reasoning']
    end

    def apply_dependency_defaults(package)
      return unless package.dependency

      package.risk_level = RISK_LEVELS_SCREEN.first.split.first
      package.requirements = DEPENDENCY_TEXT
      package.verification_reasoning = DEPENDENCY_TEXT
    end

    def prompt_for_metadata(package, prompt)
      prompt_missing_field(
        package,
        prompt,
        field: :risk_level,
        label: 'risk level',
        default_value: RISK_LEVELS_SCREEN.first.split.first
      ) { |p, pkg| p.select("Enter risk level for package #{pkg.package}", RISK_LEVELS_SCREEN).split.first }

      prompt_missing_field(
        package,
        prompt,
        field: :requirements,
        label: 'requirements',
        default_value: DEPENDENCY_TEXT
      ) { |p, pkg| p.ask("Enter requirements for package #{pkg.package}: ") }

      prompt_missing_field(
        package,
        prompt,
        field: :verification_reasoning,
        label: 'verification reasoning',
        default_value: DEPENDENCY_TEXT
      ) { |p, pkg| p.ask("Enter verification reasoning for package #{pkg.package}: ") }
    end

    def prompt_missing_field(package, prompt, field:, label:, default_value:)
      return unless package.public_send(field).to_s.empty?

      if @options.auto_reply
        package.public_send(:"#{field}=", default_value)
        return
      end

      raise(MissingMetadataError, "No #{label} found for #{package.package}!") if @options.no_prompt

      package.public_send(:"#{field}=", yield(prompt, package))
    end

    def ensure_metadata_complete!(package)
      return unless package.risk_level.empty? || package.requirements.empty? || package.verification_reasoning.empty?

      raise(MissingMetadataError, "Missing information for #{package.package}!")
    end

    def append_markdown_row(package)
      if package.description
        package.description = package.description.delete('|')
        package.description = package.description.gsub('  ', ' ')
        package.description = Nokogiri::HTML.fragment(package.description).text
      end

      website = package.website.to_s.strip.empty? ? '' : "<#{package.website}>"
      cells =
        [
          package.language,
          package.package,
          package.version,
          package.license,
          package.description,
          website,
          package.last_verified_at,
          package.risk_level,
          package.requirements,
          package.verification_reasoning
        ].map { |cell| markdown_cell(cell) }
      @markdown += "|#{cells.join('|')}|\n"
    end

    def save_files
      return unless @options.soup_check
      # Guard against ensure-block invocations that fire before any work has been
      # done (e.g. validate_config! raised). Without this, an early failure would
      # overwrite the existing .soup.json with {} and the markdown file with ''.
      return if @detected_packages.empty? && @markdown.empty?

      File.write(@options.cache_file, JSON.pretty_generate(@detected_packages))
      FileUtils.mkdir_p(File.dirname(@options.markdown_file))
      File.write(@options.markdown_file, @markdown)
    end
  end
end
