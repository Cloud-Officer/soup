# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  enable_coverage :branch
  minimum_coverage line: 80, branch: 80
end

require 'webmock/rspec'
require_relative '../lib/soup/application'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  # Run specs in random order to surface order dependencies
  config.order = :random
  Kernel.srand(config.seed)

  config.expect_with(:rspec) do |c|
    c.syntax = :expect
  end

  # Disable external HTTP requests by default
  WebMock.disable_net_connect!(allow_localhost: true)
end
