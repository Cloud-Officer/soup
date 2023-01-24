# frozen_string_literal: true

require 'optparse'

require_relative 'status'

module SOUP
  class Options
    def initialize(argv = [])
      @argv = argv
      @parser = OptionParser.new
      @cache_file = '.soup.json'
      @licenses_check = false
      @licenses_file = "#{__dir__}/../../conf/licenses.json"
      @markdown_file = './docs/soup.md'
      @no_prompt = false
      @skip_bundler = false
      @skip_cocoapods = false
      @skip_composer = false
      @skip_pip = false
      @skip_spm = false
      @soup_check = false
      @auto_reply = false

      setup_parser
    end

    attr_reader :cache_file, :licenses_check, :licenses_file, :markdown_file, :no_prompt, :skip_bundler, :skip_cocoapods, :skip_composer, :skip_pip, :skip_spm, :soup_check, :auto_reply

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

      @parser.on('', '--cache_file', 'Path to cached file') do |file|
        @cache_file = file
      end

      @parser.on('', '--licenses', 'Check for open source licenses compliance') do
        @licenses_check = true
      end

      @parser.on('', '--licenses_file', 'Path to authorized licenses file') do |file|
        @licenses_file = file
      end

      @parser.on('', '--markdown_file', 'Path to generated markdown file') do |file|
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

      @parser.on('', '--skip_pip', 'Ignore Python/PIP/requirements.txt even if detected') do
        @skip_pip = true
      end

      @parser.on('', '--skip_spm', 'Ignore Swift/SPM/Package.swift/Package.resolved even if detected') do
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
