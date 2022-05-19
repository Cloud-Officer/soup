#!/usr/bin/env ruby
#
# to install just run the following assuming you already have ruby and bundler available
#     bundle install
#

# frozen_string_literal: true

require 'bundler'
require 'cocoapods-core' if RUBY_PLATFORM =~ /darwin/i
require 'httparty'
require 'inquirer'
require 'json'
require 'optparse'
require 'semantic'

LICENSES = %w[Apache BSD BSL Boost Copyright HPND ISC MIT PSF Python zlib]
PACKAGE_MANAGERS = %w[composer.lock Gemfile.lock Package.resolved Podfile.lock requirements.txt].freeze
RISK_LEVELS = %w[Low Medium High].freeze
RISK_LEVELS_SCREEN =
  [
    'Low (can’t lead to harm)',
    'Medium (can lead to reversible harm)',
    'High (can lead to irreversible harm)'
  ].freeze
SOUP_FILE = './docs/soup.md'
SOUP_CACHE_FILE = '.soup.json'

class Soup
  def initialize(package)
    raise('No package specified!') if package.nil?

    @file = ''
    @language = ''
    @package = package
    @version = ''
    @license = ''
    @description = ''
    @website = ''
    @last_verified_at = ''
    @risk_level = ''
    @requirements = ''
    @verification_reasoning = ''
    @dependency = false
  end

  # accessor get and set method
  attr_accessor :file, :language, :package, :version, :license, :description, :website, :last_verified_at, :risk_level, :requirements, :verification_reasoning, :dependency

  def as_json(_options = {})
    {
      language: @language,
      package: @package,
      version: @version,
      license: @license,
      description: @description,
      website: @website,
      last_verified_at: @last_verified_at,
      risk_level: @risk_level,
      requirements: @requirements,
      verification_reasoning: @verification_reasoning
    }
  end

  def to_json(*options)
    as_json(*options).to_json(*options)
  end
end

