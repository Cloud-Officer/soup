# frozen_string_literal: true

# TEST-02: BaseParser has shared concurrency, license-normalization, and
# error-formatting helpers that every subclass relies on. Previously they were
# exercised only transitively through individual parser specs, leaving
# regressions in shared behavior (especially Parallel.map's partial-failure
# semantics) undetected.

# A minimal stand-in for HTTParty::Response. HTTParty::Response delegates
# code/message/body to Net::HTTPResponse via SimpleDelegator/method_missing,
# so RSpec's verifying-doubles refuse those method names. This Struct
# satisfies the helper's actual contract (responds to code, message, body).
FakeHTTPResponse = Struct.new(:code, :message, :body)

RSpec.describe(SOUP::BaseParser) do
  describe '#parse (abstract base method)' do
    it 'raises NotImplementedError so subclasses must override it' do
      expect { described_class.new.parse('any.lock', {}) }
        .to(raise_error(NotImplementedError, /must implement #parse/))
    end
  end

  describe 'shared protected helpers' do
    # A throwaway subclass that exposes the protected helpers as public so they
    # can be exercised in isolation without coupling to any specific parser.
    subject(:parser) { test_parser_class.new }

    let(:test_parser_class) do
      Class.new(described_class) do
        def parse(_file, _packages) = nil

        public :parallel_each,
               :collect_packages,
               :build_package,
               :normalize_license,
               :npm_registry_license,
               :http_error_message
      end
    end

    # Factored Package builder keeps parallel_each / collect_packages examples
    # under RSpec/ExampleLength while still exercising the real BaseParser
    # build_package path.
    let(:build_block) do
      lambda do |name|
        parser.build_package(
          name: name,
          file: 'fixture',
          language: 'X',
          version: '1.0',
          license: 'MIT',
          description: nil,
          website: nil,
          dependency: false
        )
      end
    end

    describe '#normalize_license' do
      it 'returns nil unchanged' do
        expect(parser.normalize_license(nil)).to(be_nil)
      end

      it 'returns empty string unchanged' do
        expect(parser.normalize_license('')).to(eq(''))
      end

      it 'converts Unlicense to NOASSERTION' do
        expect(parser.normalize_license('Unlicense')).to(eq('NOASSERTION'))
      end

      it 'converts a URL license to NOASSERTION' do
        expect(parser.normalize_license('https://example.com/license')).to(eq('NOASSERTION'))
      end

      it 'passes through a normal SPDX identifier' do
        expect(parser.normalize_license('MIT')).to(eq('MIT'))
      end
    end

    # BUG-002: the npm registry returns `license` as a String for modern
    # packages but as the legacy object form {"type": "...", "url": "..."} for
    # older versions. The Hash must be coerced to its type string so it never
    # reaches Application#validate_license's unguarded `.downcase`.
    describe '#npm_registry_license' do
      it 'passes a plain string license through unchanged' do
        expect(parser.npm_registry_license('MIT')).to(eq('MIT'))
      end

      it 'extracts the type from the legacy object form' do
        # String keys mirror the parsed-JSON shape the helper indexes with ['type'].
        object_license = { 'type' => 'MIT', 'url' => 'https://x/y' } # rubocop:disable Style/StringHashKeys
        expect(parser.npm_registry_license(object_license)).to(eq('MIT'))
      end

      it 'returns an empty string for nil so normalize_license stays Hash-free' do
        expect(parser.npm_registry_license(nil)).to(eq(''))
      end
    end

    describe '#http_error_message' do
      let(:response) do
        FakeHTTPResponse.new(code: 503, message: 'Service Unavailable', body: 'upstream timeout')
      end

      it 'includes status, reason phrase, package, url, and truncated body' do
        message = parser.http_error_message(response, url: 'https://x/y', package: 'pkg-a@1.0')
        expect(message).to(eq('HTTP 503 Service Unavailable | package=pkg-a@1.0 | url=https://x/y | body=upstream timeout'))
      end

      it 'omits the body section entirely when the body is empty', :aggregate_failures do
        response.body = ''
        message = parser.http_error_message(response, url: 'https://x/y', package: 'p')
        expect(message).not_to(include('body='))
        expect(message).to(include('HTTP 503'))
      end

      it 'omits the package section when no package is given' do
        message = parser.http_error_message(response, url: 'https://x/y')
        expect(message).not_to(include('package='))
      end

      it 'truncates a long body to 200 characters' do
        response.body = 'A' * 500
        message = parser.http_error_message(response, url: 'https://x/y')
        body_part = message[/body=A+/]
        expect(body_part.length).to(eq('body='.length + 200))
      end
    end

    describe '#parallel_each' do
      it 'maps the work items, compacts nils, and indexes the survivors by package name' do
        packages = {}
        parser.parallel_each(%w[a skip b], packages) { |i| build_block.call("pkg-#{i}") unless i == 'skip' }
        expect(packages.keys).to(contain_exactly('pkg-a', 'pkg-b'))
      end

      # TEST-08: partial-failure contract for Parallel.map. The current
      # behavior is that the first raise aborts the batch and no results are
      # written to the packages hash. Locking this in catches regressions
      # against future Parallel library upgrades that might change semantics.
      it 'propagates a worker exception and writes no partial results', :aggregate_failures do
        packages = {}
        block = ->(i) { i == 'fail' ? raise('boom from worker') : build_block.call("pkg-#{i}") }
        expect { parser.parallel_each(%w[a fail b c], packages, &block) }
          .to(raise_error(/boom from worker/))
        expect(packages).to(be_empty)
      end
    end

    describe '#collect_packages' do
      it 'indexes by Package#package and ignores nils', :aggregate_failures do
        good = build_block.call('pkg-x')
        packages = {}
        parser.collect_packages([good, nil], packages)
        expect(packages.size).to(eq(1))
        expect(packages[good.package]).to(equal(good))
      end
    end
  end
end
