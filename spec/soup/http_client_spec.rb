# frozen_string_literal: true

RSpec.describe(SOUP::HttpClient) do
  let(:url) { 'https://api.example.com/test' }

  describe '.get' do
    it 'returns a successful response', :aggregate_failures do
      stub_request(:get, url).to_return(status: 200, body: '{"ok":true}')
      response = described_class.get(url)
      expect(response.code).to(eq(200))
      expect(response.body).to(eq('{"ok":true}'))
    end

    context 'when the server times out twice then succeeds' do
      before do
        stub_request(:get, url)
          .to_timeout
          .to_timeout
          .to_return(status: 200, body: 'ok')
      end

      it 'retries on timeout and succeeds on third attempt', :aggregate_failures do
        expect { described_class.get(url) }
          .to(output(/Retrying/).to_stderr)
        expect(WebMock).to(have_requested(:get, url).times(3))
      end
    end

    it 'raises after exhausting retries', :aggregate_failures do
      stub_request(:get, url).to_timeout

      expect do
        described_class.get(url)
      end.to(raise_error(Net::OpenTimeout).and(output(/Aborting/).to_stderr))

      expect(WebMock).to(have_requested(:get, url).times(4))
    end

    it 'passes custom headers through to HTTParty' do
      stub_request(:get, url)
        .with(headers: { Authorization: 'token abc123' })
        .to_return(status: 200, body: 'ok')

      response = described_class.get(url, headers: { Authorization: 'token abc123' })
      expect(response.code).to(eq(200))
    end

    it 'respects custom max_retries', :aggregate_failures do
      stub_request(:get, url).to_timeout

      expect do
        described_class.get(url, max_retries: 1)
      end.to(raise_error(Net::OpenTimeout).and(output(/Aborting/).to_stderr))

      expect(WebMock).to(have_requested(:get, url).times(2))
    end

    # TEST-06: 4xx/5xx are *responses*, not transport failures -- they are
    # returned to the caller for inspection rather than retried or raised.
    it 'returns a 404 response unchanged so callers can decide how to handle it', :aggregate_failures do
      stub_request(:get, url).to_return(status: 404, body: 'Not Found')
      response = described_class.get(url)
      expect(response.code).to(eq(404))
      expect(WebMock).to(have_requested(:get, url).times(1))
    end

    it 'returns a 5xx response without retrying', :aggregate_failures do
      stub_request(:get, url).to_return(status: 503, body: 'gateway timeout')
      response = described_class.get(url)
      expect(response.code).to(eq(503))
      expect(WebMock).to(have_requested(:get, url).times(1))
    end

    # ERR-001: the retry set used to be Net::OpenTimeout/ReadTimeout only, so
    # every other transient fault bypassed the retry loop on its first attempt
    # and escaped into Parallel.map -- which propagates the first exception and
    # aborts every other in-flight lookup, killing a whole multi-hundred-package
    # scan over one connection reset. Two of the examples below previously
    # asserted that bypass as if it were the intended contract.
    #
    # Each transient class must now be retried max_retries times and only then
    # re-raised, so BaseParser#registry_response can turn it into a per-package
    # skip. Driven from the constant itself so a class added to TRANSIENT_ERRORS
    # without retry coverage fails here.
    describe 'transient network faults' do
      SOUP::HttpClient::TRANSIENT_ERRORS.each do |error_class|
        it "retries #{error_class} to exhaustion, warns, then re-raises", :aggregate_failures do
          stub_request(:get, url).to_raise(error_class)
          expect { described_class.get(url) }
            .to(raise_error(error_class).and(output(/Aborting after 3 retries/).to_stderr))
          expect(WebMock).to(have_requested(:get, url).times(4))
        end

        it "recovers when an attempt after #{error_class} succeeds", :aggregate_failures do
          stub_request(:get, url).to_raise(error_class).then.to_return(status: 200, body: 'ok')
          expect { expect(described_class.get(url).code).to(eq(200)) }
            .to(output(%r{Retrying \(1/3\)}).to_stderr)
          expect(WebMock).to(have_requested(:get, url).times(2))
        end
      end

      it 'names the exception class in the warning so resets are not reported as timeouts' do
        stub_request(:get, url).to_raise(Errno::ECONNRESET)

        expect { described_class.get(url) }
          .to(raise_error(Errno::ECONNRESET).and(output(/Errno::ECONNRESET/).to_stderr))
      end
    end
  end

  def stub_http_env(timeout: nil, max_retries: nil)
    allow(ENV).to(receive(:fetch).and_call_original)
    allow(ENV).to(receive(:fetch).with('SOUP_HTTP_TIMEOUT', nil).and_return(timeout))
    allow(ENV).to(receive(:fetch).with('SOUP_HTTP_MAX_RETRIES', nil).and_return(max_retries))
  end

  def configure_http_env(**env)
    stub_http_env(**env)
    described_class.validate_env!
  end

  describe '.max_retries' do
    it 'defaults to 3 when SOUP_HTTP_MAX_RETRIES is unset' do
      configure_http_env
      expect(described_class.max_retries).to(eq(3))
    end

    it 'honors SOUP_HTTP_MAX_RETRIES when set' do
      configure_http_env(max_retries: '7')
      expect(described_class.max_retries).to(eq(7))
    end

    it 'accepts zero to disable retries' do
      configure_http_env(max_retries: '0')
      expect(described_class.max_retries).to(eq(0))
    end
  end

  describe '.default_timeout' do
    it 'defaults to 5 when SOUP_HTTP_TIMEOUT is unset' do
      configure_http_env
      expect(described_class.default_timeout).to(eq(5))
    end

    it 'honors SOUP_HTTP_TIMEOUT when set' do
      configure_http_env(timeout: '45')
      expect(described_class.default_timeout).to(eq(45))
    end
  end

  describe '.validate_env!' do
    {
      { timeout: '5s' } => /SOUP_HTTP_TIMEOUT .*"5s"/,
      { timeout: '' } => /SOUP_HTTP_TIMEOUT .*""/,
      { timeout: '0' } => /SOUP_HTTP_TIMEOUT must be an integer >= 1, got "0"/,
      { timeout: '-3' } => /SOUP_HTTP_TIMEOUT .*"-3"/,
      { max_retries: 'three' } => /SOUP_HTTP_MAX_RETRIES .*"three"/,
      { max_retries: '1.5' } => /SOUP_HTTP_MAX_RETRIES .*"1.5"/,
      { max_retries: '-1' } => /SOUP_HTTP_MAX_RETRIES must be an integer >= 0, got "-1"/
    }.each do |env, message|
      it "raises a ConfigurationError naming the variable for #{env}" do
        stub_http_env(**env)
        expect { described_class.validate_env! }
          .to(raise_error(SOUP::ConfigurationError, message))
      end
    end

    it 'memoizes the parsed values so later ENV changes cannot break per-request reads', :aggregate_failures do
      configure_http_env(timeout: '9', max_retries: '2')
      stub_http_env(timeout: 'garbage', max_retries: 'garbage')
      expect(described_class.default_timeout).to(eq(9))
      expect(described_class.max_retries).to(eq(2))
    end
  end

  describe '.get with SOUP_HTTP_MAX_RETRIES env override' do
    before do
      configure_http_env(max_retries: '1')
      stub_request(:get, url).to_timeout
    end

    it 'uses the env-resolved max_retries as the default when no kwarg is passed', :aggregate_failures do
      expect { described_class.get(url) }
        .to(raise_error(Net::OpenTimeout).and(output(/Aborting after 1 retries/).to_stderr))
      expect(WebMock).to(have_requested(:get, url).times(2))
    end
  end
end
