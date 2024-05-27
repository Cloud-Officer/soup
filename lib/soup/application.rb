# frozen_string_literal: true

require 'fileutils'
require 'inquirer'
require 'json'

require_relative '../soup'
require_relative 'options'
require_relative 'parsers/bundler'
require_relative 'parsers/cocoapods'
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
        Dir.glob("#{Dir.pwd}/**/#{package_file}").each do |file|
          next if file.include?('/node_modules/')

          next if file.include?('/vendor/')

          if @options.ignored_folders.any? { |folder| File.fnmatch?(File.join(File.expand_path(folder), '**'), file) }
            puts("Skipping file #{file} because it is in an ignored folder.")
            next
          end

          puts("Reading file #{file}...")

          case File.basename(file)
          when 'buildscript-gradle.lockfile'
            next if @options.skip_gradle

            parser.parse(GradleParser.new, file, @detected_packages)

          when 'composer.lock'
            next if @options.skip_composer

            parser.parse(ComposerParser.new, file, @detected_packages)

          when 'Gemfile.lock'
            next if @options.skip_bundler

            parser.parse(BundlerParser.new, file, @detected_packages)

          when 'Package.resolved'
            next if @options.skip_spm

            parser.parse(SPMParser.new, file, @detected_packages)

          when 'package-lock.json'
            next if @options.skip_npm

            parser.parse(NPMParser.new, file, @detected_packages)

          when 'Podfile.lock'
            next if @options.skip_cocoapods

            next unless RUBY_PLATFORM =~ /darwin/i

            parser.parse(CocoaPodsParser.new, file, @detected_packages)

          when 'requirements.txt'
            next if @options.skip_pip

            parser.parse(PIPParser.new, file, @detected_packages)

          when 'yarn.lock'
            next if @options.skip_yarn

            parser.parse(YarnParser.new, file, @detected_packages)

          else
            raise("Unknown file #{File.basename(file)}!")
          end
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

      @detected_packages.each do |name, package|
        if @options.licenses_check && !package.license.nil? && !package.license.empty?
          found = false

          licenses.each do |license|
            if package.license.downcase.include?(license)
              found = true
              break
            end
          end

          found = true if exceptions.include?(package.package)

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
          package.risk_level = RISK_LEVELS.first
          package.requirements = DEPENDENCY_TEXT
          package.verification_reasoning = DEPENDENCY_TEXT
        end

        if package.risk_level.empty?
          if @options.auto_reply
            package.risk_level = RISK_LEVELS.first
          else
            raise("No risk level found for #{package.package}!") if @options.no_prompt

            package.risk_level = RISK_LEVELS[Ask.list("Enter risk level for package #{package.package}", RISK_LEVELS_SCREEN)]
          end
        end

        if package.requirements.empty?
          if @options.auto_reply
            package.requirements = DEPENDENCY_TEXT
          else
            raise("No requirements found for #{package.package}!") if @options.no_prompt

            package.requirements = Ask.input("Enter requirements for package #{package.package}")
          end
        end

        if package.verification_reasoning.empty?
          if @options.auto_reply
            package.verification_reasoning = DEPENDENCY_TEXT
          else
            raise("No verification reasoning found for #{package.package}!") if @options.no_prompt

            package.verification_reasoning = Ask.input("Enter verification reasoning for package #{package.package}")
          end
        end

        raise("Missing information for #{package.package}!") if package.risk_level.empty? or package.requirements.empty? or package.verification_reasoning.empty?

        package.last_verified_at = Time.now.strftime('%Y-%m-%d').to_s if package.last_verified_at.empty?

        if package.description
          package.description = package.description.gsub('|', '')
          package.description = package.description.gsub('  ', ' ')
          package.description = package.description.gsub(/<.*>/, 'HTML text removed. Please check the website.')
        end

        @markdown += "| #{package.language} | #{package.package} | #{package.version} | #{package.license} | #{package.description} | <#{package.website}> | #{package.last_verified_at} | #{package.risk_level} | #{package.requirements} | #{package.verification_reasoning} |\n"
      end
    end

    def save_files
      return unless @options.soup_check

      File.write(@options.cache_file, JSON.pretty_generate(@detected_packages))
      FileUtils.mkdir_p(File.dirname(@options.markdown_file))
      File.write(@options.markdown_file, @markdown)
    end
  end
end
