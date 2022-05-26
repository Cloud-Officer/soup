# frozen_string_literal: true

module SOUP
  class Package
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
end
