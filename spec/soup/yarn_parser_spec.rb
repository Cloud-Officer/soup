# frozen_string_literal: true

RSpec.describe(SOUP::YarnParser) do
  subject(:parser) { described_class.new }

  let(:parsed_lock) do
    [
      { name: 'lodash', version: '4.17.21' }
    ]
  end

  let(:main_file) { '{"dependencies":{"lodash":"^4.17.0"}}' }

  let(:registry_response) do
    {
      versions: {
        '4.17.21': {
          license: 'MIT',
          description: '_Lodash_ library',
          homepage: 'https://lodash.com/'
        }
      }
    }.to_json
  end

  before do
    allow(YarnLockParser::Parser).to(receive(:parse).with('yarn.lock').and_return(parsed_lock))
    allow(File).to(receive(:read).and_call_original)
    allow(File).to(receive(:read).with('package.json').and_return(main_file))
  end

  context 'with successful registry response' do
    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 200, body: registry_response)
    end

    it 'parses via YarnLockParser and calls NPM registry', :aggregate_failures do
      packages = {}
      parser.parse('yarn.lock', packages)
      expect(packages['lodash'].language).to(eq('JS'))
      expect(packages['lodash'].version).to(eq('4.17.21'))
      expect(packages['lodash'].license).to(eq('MIT'))
    end
  end

  context 'when package.json has vendor dependency' do
    before do
      allow(File).to(
        receive(:read).with('package.json')
                                         .and_return('{"dependencies":{"lodash": "file:vendor/lodash"}}')
      )
    end

    it 'skips vendor packages' do
      packages = {}
      parser.parse('yarn.lock', packages)
      expect(packages).to(be_empty)
    end
  end

  it 'raises on non-200 response' do
    stub_request(:get, 'https://registry.npmjs.org/lodash')
      .to_return(status: 500, body: 'Server Error')
    packages = {}
    expect { parser.parse('yarn.lock', packages) }
      .to(raise_error(RuntimeError))
  end

  it 'handles timeout gracefully', :aggregate_failures do
    stub_request(:get, 'https://registry.npmjs.org/lodash').to_timeout
    packages = {}
    expect { parser.parse('yarn.lock', packages) }
      .not_to(raise_error)
    expect(packages).to(be_empty)
  end

  context 'when the resolved version is not in the registry' do
    let(:missing_version_response) do
      {
        versions: {
          '4.17.20': { license: 'MIT', description: 'older', homepage: '' }
        }
      }.to_json
    end

    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 200, body: missing_version_response)
    end

    it 'skips the package instead of crashing on nil license access', :aggregate_failures do
      packages = {}
      expect { parser.parse('yarn.lock', packages) }
        .not_to(raise_error)
      expect(packages).to(be_empty)
    end
  end

  context 'when the registry response lacks a versions key' do
    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 200, body: { _id: 'lodash', name: 'lodash' }.to_json)
    end

    it 'skips the package instead of raising', :aggregate_failures do
      packages = {}
      expect { parser.parse('yarn.lock', packages) }
        .not_to(raise_error)
      expect(packages).to(be_empty)
    end
  end

  context 'when YarnLockParser returns nil (Yarn Berry / v2+ lockfile)' do
    # Regression test for BUG-01: yarn_lock_parser 0.1.0 returns nil from
    # Parser.parse when compatible? is false (Yarn v2+). Without the guard
    # in yarn.rb#parse the next line raises NoMethodError on NilClass and
    # the whole run aborts.
    before do
      allow(YarnLockParser::Parser).to(receive(:parse).with('yarn.lock').and_return(nil))
    end

    it 'raises a clear unsupported-format error', :aggregate_failures do
      packages = {}
      expect { parser.parse('yarn.lock', packages) }
        .to(raise_error(/Unsupported yarn\.lock format/))
      expect(packages).to(be_empty)
    end
  end

  context 'when license is Unlicense' do
    let(:unlicense_response) do
      {
        versions: {
          '4.17.21': {
            license: 'Unlicense',
            description: 'Test',
            homepage: 'https://example.com'
          }
        }
      }.to_json
    end

    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 200, body: unlicense_response)
    end

    it 'converts Unlicense to NOASSERTION' do
      packages = {}
      parser.parse('yarn.lock', packages)
      expect(packages['lodash'].license).to(eq('NOASSERTION'))
    end
  end

  # TEST-12: parser exercised against real lockfile bytes written to a
  # Dir.mktmpdir via SoupFixtureHelpers, exactly like Application#detect_packages
  # would invoke it in production. Demonstrates the new pattern; follow-up
  # work will migrate the remaining parsers spec-by-spec.
  context 'with a real yarn.lock fixture on disk' do
    let(:yarn_lock_content) do
      <<~LOCK
        # yarn lockfile v1


        lodash@^4.17.0:
          version "4.17.21"
          resolved "https://registry.yarnpkg.com/lodash/-/lodash-4.17.21.tgz#..."
      LOCK
    end

    let(:package_json_content) { '{"dependencies":{"lodash":"^4.17.0"}}' }

    before do
      # Let the real YarnLockParser run against on-disk bytes instead of the
      # literal-path stub from the outer `before`.
      allow(YarnLockParser::Parser).to(receive(:parse).and_call_original)
      write_fixture('package.json', package_json_content)
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 200, body: registry_response)
    end

    it 'reads the lockfile and writes a Package entry without File stubs' do
      lockfile_path = write_fixture('yarn.lock', yarn_lock_content)
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages['lodash']).to(have_attributes(language: 'JS', version: '4.17.21', license: 'MIT'))
    end
  end
end
