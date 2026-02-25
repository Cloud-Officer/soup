# frozen_string_literal: true

RSpec.describe(SOUP::BundlerParser) do
  subject(:parser) { described_class.new }

  let(:spec) do
    instance_double(Bundler::LazySpecification, name: 'test-gem', version: Gem::Version.new('1.0.0'))
  end

  let(:lock_file) { instance_double(Bundler::LockfileParser, specs: [spec]) }
  let(:main_file_content) { "gem 'test-gem'" }

  let(:v2_response_body) do
    {
      licenses: ['MIT'],
      info: 'A test gem. With more info.',
      homepage_uri: 'https://example.com '
    }.to_json
  end

  before do
    allow(Bundler::LockfileParser).to(receive(:new).and_return(lock_file))
    allow(Bundler).to(receive(:read_file).with('Gemfile.lock').and_return(''))
    allow(File).to(receive(:read).and_call_original)
    allow(File).to(receive(:read).with('Gemfile').and_return(main_file_content))
  end

  it 'parses lock file and calls RubyGems v2 API' do
    stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/1.0.0.json')
      .to_return(status: 200, body: v2_response_body)

    packages = {}
    parser.parse('Gemfile.lock', packages)
    expect(packages).to(have_key('test-gem'))
    expect(packages['test-gem'].language).to(eq('Ruby'))
    expect(packages['test-gem'].version).to(eq('1.0.0'))
    expect(packages['test-gem'].license).to(eq('MIT'))
    expect(packages['test-gem'].description).to(eq('A test gem'))
    expect(packages['test-gem'].website).to(eq('https://example.com'))
    expect(packages['test-gem'].dependency).to(be(false))
  end

  it 'falls back to latest version when v2 returns 404' do
    stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/1.0.0.json')
      .to_return(status: 404, body: 'Not Found')

    stub_request(:get, 'https://api.rubygems.org/api/v1/versions/test-gem/latest.json')
      .to_return(status: 200, body: { version: '2.0.0' }.to_json)

    stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/2.0.0.json')
      .to_return(status: 200, body: v2_response_body)

    packages = {}
    parser.parse('Gemfile.lock', packages)
    expect(packages).to(have_key('test-gem'))
  end

  it 'raises when fallback latest version also fails' do
    stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/1.0.0.json')
      .to_return(status: 404, body: 'Not Found')

    stub_request(:get, 'https://api.rubygems.org/api/v1/versions/test-gem/latest.json')
      .to_return(status: 500, body: 'Internal Server Error', headers: { Status: 'Internal Server Error' })

    packages = {}
    expect { parser.parse('Gemfile.lock', packages) }
      .to(raise_error(RuntimeError))
  end

  it 'handles nil fields from API response' do
    nil_response = {
      licenses: nil,
      info: nil,
      homepage_uri: nil
    }.to_json

    stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/1.0.0.json')
      .to_return(status: 200, body: nil_response)

    packages = {}
    parser.parse('Gemfile.lock', packages)
    expect(packages['test-gem'].license).to(be_nil)
    expect(packages['test-gem'].website).to(be_nil)
  end

  it 'marks transitive dependencies' do
    allow(File).to(receive(:read).with('Gemfile').and_return("gem 'other-gem'"))

    stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/1.0.0.json')
      .to_return(status: 200, body: v2_response_body)

    packages = {}
    parser.parse('Gemfile.lock', packages)
    expect(packages['test-gem'].dependency).to(be(true))
  end
end
