# frozen_string_literal: true

RSpec.describe(SOUP::ComposerParser) do
  subject(:parser) { described_class.new }

  let(:lock_file) do
    {
      packages: [
        {
          name: 'vendor/main-pkg',
          version: 'v1.2.3',
          license: ['MIT'],
          description: 'A main package. With more info.',
          homepage: 'https://example.com/main'
        }
      ],
      'packages-dev': [
        {
          name: 'vendor/dev-pkg',
          version: '2.0.0 ',
          license: ['Apache-2.0'],
          description: 'A dev package',
          homepage: 'https://example.com/dev '
        }
      ]
    }.to_json
  end

  let(:main_file) { '{"require":{"vendor/main-pkg":"^1.0"}}' }

  let(:packages) { {} }

  before do |example|
    allow(File).to(receive(:read).and_call_original)
    allow(File).to(receive(:read).with('composer.lock').and_return(lock_file))
    allow(File).to(receive(:read).with('composer.json').and_return(main_file))
    parser.parse('composer.lock', packages) if example.metadata.fetch(:auto_parse, true)
  end

  it 'parses packages and packages-dev', :aggregate_failures do
    expect(packages).to(have_key('vendor/main-pkg'))
    expect(packages).to(have_key('vendor/dev-pkg'))
  end

  it 'sets language to PHP' do
    expect(packages['vendor/main-pkg'].language).to(eq('PHP'))
  end

  it 'extracts version', :aggregate_failures do
    expect(packages['vendor/main-pkg'].version).to(eq('v1.2.3'))
    expect(packages['vendor/dev-pkg'].version).to(eq('2.0.0'))
  end

  it 'extracts license', :aggregate_failures do
    expect(packages['vendor/main-pkg'].license).to(eq('MIT'))
    expect(packages['vendor/dev-pkg'].license).to(eq('Apache-2.0'))
  end

  it 'extracts first sentence of description' do
    expect(packages['vendor/main-pkg'].description).to(eq('A main package'))
  end

  it 'marks non-main-file packages as dependencies', :aggregate_failures do
    expect(packages['vendor/main-pkg'].dependency).to(be(false))
    expect(packages['vendor/dev-pkg'].dependency).to(be(true))
  end

  # BUG-003 regression: a transitive package whose name is a substring of a
  # declared require (vendor/main within vendor/main-pkg) must NOT be flagged
  # direct. The old String#include? scan of composer.json mis-classified it.
  context 'when a transitive package name is a substring of a required package' do
    let(:lock_file) do
      {
        packages: [
          { name: 'vendor/main', version: '1.0.0', license: ['MIT'], description: 'Substring pkg', homepage: '' }
        ],
        'packages-dev': []
      }.to_json
    end

    it 'classifies the substring package as transitive' do
      expect(packages['vendor/main'].dependency).to(be(true))
    end
  end

  context 'with parentheses in license' do
    let(:lock_file) do
      {
        packages: [
          {
            name: 'vendor/paren-pkg',
            version: '1.0.0',
            license: ['(MIT OR Apache-2.0)'],
            description: 'Test',
            homepage: 'https://example.com'
          }
        ],
        'packages-dev': []
      }.to_json
    end

    it 'strips parentheses and takes first license' do
      expect(packages['vendor/paren-pkg'].license).to(eq('MIT'))
    end
  end

  context 'with nil fields' do
    let(:lock_file) do
      {
        packages: [
          {
            name: 'vendor/nil-pkg',
            version: nil,
            license: nil,
            description: nil,
            homepage: nil
          }
        ],
        'packages-dev': []
      }.to_json
    end

    let(:pkg) { packages['vendor/nil-pkg'] }

    it 'handles nil version, license, description, and homepage', :aggregate_failures do
      expect(pkg.version).to(be_nil)
      expect(pkg.license).to(be_nil)
      expect(pkg.description).to(be_nil)
      expect(pkg.website).to(be_nil)
    end
  end

  context 'with composer.lock missing packages-dev key' do
    # Regression test for BUG-021: production-only lockfiles (e.g. from
    # composer install --no-dev) may omit packages-dev entirely. The parser
    # used to raise TypeError on Array + nil.
    let(:lock_file) do
      {
        packages: [
          {
            name: 'vendor/prod-only',
            version: '1.0.0',
            license: ['MIT'],
            description: 'Prod',
            homepage: 'https://example.com'
          }
        ]
      }.to_json
    end

    it 'treats missing packages-dev as empty and parses the prod packages', :aggregate_failures do
      expect { packages }
        .not_to(raise_error)
      expect(packages).to(have_key('vendor/prod-only'))
    end
  end

  context 'with composer.lock missing packages key' do
    let(:lock_file) do
      {
        'packages-dev': [
          {
            name: 'vendor/dev-only',
            version: '1.0.0',
            license: ['MIT'],
            description: 'Dev',
            homepage: 'https://example.com'
          }
        ]
      }.to_json
    end

    it 'treats missing packages as empty and still parses dev packages' do
      expect(packages).to(have_key('vendor/dev-only'))
    end
  end

  context 'when the lockfile lives in a directory whose name contains "lock"' do
    # Regression test for BUG-04: pre-fix the parser used file.gsub('lock',
    # 'json'), an unanchored substring substitution that corrupted any path
    # containing "lock" (e.g. /Users/sherlock/proj/composer.lock).
    let(:lock_file_path) { '/Users/sherlock/proj/composer.lock' }
    let(:main_file_path) { '/Users/sherlock/proj/composer.json' }
    let(:lock_file) do
      {
        packages: [
          { name: 'vendor/x', version: '1.0.0', license: ['MIT'], description: 'X', homepage: '' }
        ],
        'packages-dev': []
      }.to_json
    end

    before do
      allow(File).to(receive(:read).with(lock_file_path).and_return(lock_file))
      allow(File).to(receive(:read).with(main_file_path).and_return('{"require":{"vendor/x":"^1.0"}}'))
      parser.parse(lock_file_path, packages)
    end

    it 'reads composer.json from the same directory without corrupting the path' do
      expect(packages).to(have_key('vendor/x'))
    end
  end

  context 'when license is a single String (not an Array)' do
    # Regression test for BUG-12: Composer's schema permits `license` as a
    # single string. Pre-fix the parser called `.first` on a String, which
    # either raised NoMethodError (plain Ruby) or returned the first
    # character "M" (when ActiveSupport's String#first was loaded).
    let(:lock_file) do
      {
        packages: [
          {
            name: 'vendor/str-license',
            version: '1.0.0',
            license: 'MIT',
            description: 'Single-string license',
            homepage: 'https://example.com'
          }
        ],
        'packages-dev': []
      }.to_json
    end

    it 'treats the string as a one-element array and keeps the full SPDX id' do
      expect(packages['vendor/str-license'].license).to(eq('MIT'))
    end
  end

  # TEST-04: graceful malformed-lockfile cases. Structurally-empty and
  # unknown-shape JSON should fall through the existing `|| []` guards
  # without raising.
  context 'with structurally empty (but valid JSON) composer.lock' do
    let(:lock_file) { '{}' }

    it 'parses without raising and adds no packages' do
      expect(packages).to(be_empty)
    end
  end

  context 'with composer.lock that lacks both packages and packages-dev keys' do
    let(:lock_file) { '{"foo": "bar"}' }

    it 'parses without raising and adds no packages' do
      expect(packages).to(be_empty)
    end
  end

  context 'with URL license' do
    let(:lock_file) do
      {
        packages: [
          {
            name: 'vendor/url-pkg',
            version: '1.0.0',
            license: ['https://example.com/license'],
            description: 'Test',
            homepage: 'https://example.com'
          }
        ],
        'packages-dev': []
      }.to_json
    end

    it 'converts URL license to NOASSERTION' do
      expect(packages['vendor/url-pkg'].license).to(eq('NOASSERTION'))
    end
  end

  # TEST-05: a transient race where Dir.glob found the lockfile but it was
  # deleted/unreadable before File.read surfaces as a bare Errno::ENOENT
  # backtrace. Locking in current behavior so a future improvement (clearer
  # message) is deliberate.
  context 'when the lockfile itself is missing at read time', auto_parse: false do
    before do
      allow(File).to(receive(:read).with('composer.lock').and_raise(Errno::ENOENT.new('composer.lock')))
    end

    it 'surfaces Errno::ENOENT' do
      expect { parser.parse('composer.lock', packages) }
        .to(raise_error(Errno::ENOENT))
    end
  end

  # TEST-04: malformed-JSON cases use auto_parse: false so the top-level
  # before-hook does not invoke parser.parse before the example body has
  # a chance to assert on the expected exception.
  context 'with malformed composer.lock JSON', auto_parse: false do
    let(:lock_file) { 'not json' }

    it 'raises JSON::ParserError on non-JSON garbage' do
      expect { parser.parse('composer.lock', packages) }
        .to(raise_error(JSON::ParserError))
    end

    context 'with empty composer.lock content' do
      let(:lock_file) { '' }

      it 'raises JSON::ParserError' do
        expect { parser.parse('composer.lock', packages) }
          .to(raise_error(JSON::ParserError))
      end
    end

    context 'with truncated JSON in composer.lock' do
      let(:lock_file) { '{"packages":[{"name":"vendor/x"' }

      it 'raises JSON::ParserError' do
        expect { parser.parse('composer.lock', packages) }
          .to(raise_error(JSON::ParserError))
      end
    end
  end

  # TEST-12 follow-up: parser exercised against real lockfile bytes via
  # SoupFixtureHelpers. Uses auto_parse: false so the outer before-hook does
  # not invoke parser.parse with the stubbed 'composer.lock' literal before
  # the example writes its real fixture path.
  context 'with real fixture files on disk', auto_parse: false do
    let(:tmpdir_lock_content) do
      {
        packages: [
          {
            name: 'vendor/main-pkg',
            version: '1.0.0',
            license: ['MIT'],
            description: 'Main package',
            homepage: 'https://example.com'
          }
        ],
        'packages-dev': []
      }.to_json
    end

    it 'reads the lockfile + composer.json from disk without File stubs' do
      write_fixture('composer.json', '{"require":{"vendor/main-pkg":"^1.0"}}')
      lockfile_path = write_fixture('composer.lock', tmpdir_lock_content)
      parser.parse(lockfile_path, packages)
      expect(packages['vendor/main-pkg']).to(have_attributes(language: 'PHP', version: '1.0.0', license: 'MIT'))
    end
  end
end
