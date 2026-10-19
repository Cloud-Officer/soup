# frozen_string_literal: true

require 'etc'
require 'httparty'
require 'net/http'
require 'openssl'

require_relative 'errors'

module SOUP
  module HttpClient
    # Defaults are tuned for healthy public package registries (rubygems,
    # registry.npmjs, pypi, repo1.maven, api.github). Override at runtime
    # via SOUP_HTTP_TIMEOUT (seconds, integer) and SOUP_HTTP_MAX_RETRIES
    # (integer) for slow corporate proxies, rate-limited mirrors, or
    # air-gapped environments.
    DEFAULT_MAX_RETRIES = 3
    DEFAULT_TIMEOUT_SECONDS = 5
    THREAD_COUNT = Etc.nprocessors

    # Every network fault that is worth another attempt, and the single source
    # of truth for "transient" across the codebase: `.get` retries these and
    # BaseParser#registry_response rescues this same list. Keeping one list is
    # the point -- when the retry set and the parser rescue set were maintained
    # separately, they drifted to timeouts-only and a lone connection reset
    # escaped into Parallel.map, which propagates the first exception and
    # aborted every other in-flight lookup in the scan.
    #
    # - Net::OpenTimeout / ReadTimeout / WriteTimeout: registry slow or wedged
    # - Errno::ECONNRESET / EPIPE: peer or proxy dropped an established socket
    # - Errno::ECONNREFUSED / EHOSTUNREACH / ENETUNREACH: mirror down or a
    #   routing blip; a Gradle mirror loop wants to fall through to the next one
    # - SocketError: DNS resolution failure, routinely momentary in CI
    # - OpenSSL::SSL::SSLError: TLS handshake interrupted mid-negotiation
    # - EOFError / Net::HTTPBadResponse: connection closed or truncated
    #   mid-response, leaving an unparseable reply
    #
    # Deliberately excluded: HTTP status codes. A 4xx/5xx is a *response*, not a
    # transport failure -- callers inspect `response.code` and decide; GitHub
    # rate-limit and bad-credentials responses (SPM and GHA) abort the scan.
    TRANSIENT_ERRORS = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Net::WriteTimeout,
      Net::HTTPBadResponse,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH,
      Errno::ENETUNREACH,
      Errno::EPIPE,
      SocketError,
      OpenSSL::SSL::SSLError,
      EOFError
    ].freeze

    private_constant :DEFAULT_MAX_RETRIES, :DEFAULT_TIMEOUT_SECONDS
    public_constant :THREAD_COUNT, :TRANSIENT_ERRORS

    Settings = Struct.new(:max_retries, :timeout)
    SETTINGS = Settings.new
    private_constant :Settings, :SETTINGS

    def self.validate_env!
      SETTINGS.max_retries = env_integer('SOUP_HTTP_MAX_RETRIES', DEFAULT_MAX_RETRIES, minimum: 0)
      SETTINGS.timeout = env_integer('SOUP_HTTP_TIMEOUT', DEFAULT_TIMEOUT_SECONDS, minimum: 1)
    end

    def self.max_retries
      validate_env! if SETTINGS.max_retries.nil?
      SETTINGS.max_retries
    end

    def self.default_timeout
      validate_env! if SETTINGS.timeout.nil?
      SETTINGS.timeout
    end

    def self.env_integer(name, default, minimum:)
      raw = ENV.fetch(name, nil)
      return default if raw.nil?

      value = Integer(raw, exception: false)
      return value if value && value >= minimum

      raise(ConfigurationError, "#{name} must be an integer >= #{minimum}, got #{raw.inspect}")
    end

    private_class_method :env_integer

    def self.get(url, max_retries: nil, **options)
      max_retries ||= self.max_retries
      retries = 0

      begin
        HTTParty.get(url, { timeout: default_timeout }.merge(options))
      rescue *TRANSIENT_ERRORS => e
        retries += 1

        if retries <= max_retries
          warn("Error: #{e.class}: #{e.message}. Retrying (#{retries}/#{max_retries})...")
          retry
        end

        warn("Error: #{e.class}: #{e.message}. Aborting after #{max_retries} retries.")
        raise
      end
    end
  end
end
