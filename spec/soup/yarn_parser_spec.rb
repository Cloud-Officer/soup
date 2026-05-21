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

  it 'raises a SOUP::RegistryError on non-200 response' do
    stub_request(:get, 'https://registry.npmjs.org/lodash')
      .to_return(status: 500, body: 'Server Error')
    packages = {}
    expect { parser.parse('yarn.lock', packages) }
      .to(raise_error(SOUP::RegistryError, /HTTP 500.*lodash.*registry\.npmjs\.org/m))
  end

  # TEST-305: assert the full retry loop ran and the user saw the
  # "Aborting after N retries" warning before the parser skipped the
  # package, not just that parse did not raise.
  context 'when the registry times out' do
    let(:url) { 'https://registry.npmjs.org/lodash' }
    let(:packages) { {} }

    before { stub_request(:get, url).to_timeout }

    it 'emits the "Aborting after N retries" stderr warning' do
      expect { parser.parse('yarn.lock', packages) }
        .to(output(/Aborting after \d+ retries/).to_stderr)
    end

    it 'retries max_retries+1 times before skipping the package', :aggregate_failures do
      parser.parse('yarn.lock', packages)
      expect(packages).to(be_empty)
      expect(a_request(:get, url)).to(have_been_made.times(SOUP::HttpClient.max_retries + 1))
    end
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
        .to(raise_error(SOUP::UnsupportedFormatError, /Unsupported yarn\.lock format/))
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

  # TEST-05: race where Dir.glob found the lockfile but it was deleted /
  # unreadable before YarnLockParser::Parser.parse ran.
  context 'when yarn.lock cannot be read' do
    before do
      allow(YarnLockParser::Parser).to(receive(:parse).with('yarn.lock').and_raise(Errno::ENOENT.new('yarn.lock')))
    end

    it 'surfaces Errno::ENOENT' do
      packages = {}
      expect { parser.parse('yarn.lock', packages) }
        .to(raise_error(Errno::ENOENT))
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

  # TEST-306: parity with bundler / composer which both cover an explicit
  # empty-lockfile context. yarn_lock_parser 0.1.0 returns nil for empty
  # input, so the parser surfaces the same UnsupportedFormatError as the
  # Yarn Berry case (BUG-01) but via a real on-disk file rather than a stub.
  context 'with an empty yarn.lock fixture on disk' do
    let(:packages) { {} }
    let(:lockfile_path) do
      write_fixture('package.json', '{}')
      write_fixture('yarn.lock', '')
    end

    before { allow(YarnLockParser::Parser).to(receive(:parse).and_call_original) }

    it 'raises UnsupportedFormatError when YarnLockParser cannot parse the file', :aggregate_failures do
      expect { parser.parse(lockfile_path, packages) }
        .to(raise_error(SOUP::UnsupportedFormatError, /Unsupported yarn\.lock format/))
      expect(packages).to(be_empty)
    end
  end

  # TEST-303: exercise parallel_each at a meaningful fan-out width so a
  # parser-local concurrency or ordering regression in Yarn is caught
  # by the spec suite, not just by NPM's existing scale guard.
  context 'with 100 packages (Parallel.map fan-out)' do
    let(:parsed_lock) do
      (1..100).map { |i| { name: "pkg-#{i}", version: '1.0.0' } }
    end

    let(:main_file) do
      deps = (1..100).to_h { |i| ["pkg-#{i}", '^1.0.0'] }
      { dependencies: deps }.to_json
    end

    before do
      (1..100).each do |i|
        body = { versions: { '1.0.0': { license: 'MIT', description: "pkg-#{i}", homepage: '' } } }.to_json
        stub_request(:get, "https://registry.npmjs.org/pkg-#{i}").to_return(status: 200, body: body)
      end
    end

    it 'parses all 100 packages without raising and adds them to the hash', :aggregate_failures do
      packages = {}
      parser.parse('yarn.lock', packages)
      expect(packages.size).to(eq(100))
      expect(packages['pkg-1']).to(have_attributes(language: 'JS', version: '1.0.0', license: 'MIT'))
      expect(packages['pkg-100']).to(have_attributes(language: 'JS', version: '1.0.0', license: 'MIT'))
    end
  end
end
