# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  enable_coverage :branch
  minimum_coverage line: 80, branch: 80
end

require 'fileutils'
require 'tmpdir'
require 'webmock/rspec'
require_relative '../lib/soup/application'

# TEST-12 helpers: write parser fixture files into a per-example tmpdir
# instead of stubbing File.read / File.foreach / File.readlines. Returns the
# absolute path of the written file so parser specs can pass it to
# Parser#parse the same way detect_packages would in production. The tmpdir is
# cleaned up by an after-each hook in RSpec.configure below.
module SoupFixtureHelpers
  def fixture_dir
    @fixture_dir ||= Dir.mktmpdir('soup-spec-')
  end

  def write_fixture(relative_path, content)
    path = File.join(fixture_dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end
end

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

  config.include(SoupFixtureHelpers)

  config.after do
    next unless instance_variable_defined?(:@fixture_dir) && @fixture_dir

    FileUtils.rm_rf(@fixture_dir)
  end
end
