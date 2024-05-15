# frozen_string_literal: true

require 'optparse'

require_relative 'status'

module SOUP
  class Options
    def initialize(argv = [])
      @argv = argv
      @auto_reply = false
      @cache_file = '.soup.json'
      @exceptions_file = "#{__dir__}/../../config/exceptions.json"
      @ignored_folders = []
      @licenses_check = false
      @licenses_file = "#{__dir__}/../../config/licenses.json"
      @markdown_file = './docs/soup.md'
      @no_prompt = false
      @parser = OptionParser.new
      @skip_bundler = false
      @skip_cocoapods = false
      @skip_composer = false
      @skip_gradle = false
      @skip_npm = false
      @skip_pip = false
      @skip_spm = false
      @skip_yarn = false
      @soup_check = false

      setup_parser
    end

    attr_reader :auto_reply, :exceptions_file, :ignored_folders, :licenses_check, :licenses_file, :markdown_file, :no_prompt, :skip_bundler, :skip_cocoapods, :skip_composer, :skip_gradle, :skip_npm, :skip_pip, :skip_spm, :skip_yarn, :soup_check, :cache_file

    def parse
      @parser.parse!(@argv)

      if !@licenses_check and !@soup_check
        @licenses_check = true
        @soup_check = true
      end

      self
    end

    private

    def setup_parser
      @parser.banner = 'Usage: soup options'
      @parser.separator('')
      @parser.separator('options')

      @parser.on('', '--cache_file file', 'Path to cached file') do |file|
        @cache_file = file
      end

      @parser.on('', '--exceptions_file file', 'Path to exception file') do |file|
        @exceptions_file = file
      end

      @parser.on('', '--ignored_folders ignored_folders', 'Comma separated list of folders to ignore') do |folders|
        @ignored_folders = folders.split(',')
      end

      @parser.on('', '--licenses', 'Check for open source licenses compliance') do
        @licenses_check = true
      end

      @parser.on('', '--licenses_file file', 'Path to authorized licenses file') do |file|
        @licenses_file = file
      end

      @parser.on('', '--markdown_file file', 'Path to generated markdown file') do |file|
        @markdown_file = file
      end

      @parser.on('', '--no_prompt', 'Do not prompt for missing information and fail immediately') do
        @no_prompt = true
      end

      @parser.on('', '--skip_bundler', 'Ignore Ruby/Bundler/Gemfile/Gemfile.lock even if detected') do
        @skip_bundler = true
      end

      @parser.on('', '--skip_cocoapods', 'Ignore Swift/CocoaPods/Podfile/Podfile.lock even if detected') do
        @skip_cocoapods = true
      end

      @parser.on('', '--skip_composer', 'Ignore PHP/Composer/composer.json/composer.lock even if detected') do
        @skip_composer = true
      end

      @parser.on('', '--skip_gradle', 'Ignore Kotlin/Gradle/build.gradle/buildscript-gradle.lockfile even if detected') do
        @skip_gradle = true
      end

      @parser.on('', '--skip_npm', 'Ignore JS/NPM/package.json/package-lock.json even if detected') do
        @skip_spm = true
      end

      @parser.on('', '--skip_pip', 'Ignore Python/PIP/requirements.txt even if detected') do
        @skip_pip = true
      end

      @parser.on('', '--skip_spm', 'Ignore Swift/SPM/Package.swift/Package.resolved even if detected') do
        @skip_spm = true
      end

      @parser.on('', '--skip_yarn', 'Ignore JS/Yarn/package.json/yarn.lock even if detected') do
        @skip_spm = true
      end

      @parser.on('', '--soup', 'Check for missing information and generate the soup.md file') do
        @soup_check = true
      end

      @parser.on('', '--auto_reply', 'Auto reply to questions prompt') do
        @auto_reply = true
      end

      @parser.on_tail('-h', '--help', 'Show this message') do
        puts(@parser)
        exit(Status::SUCCESS_EXIT_CODE)
      end
    end
  end
end
