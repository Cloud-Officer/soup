# frozen_string_literal: true

require 'httparty'

module SOUP
  module HttpClient
    MAX_RETRIES = 3
    DEFAULT_TIMEOUT = 5

    private_constant :MAX_RETRIES
    private_constant :DEFAULT_TIMEOUT

    def self.get(url, max_retries: MAX_RETRIES, **options)
      retries = 0

      begin
        HTTParty.get(url, { timeout: DEFAULT_TIMEOUT }.merge(options))
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        retries += 1

        if retries <= max_retries
          puts("Error: #{e.message}. Retrying (#{retries}/#{max_retries})...")
          retry
        end

        puts("Error: #{e.message}. Aborting after #{max_retries} retries.")
        raise
      end
    end
  end
end
