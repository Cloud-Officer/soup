# frozen_string_literal: true

RSpec.describe(SOUP::BundlerParser) do
  subject(:parser) { described_class.new }

  let(:spec) do
    instance_double(Bundler::LazySpecification, name: 'test-gem', version: Gem::Version.new('1.0.0'))
  end

  # DEPENDENCIES section of the lockfile = the directly declared gems. test-gem
  # is present here, so it is classified as a direct dependency by default.
  let(:lock_file) do
    # rubocop:disable Style/StringHashKeys -- DEPENDENCIES keys are gem-name strings.
    instance_double(Bundler::LockfileParser, specs: [spec], dependencies: { 'test-gem' => nil })
    # rubocop:enable Style/StringHashKeys
  end

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
  end

  context 'when v2 API succeeds' do
    let(:packages) { {} }

    before do
      stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/1.0.0.json')
        .to_return(status: 200, body: v2_response_body)

      parser.parse('Gemfile.lock', packages)
    end

    it 'parses lock file and calls RubyGems v2 API', :aggregate_failures do
      expect(packages['test-gem'].language).to(eq('Ruby'))
      expect(packages['test-gem'].version).to(eq('1.0.0'))
      expect(packages['test-gem'].license).to(eq('MIT'))
      expect(packages['test-gem'].description).to(eq('A test gem'))
      expect(packages['test-gem'].website).to(eq('https://example.com'))
    end
  end

  context 'when v2 returns 404' do
    before do
      stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/1.0.0.json')
        .to_return(status: 404, body: 'Not Found')
    end

    context 'when fallback to latest version succeeds' do
      before do
        stub_request(:get, 'https://api.rubygems.org/api/v1/versions/test-gem/latest.json')
          .to_return(status: 200, body: { version: '2.0.0' }.to_json)

        stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/2.0.0.json')
          .to_return(status: 200, body: v2_response_body)
      end

      it 'falls back to latest version when v2 returns 404' do
        packages = {}
        parser.parse('Gemfile.lock', packages)
        expect(packages).to(have_key('test-gem'))
      end
    end

    context 'when fallback latest version also fails' do
      before do
        stub_request(:get, 'https://api.rubygems.org/api/v1/versions/test-gem/latest.json')
          .to_return(status: 500, body: 'Internal Server Error', headers: { Status: 'Internal Server Error' })
      end

      it 'raises a SOUP::RegistryError with status + url + package context' do
        packages = {}
        expect { parser.parse('Gemfile.lock', packages) }
          .to(raise_error(SOUP::RegistryError, /HTTP 500.*test-gem.*api\.rubygems\.org/m))
      end
    end
  end

  context 'when API returns nil fields' do
    let(:packages) { {} }

    before do
      nil_response = {
        licenses: nil,
        info: nil,
        homepage_uri: nil
      }.to_json

      stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/1.0.0.json')
        .to_return(status: 200, body: nil_response)

      parser.parse('Gemfile.lock', packages)
    end

    it 'handles nil fields from API response', :aggregate_failures do
      expect(packages['test-gem'].license).to(be_nil)
      expect(packages['test-gem'].website).to(be_nil)
    end
  end

  context 'when gem is not a direct dependency' do
    # test-gem resolved in specs but absent from the DEPENDENCIES section.
    let(:lock_file) do
      # rubocop:disable Style/StringHashKeys -- DEPENDENCIES keys are gem-name strings.
      instance_double(Bundler::LockfileParser, specs: [spec], dependencies: { 'other-gem' => nil })
      # rubocop:enable Style/StringHashKeys
    end

    before do
      stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/1.0.0.json')
        .to_return(status: 200, body: v2_response_body)
    end

    it 'marks transitive dependencies' do
      packages = {}
      parser.parse('Gemfile.lock', packages)
      expect(packages['test-gem'].dependency).to(be(true))
    end
  end

  # BUG-003 regression: a transitive gem whose name is a substring of a direct
  # dependency (test-gem within test-gem-extras) must NOT be mis-flagged as
  # direct. The previous String#include? scan of the Gemfile classified it wrong.
  context 'when a transitive gem name is a substring of a direct dependency' do
    let(:lock_file) do
      # rubocop:disable Style/StringHashKeys -- DEPENDENCIES keys are gem-name strings.
      instance_double(Bundler::LockfileParser, specs: [spec], dependencies: { 'test-gem-extras' => nil })
      # rubocop:enable Style/StringHashKeys
    end

    before do
      stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/1.0.0.json')
        .to_return(status: 200, body: v2_response_body)
    end

    it 'classifies the substring gem as transitive' do
      packages = {}
      parser.parse('Gemfile.lock', packages)
      expect(packages['test-gem'].dependency).to(be(true))
    end
  end

  # TEST-04: malformed-lockfile coverage. Locks in current behavior so future
  # error-handling improvements are deliberate, not accidental.
  describe '#parse with malformed input' do
    let(:packages) { {} }

    before do
      # Override the top-level stub so the parser's Bundler::LockfileParser.new
      # actually runs against the test content rather than the instance_double.
      allow(Bundler::LockfileParser).to(receive(:new).and_call_original)
    end

    context 'with an empty Gemfile.lock' do
      before do
        allow(Bundler).to(receive(:read_file).with('Gemfile.lock').and_return(''))
      end

      it 'parses without raising and adds no packages', :aggregate_failures do
        expect { parser.parse('Gemfile.lock', packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end

    context 'with garbage content that yields no specs' do
      before do
        allow(Bundler).to(receive(:read_file).with('Gemfile.lock').and_return("not a lockfile\n"))
      end

      it 'parses without raising and adds no packages', :aggregate_failures do
        expect { parser.parse('Gemfile.lock', packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end

    # TEST-05: race where Dir.glob found the lockfile but it was deleted /
    # unreadable before Bundler.read_file ran.
    context 'when Gemfile.lock cannot be read' do
      before do
        allow(Bundler).to(receive(:read_file).with('Gemfile.lock').and_raise(Errno::ENOENT.new('Gemfile.lock')))
      end

      it 'surfaces Errno::ENOENT' do
        expect { parser.parse('Gemfile.lock', packages) }
          .to(raise_error(Errno::ENOENT))
      end
    end

    # TEST-12 follow-up: parser exercised against real Gemfile + Gemfile.lock
    # bytes via SoupFixtureHelpers. Overrides the outer LockfileParser /
    # Bundler.read_file stubs with and_call_original so the real Bundler
    # parser runs against on-disk content.
    context 'with real Gemfile.lock + Gemfile fixtures on disk' do
      # `def` inside a context block defines an instance method on the
      # example group; it is not a memoized helper and does not count against
      # RSpec/MultipleMemoizedHelpers like a `let` would.
      def gemfile_lock_bytes
        <<~LOCK
          GEM
            remote: https://rubygems.org/
            specs:
              test-gem (1.0.0)
          PLATFORMS
            ruby
          DEPENDENCIES
            test-gem
          BUNDLED WITH
             2.5.0
        LOCK
      end

      before do
        allow(Bundler::LockfileParser).to(receive(:new).and_call_original)
        allow(Bundler).to(receive(:read_file).and_call_original)
        stub_request(:get, 'https://api.rubygems.org/api/v2/rubygems/test-gem/versions/1.0.0.json')
          .to_return(status: 200, body: v2_response_body)
      end

      it 'reads Gemfile + Gemfile.lock from disk and lets the real LockfileParser run' do
        write_fixture('Gemfile', "gem 'test-gem'")
        lockfile_path = write_fixture('Gemfile.lock', gemfile_lock_bytes)
        parser.parse(lockfile_path, packages)
        expect(packages['test-gem']).to(have_attributes(language: 'Ruby', version: '1.0.0', license: 'MIT'))
      end
    end
  end

  # TEST-303: exercise parallel_each at a meaningful fan-out width so a
  # parser-local concurrency or ordering regression in Bundler is caught
  # by the spec suite, not just by NPM's existing scale guard.
  context 'with 100 packages (Parallel.map fan-out)' do
    let(:specs) do
      (1..100).map do |i|
        instance_double(Bundler::LazySpecification, name: "gem-#{i}", version: Gem::Version.new('1.0.0'))
      end
    end
    let(:lock_file) { instance_double(Bundler::LockfileParser, specs: specs, dependencies: {}) }

    before do
      (1..100).each do |i|
        stub_request(:get, "https://api.rubygems.org/api/v2/rubygems/gem-#{i}/versions/1.0.0.json")
          .to_return(status: 200, body: v2_response_body)
      end
    end

    it 'parses all 100 gems without raising and adds them to the hash', :aggregate_failures do
      packages = {}
      parser.parse('Gemfile.lock', packages)
      expect(packages.size).to(eq(100))
      expect(packages['gem-1']).to(have_attributes(license: 'MIT', version: '1.0.0'))
      expect(packages['gem-100']).to(have_attributes(license: 'MIT', version: '1.0.0'))
    end
  end
end
