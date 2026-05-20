# frozen_string_literal: true

require 'etc'
require 'httparty'

module SOUP
  module HttpClient
    # Defaults are tuned for healthy public package registries (rubygems,
    # registry.npmjs, pypi, search.maven, api.github). Override at runtime
    # via SOUP_HTTP_TIMEOUT (seconds, integer) and SOUP_HTTP_MAX_RETRIES
    # (integer) for slow corporate proxies, rate-limited mirrors, or
    # air-gapped environments.
    DEFAULT_MAX_RETRIES = 3
    DEFAULT_TIMEOUT_SECONDS = 5
    THREAD_COUNT = Etc.nprocessors

    private_constant :DEFAULT_MAX_RETRIES, :DEFAULT_TIMEOUT_SECONDS
    public_constant :THREAD_COUNT

    def self.max_retries
      Integer(ENV.fetch('SOUP_HTTP_MAX_RETRIES', DEFAULT_MAX_RETRIES))
    end

    def self.default_timeout
      Integer(ENV.fetch('SOUP_HTTP_TIMEOUT', DEFAULT_TIMEOUT_SECONDS))
    end

    def self.get(url, max_retries: nil, **options)
      max_retries ||= self.max_retries
      retries = 0

      begin
        HTTParty.get(url, { timeout: default_timeout }.merge(options))
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        retries += 1

        if retries <= max_retries
          warn("Error: #{e.message}. Retrying (#{retries}/#{max_retries})...")
          retry
        end

        warn("Error: #{e.message}. Aborting after #{max_retries} retries.")
        raise
      end
    end
  end
end
