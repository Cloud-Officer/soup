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
               :sibling_file,
               :registry_response,
               :empty_response?,
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

      # BUG-006: Unlicense is a real SPDX identifier and config/licenses.json
      # allowlists it, but normalize_license rewrote it to NOASSERTION before
      # validation ever saw it -- making the allowlist entry unreachable and
      # warning "Invalid license NOASSERTION" on every run.
      it 'passes Unlicense through so the allowlist entry stays reachable' do
        expect(parser.normalize_license('Unlicense')).to(eq('Unlicense'))
      end

      it 'passes the "The Unlicense" spelling through as well' do
        expect(parser.normalize_license('The Unlicense')).to(eq('The Unlicense'))
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

    # CONS-007: before the TEST-12 fixture migration, the bare-basename branch
    # was covered only incidentally, by parser specs that stubbed File.read and
    # so passed 'composer.lock' rather than a real path. Now that every fixture
    # is a real absolute tmpdir path, the helper is asserted directly instead.
    describe '#sibling_file' do
      it 'returns the bare suffix when the file has no directory component' do
        expect(parser.sibling_file('composer.lock', 'composer.json')).to(eq('composer.json'))
      end

      it 'joins the suffix onto the file\'s directory for a nested path' do
        expect(parser.sibling_file('/tmp/proj/composer.lock', 'composer.json')).to(eq('/tmp/proj/composer.json'))
      end

      it 'does not corrupt a directory whose name contains the lockfile name' do
        expect(parser.sibling_file('/Users/sherlock/composer.lock', 'composer.json'))
          .to(eq('/Users/sherlock/composer.json'))
      end
    end

    # ERR-001: registry_response is the single parser-level rescue every parser
    # routes through. Its rescue list used to be a hand-copied
    # "Net::OpenTimeout, Net::ReadTimeout", so any other transient fault escaped
    # into Parallel.map and aborted the entire scan. It now rescues
    # HttpClient::TRANSIENT_ERRORS itself, which cannot drift from what .get
    # retries.
    describe '#registry_response' do
      let(:url) { 'https://registry.example.com/pkg' }
      # One healthy package, one that resets, one more healthy -- routed through
      # the same parallel_each every parser uses.
      let(:mixed_batch) do
        lambda do |packages|
          parser.parallel_each(%w[good bad good2], packages) do |name|
            target = name == 'bad' ? "#{url}/bad" : "#{url}/good"
            build_block.call("pkg-#{name}") if parser.registry_response(target, label: name, max_retries: 0)
          end
        end
      end

      # max_retries: 0 keeps each example to a single request -- the retry
      # behaviour itself is HttpClient's contract and is covered there.
      SOUP::HttpClient::TRANSIENT_ERRORS.each do |error_class|
        it "returns nil and warns instead of letting #{error_class} abort the scan", :aggregate_failures do
          stub_request(:get, url).to_raise(error_class)

          result = nil
          expect { result = parser.registry_response(url, label: 'pkg', max_retries: 0) }
            .to(output(/Skipping pkg: network error after retries/).to_stderr)
          expect(result).to(be_nil)
        end
      end

      it 'names the exception class rather than calling every fault a timeout' do
        stub_request(:get, url).to_raise(Errno::ECONNRESET)

        expect { parser.registry_response(url, label: 'pkg', max_retries: 0) }
          .to(output(/Errno::ECONNRESET/).to_stderr)
      end

      it 'reports the caller-supplied outcome so gradle\'s mirror loop is not misdescribed' do
        stub_request(:get, url).to_raise(SocketError)

        expect { parser.registry_response(url, label: url, outcome: 'trying next repository', max_retries: 0) }
          .to(output(/trying next repository/).to_stderr)
      end

      it 'passes a successful response straight through' do
        stub_request(:get, url).to_return(status: 200, body: 'ok')
        expect(parser.registry_response(url, label: 'pkg').code).to(eq(200))
      end

      # A non-2xx is a response, not a transport fault: callers inspect the code
      # themselves, so it must not be swallowed into nil here.
      it 'returns a non-2xx response rather than converting it to nil' do
        stub_request(:get, url).to_return(status: 404, body: 'Not Found')
        expect(parser.registry_response(url, label: 'pkg').code).to(eq(404))
      end

      # The whole point of ERR-001: Parallel.map propagates the first exception
      # and drops every other in-flight result, so a single reset used to cost
      # the entire run. The surviving packages must still be collected.
      it 'lets the rest of a parallel batch survive one package\'s connection reset' do
        stub_request(:get, "#{url}/bad").to_raise(Errno::ECONNRESET)
        stub_request(:get, "#{url}/good").to_return(status: 200, body: 'ok')
        packages = {}
        mixed_batch.call(packages)
        expect(packages.keys).to(contain_exactly('pkg-good', 'pkg-good2'))
      end
    end

    # Every parser guards its registry lookup with this. It used to be spelled
    # `response.nil?`, which only covered the empty-body case because
    # HTTParty::Response overrides #nil? to mean "body is nil or empty" -- an
    # override HTTParty has deprecated, so a scan printed one [DEPRECATION]
    # block per package and the guard would have silently narrowed to a plain
    # object check on removal, letting empty bodies reach JSON.parse.
    describe '#empty_response?' do
      let(:url) { 'https://registry.example.com/pkg' }

      def response_for(body)
        stub_request(:get, url).to_return(status: 200, body: body)
        parser.registry_response(url, label: 'pkg')
      end

      it 'is true when the network fault left no response at all' do
        expect(parser.empty_response?(nil)).to(be(true))
      end

      it 'is true for an empty body, which JSON.parse would only reject' do
        expect(parser.empty_response?(response_for(''))).to(be(true))
      end

      it 'is false for a response that actually has a payload to parse' do
        expect(parser.empty_response?(response_for('{}'))).to(be(false))
      end

      it 'does not trip HTTParty\'s response#nil? deprecation warning' do
        response = response_for('{}')
        expect { parser.empty_response?(response) }
          .not_to(output(/DEPRECATION/).to_stderr)
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
