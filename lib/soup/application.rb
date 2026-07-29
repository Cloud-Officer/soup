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
require_relative 'parsers/composer'
require_relative 'parsers/generic'
require_relative 'parsers/gradle'
require_relative 'parsers/importmap'
require_relative 'parsers/manual'
require_relative 'parsers/npm'
require_relative 'parsers/pip'
require_relative 'parsers/spm'
require_relative 'parsers/yarn'
require_relative 'status'

module SOUP
  DEPENDENCY_TEXT = 'Dependency'
  private_constant :DEPENDENCY_TEXT

  PARSER_REGISTRY = {
    'buildscript-gradle.lockfile': { parser: GradleParser, skip: :skip_gradle },
    'composer.lock': { parser: ComposerParser, skip: :skip_composer },
    'Gemfile.lock': { parser: BundlerParser, skip: :skip_bundler },
    'gradle.lockfile': { parser: GradleParser, skip: :skip_gradle },
    'importmap.rb': { parser: ImportmapParser, skip: :skip_importmap },
    'Package.resolved': { parser: SPMParser, skip: :skip_spm },
    'package-lock.json': { parser: NPMParser, skip: :skip_npm },
    # Podfile.lock support removed: cocoapods-core requires activesupport < 8.
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

        validate_json!(file)
      end

      validate_cache_file!
    end

    # The cache is optional -- absent on a first run -- so it is only checked
    # when it exists and when --soup will actually read it.
    #
    # It is validated HERE rather than in read_cached_packages because by that
    # point detect_packages has already populated @detected_packages. A parse
    # error raised there escapes through the ensure-block save, which then
    # rewrites .soup.json with metadata-less entries and blanks docs/soup.md --
    # silently discarding previously entered IEC 62304 risk, requirements and
    # verification reasoning. Failing before any state exists lets save_files'
    # empty-state guard keep both files untouched.
    def validate_cache_file!
      return unless @options.soup_check
      return unless File.exist?(@options.cache_file)

      validate_json!(@options.cache_file, label: 'cache file')
    end

    def validate_json!(file, label: 'configuration file')
      JSON.parse(File.read(file))
    rescue JSON::ParserError => e
      raise(ConfigurationError, "Invalid JSON in #{label} #{file}: #{e.message}")
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

          # The skip-flag guard comes BEFORE the "Reading file" announce so the
          # user never sees "Reading file X..." for a file that is then silently
          # dropped (e.g. --skip_yarn).
          next if @options.public_send(config[:skip])

          puts("Reading file #{file}...")
          generic_parser.parse(config[:parser].new, file, @detected_packages)
        end
      end

      parse_manual_entries
      enforce_vendored_coverage
    end

    # Manually-declared SOUP entries cover vendored/proprietary components that
    # no package manager resolves. Parsed after the auto-detected packages so a
    # project can override an auto-detected entry by package name if needed.
    def parse_manual_entries
      return if @options.manual_file.to_s.empty?
      return unless File.exist?(@options.manual_file)

      puts("Reading file #{@options.manual_file}...")
      ManualParser.new.parse(@options.manual_file, @detected_packages)
    end

    # Fail the run if a committed vendored JS file (matched by --vendored_globs)
    # has no SOUP entry, so dropping a new third-party file into the repo cannot
    # silently bypass the register. Coverage is matched on the entry's `file`
    # path or basename.
    def enforce_vendored_coverage
      return if @options.vendored_globs.empty?

      declared = @detected_packages.values.filter_map { |package| package.file unless package.file.to_s.empty? }
      declared_basenames = declared.map { |path| File.basename(path) }

      @options.vendored_globs.each do |glob|
        Dir.glob(File.join(Dir.pwd, glob)).each do |file|
          relative = file.sub("#{Dir.pwd}/", '')
          next if declared.include?(relative) || declared_basenames.include?(File.basename(file))

          warn("Vendored file #{relative} has no SOUP entry; add it to #{@options.manual_file}!")
          @exit_code = Status::ERROR_EXIT_CODE
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
      license_pattern = build_license_pattern
      exceptions = JSON.parse(File.read(@options.exceptions_file))
      prompt = TTY::Prompt.new

      @detected_packages.each do |name, package|
        validate_license(package, license_pattern, exceptions)

        next unless @options.soup_check

        apply_cached_metadata(name, package)
        apply_dependency_defaults(package)
        prompt_for_metadata(package, prompt)
        ensure_metadata_complete!(package)

        package.last_verified_at = Time.now.strftime('%Y-%m-%d').to_s if package.last_verified_at.empty?

        append_markdown_row(package)
      end
    end

    # Build the allowlist matcher from --licenses_file.
    #
    # Entries are licence *families* as often as exact identifiers -- "Apache"
    # is meant to cover "Apache-2.0", "BSD" to cover "BSD-3-Clause" -- so this
    # cannot be an equality test. It used to be a bare `Regexp.union` of the
    # entries, which is an unanchored substring match: any licence string that
    # merely *contained* an entry passed the compliance gate. npm's "UNLICENSED"
    # (proprietary, no rights granted) contains "Unlicense" and sailed through,
    # as did anything containing "MIT" or "ISC" as a syllable.
    #
    # Each entry is now anchored on word boundaries. `(?<!\w)`/`(?!\w)` rather
    # than `\b` so an entry ending in punctuation still behaves, and `-`/`.`
    # deliberately remain boundaries so the family entries keep matching the
    # versioned identifiers ("apache" matches "apache-2.0") while "unlicense"
    # no longer matches "unlicensed". Mirrors BaseParser#manifest_mentions?,
    # which uses the same idiom (that one also excludes `-`, because coordinate
    # names must not match across a hyphen).
    #
    # Regexp.escape guards against an operator putting regex metacharacters in
    # their own licences.json; Regexp.union of an empty list yields a pattern
    # that matches nothing, so an empty allowlist fails every licence rather
    # than passing everything.
    def build_license_pattern
      entries = JSON.parse(File.read(@options.licenses_file))

      Regexp.union(entries.map { |entry| /(?<!\w)#{Regexp.escape(entry.downcase)}(?!\w)/ })
    end

    def validate_license(package, license_pattern, exceptions)
      return unless @options.licenses_check
      return if package.license.nil? || package.license.empty?
      return if package.license.downcase.match?(license_pattern)
      return if exceptions.include?(package.package)

      warn("Invalid license #{package.license} found in #{package.file} in package #{package.package}!")
      @exit_code = Status::ERROR_EXIT_CODE if package.license != 'NOASSERTION'
    end

    def apply_cached_metadata(name, package)
      cached = @cached_packages[name]
      return unless cached

      restore_unresolved_metadata(package, cached) if package.unresolved
      package.last_verified_at = cached['last_verified_at']
      package.risk_level = cached['risk_level']
      package.requirements = cached['requirements']
      package.verification_reasoning = cached['verification_reasoning']
    end

    # When this run could not reach the registry, keep whatever a previous run
    # resolved instead of downgrading the entry to NOASSERTION -- a transient
    # outage must not blank out metadata already recorded in the register.
    #
    # Only restored when the cached entry is for the SAME version: licenses do
    # change between releases, so carrying an older version's license onto a
    # newly pinned one would assert something we never verified.
    def restore_unresolved_metadata(package, cached)
      return unless cached['version'].to_s == package.version.to_s

      package.license = cached['license'] unless cached['license'].to_s.empty?
      package.description = cached['description'] unless cached['description'].to_s.empty?
      package.website = cached['website'] unless cached['website'].to_s.empty?
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
      # Sanitize into a local instead of mutating package.description in place.
      # Pre-fix this method re-rendered every Package twice across re-runs and
      # leaked sanitized state into the persisted .soup.json cache.
      description = sanitize_markdown_description(package.description)

      website = package.website.to_s.strip.empty? ? '' : "<#{package.website}>"
      cells =
        [
          package.language,
          package.package,
          package.version,
          package.license,
          description,
          website,
          package.last_verified_at,
          package.risk_level,
          package.requirements,
          package.verification_reasoning
        ].map { |cell| markdown_cell(cell) }
      @markdown += "|#{cells.join('|')}|\n"
    end

    def sanitize_markdown_description(raw)
      return raw if raw.nil? || raw.empty?

      stripped = raw.delete('|').gsub('  ', ' ')
      Nokogiri::HTML.fragment(stripped).text
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
