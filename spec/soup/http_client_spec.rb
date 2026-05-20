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
  end

  # Regression tests for CFG-01: SOUP_HTTP_TIMEOUT and SOUP_HTTP_MAX_RETRIES
  # are read from ENV at call time so operators can tune behavior on slow
  # corporate proxies / rate-limited mirrors without forking.
  describe '.max_retries' do
    it 'defaults to 3 when SOUP_HTTP_MAX_RETRIES is unset' do
      allow(ENV).to(receive(:fetch).and_call_original)
      allow(ENV).to(receive(:fetch).with('SOUP_HTTP_MAX_RETRIES', 3).and_return(3))
      expect(described_class.max_retries).to(eq(3))
    end

    it 'honors SOUP_HTTP_MAX_RETRIES when set' do
      allow(ENV).to(receive(:fetch).and_call_original)
      allow(ENV).to(receive(:fetch).with('SOUP_HTTP_MAX_RETRIES', 3).and_return('7'))
      expect(described_class.max_retries).to(eq(7))
    end
  end

  describe '.default_timeout' do
    it 'defaults to 5 when SOUP_HTTP_TIMEOUT is unset' do
      allow(ENV).to(receive(:fetch).and_call_original)
      allow(ENV).to(receive(:fetch).with('SOUP_HTTP_TIMEOUT', 5).and_return(5))
      expect(described_class.default_timeout).to(eq(5))
    end

    it 'honors SOUP_HTTP_TIMEOUT when set' do
      allow(ENV).to(receive(:fetch).and_call_original)
      allow(ENV).to(receive(:fetch).with('SOUP_HTTP_TIMEOUT', 5).and_return('45'))
      expect(described_class.default_timeout).to(eq(45))
    end
  end

  describe '.get with SOUP_HTTP_MAX_RETRIES env override' do
    before do
      allow(ENV).to(receive(:fetch).and_call_original)
      allow(ENV).to(receive(:fetch).with('SOUP_HTTP_MAX_RETRIES', 3).and_return('1'))
      allow(ENV).to(receive(:fetch).with('SOUP_HTTP_TIMEOUT', 5).and_return(5))
      stub_request(:get, url).to_timeout
    end

    it 'uses the env-resolved max_retries as the default when no kwarg is passed', :aggregate_failures do
      expect { described_class.get(url) }
        .to(raise_error(Net::OpenTimeout))
      expect(WebMock).to(have_requested(:get, url).times(2))
    end
  end
end