begin
  # parse command line options

  options = {}

  OptionParser.new do |opts|
    opts.banner = 'Usage: soup.rb options'
    opts.separator('')
    opts.separator('options')

    opts.on('--licenses')
    opts.on('--no_prompt')
    opts.on('--skip_bundler')
    opts.on('--skip_cocoapods')
    opts.on('--skip_composer')
    opts.on('--skip_pip')
    opts.on('--skip_spm')
    opts.on('--soup')
    opts.on('-h', '--help') do
      puts(opts)
      exit(1)
    end
  end.parse!(into: options)

  mandatory = %i[]
  missing = mandatory.select { |param| options[param].nil? }
  raise(OptionParser::MissingArgument, missing.join(', ')) unless missing.empty?

  if options[:licenses].nil? and options[:soup].nil?
    options[:licenses] = true
    options[:soup] = true
  end

  detected_soups = {}
  LICENSES.map!(&:downcase)

  PACKAGE_MANAGERS.each do |package_file|
    Dir.glob("#{Dir.pwd}/**/#{package_file}") do |file|
      case File.basename(file)
      when 'composer.lock'
        next if options[:skip_composer]

        package_manager_lock_file = JSON.parse(File.read(file))
        package_manager_file = File.read(file.gsub('lock', 'json'))

        package_manager_lock_file['packages'].each do |package|
          soup = Soup.new(package['name'])
          soup.file = file
          soup.language = 'PHP'
          soup.version = package['version']&.strip
          soup.license = package['license']&.first&.tr('()', '  ')&.strip&.split&.first
          soup.description = package['description']&.split(/\n|\. /)&.first&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
          soup.website = package['homepage']&.strip
          soup.dependency = !package_manager_file.include?(soup.package)
          detected_soups[soup.package] = soup
        end

      when 'Gemfile.lock'
        next if options[:skip_bundler]

        package_manager_lock_file = {}
        package_manager_file = ''

        Dir.chdir(File.dirname(file)) do
          package_manager_lock_file = Bundler::LockfileParser.new(Bundler.read_file(file))
          package_manager_file = File.read(file.gsub('.lock', ''))
        end

        package_manager_lock_file.specs.each do |package|
          response = HTTParty.get("https://api.rubygems.org/api/v2/rubygems/#{package.name}/versions/#{package.version}.json")

          raise(response.message) unless response.code == 200

          package_details = JSON.parse(response.body)
          soup = Soup.new(package.name)
          soup.file = file
          soup.language = 'Ruby'
          soup.version = package.version&.to_s&.strip
          soup.license = package_details['licenses']&.first&.strip
          soup.description = package_details['info']&.split(/\n|\. /)&.first&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
          soup.website = package_details['homepage_uri']&.strip
          soup.dependency = !package_manager_file.include?(soup.package)
          detected_soups[soup.package] = soup
        end

      when 'Package.resolved'
        next if options[:skip_spm]

        package_manager_lock_file = JSON.parse(File.read(file))
        package_manager_lock_file = package_manager_lock_file['object'] if package_manager_lock_file['object']
        package_manager_file =
          if File.exist?(file.gsub('resolved', 'swift'))
            File.read(file.gsub('resolved', 'swift'))
          else
            File.read("#{file.split('.').first}.xcodeproj/project.pbxproj")
          end

        headers =
          if ENV.fetch('GITHUB_TOKEN', '').empty?
            nil
          else
            {
              headers: { Authorization: "token #{ENV.fetch('GITHUB_TOKEN', '')}" }
            }
          end

        package_manager_lock_file['pins'].each do |package|
          location = package['location'] || package['repositoryURL']
          url = "https://api.github.com/repos/#{location.gsub('git@github.com:', '').gsub('https://github.com/', '').gsub('.git', '')}"

          response =
            if headers
              HTTParty.get(url, headers)
            else
              HTTParty.get(url)
            end

          raise("Error: #{response.message}! Please set GITHUB_TOKEN.") if response.message.include?('rate limit')

          next unless response.code == 200

          package_details = JSON.parse(response.body)

          next if package_details['private']

          soup = Soup.new(package_details['name'])
          soup.file = file
          soup.language = 'Swift'
          soup.version = package['state']['version']&.strip
          soup.license = package_details['license']['spdx_id']&.strip
          soup.description = package_details['description']&.split(/\n|\. /)&.first&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
          soup.website = package_details['html_url']&.strip
          soup.dependency = !package_manager_file.include?(soup.package)
          detected_soups[soup.package] = soup
        end

      when 'Podfile.lock'
        next if options[:skip_cocoapods]

        next unless RUBY_PLATFORM =~ /darwin/i

        package_manager_lock_file = Pod::Lockfile.from_file(Pathname.new(file))
        package_manager_file = File.read(file.gsub('.lock', '')).gsub('/', '')
        source = Pod::Source.new("#{Dir.home}/.cocoapods/repos/trunk")

        _key, pods = package_manager_lock_file&.pods_by_spec_repo&.first

        pods.each do |pod|
          version = Semantic::Version.new(package_manager_lock_file&.version(pod)&.version)
          version.patch = 0 if version.patch != 0

          begin
            package_details = source.specification(pod.gsub('/', '').gsub('Only', ''), version).attributes_hash
          rescue Pod::StandardError
            next
          end

          soup = Soup.new(pod)
          soup.file = file
          soup.language = 'Swift'
          soup.version = package_details['version'].strip
          soup.license = package_details['license']['type']&.strip
          soup.description = package_details['description'].split(/\n|\. /)&.first&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
          soup.website = package_details['homepage'].strip
          soup.dependency = !package_manager_file.include?(soup.package)
          detected_soups[soup.package] = soup
        end

      when 'requirements.txt'
        next if options[:skip_pip]

        File.open(file, 'r').each_line do |line|
          package, version = line.split(/==/)

          next if package.strip.empty?

          response = HTTParty.get("https://pypi.python.org/pypi/#{package}/json")

          raise(response.message) unless response.code == 200

          package_details = JSON.parse(response.body)
          soup = Soup.new(package)
          soup.file = file
          soup.language = 'Python'
          soup.version = version&.strip
          soup.license = package_details['info']['license']&.strip
          soup.description = package_details['info']['summary']&.split(/\n|\. /)&.first&.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
          soup.website = package_details['info']['home_page']&.strip
          soup.dependency = false
          detected_soups[soup.package] = soup
        end

      else
        raise("Unknown file #{File.basename(file)}!")
      end
    end
  end

  exit_code = 0
  cached_soups = {}
  soup_md = ''

  if options[:soup]
    cached_soups =
      if File.exist?(SOUP_CACHE_FILE)
        JSON.parse(File.read(SOUP_CACHE_FILE))
      else
        {}
      end

    soup_md = "# Software of Unknown Provenance\n\n| **Language** | **Package** | **Version** | **License** | **Description** | **Website** | **Last Verified** | **Risk Level** | **Requirements** | **Verification Reasoning** |\n| :---: | :--- | :---: | :---: | :--- | :--- | :---: | :---: | :--- | :--- |\n"
  end

  detected_soups = detected_soups.sort.to_h

  detected_soups.each do |package, soup|
    if options[:licenses] && !soup.license.nil? && !soup.license.empty?
      found = false

      LICENSES.each do |license|
        if soup.license.downcase.include?(license)
          found = true
          break
        end
      end

      unless found
        puts("Invalid license #{soup.license} found in #{soup.file} in package #{soup.package}!")
        exit_code = 1 if soup.license != 'NOASSERTION'
      end
    end

    next unless options[:soup]

    if cached_soups[package]
      soup.last_verified_at = cached_soups[package]['last_verified_at']
      soup.risk_level = cached_soups[package]['risk_level']
      soup.requirements = cached_soups[package]['requirements']
      soup.verification_reasoning = cached_soups[package]['verification_reasoning']
    end

    if soup.dependency
      soup.risk_level = RISK_LEVELS[0]
      soup.requirements = 'Dependency'
      soup.verification_reasoning = 'Dependency'
    end

    if soup.risk_level.empty?
      raise("No risk level found for #{soup.package}!") if options[:no_prompt]

      soup.risk_level = RISK_LEVELS[Ask.list("Enter risk level for package #{soup.package}", RISK_LEVELS_SCREEN)]
    end

    if soup.requirements.empty?
      raise("No requirements found for #{soup.package}!") if options[:no_prompt]

      soup.requirements = Ask.input("Enter requirements for package #{soup.package}")
    end

    if soup.verification_reasoning.empty?
      raise("No verification reasoning found for #{soup.package}!") if options[:no_prompt]

      soup.verification_reasoning = Ask.input("Enter verification reasoning for package #{soup.package}")
    end

    raise("Missing information for #{soup.package}!") if soup.risk_level.empty? or soup.requirements.empty? or soup.verification_reasoning.empty?

    soup.last_verified_at = Time.now.strftime('%Y-%m-%d').to_s if soup.last_verified_at.empty?
    soup_md += "| #{soup.language} | #{soup.package} | #{soup.version} | #{soup.license} | #{soup.description} | <#{soup.website}> | #{soup.last_verified_at} | #{soup.risk_level} | #{soup.requirements} | #{soup.verification_reasoning} |\n"
  end

  if options[:soup]
    Dir.mkdir('docs') unless Dir.exist?('docs')
    File.write(SOUP_CACHE_FILE, JSON.pretty_generate(detected_soups))
    File.write(SOUP_FILE, soup_md)
  end

  exit(exit_code)
rescue StandardError => e
  puts(e)
  puts(e.backtrace)
  exit(1)
end
