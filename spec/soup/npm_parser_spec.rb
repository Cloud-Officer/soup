# frozen_string_literal: true

RSpec.describe(SOUP::NPMParser) do
  subject(:parser) { described_class.new }

  let(:lock_file) do
    {
      packages: {
        '': { version: '1.0.0' }, # rubocop:disable Naming/VariableNumber
        'node_modules/lodash': { version: '4.17.21' },
        'node_modules/dev-only': { version: '1.0.0', dev: true }
      }
    }.to_json
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

  # TEST-12: lockfile and its sibling package.json are written to a per-example
  # tmpdir, so the parser resolves package.json through the real sibling_file
  # path handling rather than a File.read stub keyed to a bare basename.
  def lockfile_path
    write_fixture('package.json', main_file)
    write_fixture('package-lock.json', lock_file)
  end

  context 'with successful registry response' do
    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 200, body: registry_response)
    end

    let(:packages) do
      result = {}
      parser.parse(lockfile_path, result)
      result
    end

    it 'parses packages and skips empty root key and dev dependencies', :aggregate_failures do
      expect(packages).to(have_key('lodash'))
      expect(packages).not_to(have_key('dev-only'))
      expect(packages).not_to(have_key(''))
    end

    it 'sets language to JS and extracts package details', :aggregate_failures do
      expect(packages['lodash'].language).to(eq('JS'))
      expect(packages['lodash'].version).to(eq('4.17.21'))
      expect(packages['lodash'].license).to(eq('MIT'))
      expect(packages['lodash'].description).to(eq('Lodash library'))
      expect(packages['lodash'].website).to(eq('https://lodash.com/'))
    end
  end

  context 'with non-200 response' do
    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 404, body: 'Not Found')
    end

    it 'records the package as unresolved rather than dropping it', :aggregate_failures do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages['lodash']).to(have_attributes(version: '4.17.21', language: 'JS', license: 'NOASSERTION'))
      expect(packages['lodash'].unresolved).to(be(true))
    end
  end

  # TEST-305: assert the full retry loop ran and the user saw the
  # "Aborting after N retries" warning before the parser skipped the
  # package, not just that parse did not raise.
  context 'when the registry times out' do
    let(:url) { 'https://registry.npmjs.org/lodash' }
    let(:packages) { {} }

    before { stub_request(:get, url).to_timeout }

    it 'emits the "Aborting after N retries" stderr warning' do
      expect { parser.parse(lockfile_path, packages) }
        .to(output(/Aborting after \d+ retries/).to_stderr)
    end

    it 'retries max_retries+1 times before recording the package as unresolved', :aggregate_failures do
      parser.parse(lockfile_path, packages)
      expect(packages['lodash']).to(have_attributes(version: '4.17.21', license: 'NOASSERTION'))
      expect(a_request(:get, url)).to(have_been_made.times(SOUP::HttpClient.max_retries + 1))
    end

    # QUAL-001: the warning is emitted by the shared
    # BaseParser#npm_registry_response, which names the package from the `label`
    # this parser passes. NPM knows the version up front, so it must stay
    # "name@version" -- Importmap, which cannot, deliberately omits it.
    it 'names the package as name@version in the skip warning' do
      expect { parser.parse(lockfile_path, packages) }
        .to(output(/Skipping lodash@4\.17\.21: network error after retries/).to_stderr)
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

    # BUG-006: Unlicense is allowlisted in config/licenses.json, so it must
    # survive parsing intact rather than being downgraded to NOASSERTION.
    it 'records Unlicense verbatim' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages['lodash'].license).to(eq('Unlicense'))
    end
  end

  context 'when version is not found in registry' do
    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 200, body: { versions: {} }.to_json)
    end

    it 'records the package as unresolved when its version is absent', :aggregate_failures do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages['lodash']).to(have_attributes(version: '4.17.21', license: 'NOASSERTION'))
      expect(packages['lodash'].unresolved).to(be(true))
    end
  end

  context 'when registry response has no versions key' do
    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 200, body: { _id: 'lodash', name: 'lodash', time: {} }.to_json)
    end

    it 'records unpublished or stub-only packages without raising', :aggregate_failures do
      packages = {}
      expect { parser.parse(lockfile_path, packages) }
        .not_to(raise_error)
      expect(packages['lodash']).to(have_attributes(license: 'NOASSERTION'))
      expect(packages['lodash'].unresolved).to(be(true))
    end
  end

  context 'when package only appears in package.json overrides' do
    let(:main_file) { '{"dependencies":{"lodash":"^4.17.0"},"overrides":{"lodash":"4.17.21"}}' }

    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 200, body: registry_response)
    end

    it 'classifies overrides-only packages as transitive (not direct)' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages['lodash'].dependency).to(be(false))
    end
  end

  context 'when package is in overrides but not declared as a direct dep' do
    let(:lock_file) do
      {
        packages: {
          '': { version: '1.0.0' }, # rubocop:disable Naming/VariableNumber
          'node_modules/transitive-only': { version: '1.0.0' }
        }
      }.to_json
    end

    let(:main_file) { '{"dependencies":{},"overrides":{"transitive-only":"1.0.0"}}' }

    let(:transitive_response) do
      { versions: { '1.0.0': { license: 'MIT', description: 'x', homepage: 'https://example.com' } } }.to_json
    end

    before do
      stub_request(:get, 'https://registry.npmjs.org/transitive-only')
        .to_return(status: 200, body: transitive_response)
    end

    it 'is treated as transitive even though it appears in overrides' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages['transitive-only'].dependency).to(be(true))
    end
  end

  context 'with a lockfileVersion 1 package-lock.json (no `packages` key)' do
    # Regression test for BUG-02: npm v6 / lockfileVersion 1 lockfiles only
    # contain a top-level `dependencies` key; without the nil guard in
    # npm.rb#parse the next line raises NoMethodError on NilClass and the
    # whole run aborts.
    let(:lock_file) { { dependencies: { lodash: { version: '4.17.21' } } }.to_json }

    it 'raises a clear unsupported-format error', :aggregate_failures do
      packages = {}
      expect { parser.parse(lockfile_path, packages) }
        .to(raise_error(SOUP::UnsupportedFormatError, /Unsupported package-lock\.json/))
      expect(packages).to(be_empty)
    end
  end

  # TEST-07: realistic-scale lockfile to exercise Parallel.map(in_threads: ...)
  # at a meaningful work-item count. Pre-fix parser specs only used 1-2
  # packages, so the parallel fan-out path was never realistically loaded and
  # concurrency or ordering regressions would not have been caught.
  context 'with 100 packages (Parallel.map fan-out)' do
    let(:lock_file) do
      packages_hash =
        (1..100).each_with_object({ '': { version: '1.0.0' } }) do |i, acc| # rubocop:disable Naming/VariableNumber
          acc["node_modules/pkg-#{i}"] = { version: '1.0.0' }
        end
      { packages: packages_hash }.to_json
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
      parser.parse(lockfile_path, packages)
      expect(packages.size).to(eq(100))
      expect(packages['pkg-1']).to(have_attributes(license: 'MIT', version: '1.0.0'))
      expect(packages['pkg-100']).to(have_attributes(license: 'MIT', version: '1.0.0'))
    end
  end

  # TEST-05: race where Dir.glob found the lockfile but it was deleted /
  # unreadable before File.read ran.
  context 'when package-lock.json cannot be read' do
    # Points at a path inside the fixture dir that was never written, so the
    # real File.read raises ENOENT instead of a stub simulating it.
    let(:lockfile_path) { File.join(fixture_dir, 'gone', 'package-lock.json') }

    it 'surfaces Errno::ENOENT' do
      packages = {}
      expect { parser.parse(lockfile_path, packages) }
        .to(raise_error(Errno::ENOENT))
    end
  end

  # TEST-12 follow-up: parser exercised against real lockfile bytes via
  # SoupFixtureHelpers, demonstrating the no-stub pattern for npm.
  context 'with a real lockfileVersion 3 package-lock.json on disk' do
    let(:lock_file) do
      {
        lockfileVersion: 3,
        packages: {
          '': { version: '1.0.0' }, # rubocop:disable Naming/VariableNumber
          'node_modules/lodash': { version: '4.17.21' }
        }
      }.to_json
    end

    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 200, body: registry_response)
    end

    it 'reads both files from disk without File stubs' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages['lodash']).to(have_attributes(language: 'JS', version: '4.17.21', license: 'MIT'))
    end
  end
end
