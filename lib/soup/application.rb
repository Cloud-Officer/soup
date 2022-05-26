# frozen_string_literal: true

require 'inquirer'
require 'json'

require_relative '../soup'
require_relative 'options'
require_relative 'parsers/bundler'
require_relative 'parsers/cocoapods'
require_relative 'parsers/composer'
require_relative 'parsers/generic'
require_relative 'parsers/pip'
require_relative 'parsers/spm'
require_relative 'status'

module SOUP
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
      detect_packages
      read_cached_packages
      check_packages
      save_files
      @exit_code
    end

    private

    def configure_options(argv)
      Options.new(argv).parse
    rescue OptionParser::InvalidOption => e
      puts("Error: #{e}")
      exit(Status::ERROR_EXIT_CODE)
    end

    def detect_packages
      parser = GenericParser.new

      PACKAGE_MANAGERS.each do |package_file|
        Dir.glob("#{Dir.pwd}/**/#{package_file}") do |file|
          case File.basename(file)
          when 'composer.lock'
            next if @options.skip_composer

            parser.parse(ComposerParser.new, file, @detected_packages)

          when 'Gemfile.lock'
            next if @options.skip_bundler

            parser.parse(BundlerParser.new, file, @detected_packages)

          when 'Package.resolved'
            next if @options.skip_spm

            parser.parse(SPMParser.new, file, @detected_packages)

          when 'Podfile.lock'
            next if @options.skip_cocoapods

            next unless RUBY_PLATFORM =~ /darwin/i

            parser.parse(CocoaPodsParser.new, file, @detected_packages)

          when 'requirements.txt'
            next if @options.skip_pip

            parser.parse(PIPParser.new, file, @detected_packages)

          else
            raise("Unknown file #{File.basename(file)}!")
          end
        end
      end

      @detected_packages = @detected_packages.sort.to_h
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

      @detected_packages.each do |name, package|
        if @options.licenses_check && !package.license.nil? && !package.license.empty?
          found = false

          licenses.each do |license|
            if package.license.downcase.include?(license)
              found = true
              break
            end
          end

          unless found
            puts("Invalid license #{package.license} found in #{package.file} in package #{package.package}!")
            @exit_code = Status::ERROR_EXIT_CODE if package.license != 'NOASSERTION'
          end
        end

        next unless @options.soup_check

        if @cached_packages[name]
          package.last_verified_at = @cached_packages[name]['last_verified_at']
          package.risk_level = @cached_packages[name]['risk_level']
          package.requirements = @cached_packages[name]['requirements']
          package.verification_reasoning = @cached_packages[name]['verification_reasoning']
        end

        if package.dependency
          package.risk_level = RISK_LEVELS[0]
          package.requirements = 'Dependency'
          package.verification_reasoning = 'Dependency'
        end

        if package.risk_level.empty?
          raise("No risk level found for #{package.package}!") if @options.no_prompt

          package.risk_level = RISK_LEVELS[Ask.list("Enter risk level for package #{package.package}", RISK_LEVELS_SCREEN)]
        end

        if package.requirements.empty?
          raise("No requirements found for #{package.package}!") if @options.no_prompt

          package.requirements = Ask.input("Enter requirements for package #{package.package}")
        end

        if package.verification_reasoning.empty?
          raise("No verification reasoning found for #{package.package}!") if @options.no_prompt

          package.verification_reasoning = Ask.input("Enter verification reasoning for package #{package.package}")
        end

        raise("Missing information for #{package.package}!") if package.risk_level.empty? or package.requirements.empty? or package.verification_reasoning.empty?

        package.last_verified_at = Time.now.strftime('%Y-%m-%d').to_s if package.last_verified_at.empty?
        @markdown += "| #{package.language} | #{package.package} | #{package.version} | #{package.license} | #{package.description} | <#{package.website}> | #{package.last_verified_at} | #{package.risk_level} | #{package.requirements} | #{package.verification_reasoning} |\n"
      end
    end

    def save_files
      return unless @options.soup_check

      File.write(@options.cache_file, JSON.pretty_generate(@detected_packages))
      File.write(@options.markdown_file, @markdown)
    end
  end
end
