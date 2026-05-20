# frozen_string_literal: true

require 'parallel'

require_relative '../http_client'
require_relative '../package'

module SOUP
  class BaseParser
    NOASSERTION_LICENSE = 'NOASSERTION'
    public_constant :NOASSERTION_LICENSE

    UNLICENSE_PATTERN = 'Unlicense'
    private_constant :UNLICENSE_PATTERN

    def parse(_file, _packages)
      raise(NotImplementedError, "#{self.class} must implement #parse")
    end

    protected

    def parallel_each(work_items, packages, &)
      results = Parallel.map(work_items, in_threads: HttpClient::THREAD_COUNT, &)
      collect_packages(results, packages)
    end

    def collect_packages(results, packages)
      results.compact.each { |package| packages[package.package] = package }
    end

    def build_package(name:, file:, language:, version:, license:, description:, website:, dependency:)
      package = Package.new(name)
      package.file = file
      package.language = language
      package.version = version
      package.license = normalize_license(license)
      package.description = description
      package.website = website
      package.dependency = dependency
      package
    end

    def normalize_license(license)
      return license if license.nil?
      return license if license.respond_to?(:empty?) && license.empty?
      return NOASSERTION_LICENSE if license.to_s.include?(UNLICENSE_PATTERN)
      return NOASSERTION_LICENSE if license.to_s.start_with?('http')

      license
    end
  end
end
