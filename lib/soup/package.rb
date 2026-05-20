# frozen_string_literal: true

module SOUP
  class Package
    def self.sanitize_description(text, first_sentence: false, strip_markdown: false)
      return if text.nil? || text.empty?

      text = text.split(/\n|\. /).first if first_sentence
      return if text.nil?

      text = text.gsub(%r{((?:f|ht)tps?:/\S+)}, '<\1>')
      text = text.delete('_[]!|') if strip_markdown
      text
    end

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

    # Parser-produced fields. Set once during BaseParser#build_package and
    # treated as read-only afterwards. Accessors stay mutable so existing tests
    # can patch fixture content, but production code MUST NOT mutate these
    # after construction.
    attr_accessor :file, :language, :package, :version, :license, :description, :website, :dependency

    # Verification fields. Filled in by Application#check_packages from the
    # cache, dependency defaults, or interactive prompts.
    attr_accessor :last_verified_at, :risk_level, :requirements, :verification_reasoning

    # True when all four verification fields are non-empty (i.e. the package is
    # ready to be rendered into the SOUP markdown). Use this instead of
    # ad-hoc presence checks across application.rb.
    def verified?
      !last_verified_at.to_s.empty? &&
        !risk_level.to_s.empty? &&
        !requirements.to_s.empty? &&
        !verification_reasoning.to_s.empty?
    end

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
end
