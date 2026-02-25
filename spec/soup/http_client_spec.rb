# frozen_string_literal: true

RSpec.describe(SOUP::HttpClient) do
  let(:url) { 'https://api.example.com/test' }

  describe '.get' do
    it 'returns a successful response' do
      stub_request(:get, url).to_return(status: 200, body: '{"ok":true}')
      response = described_class.get(url)
      expect(response.code).to(eq(200))
      expect(response.body).to(eq('{"ok":true}'))
    end

    it 'retries on timeout and succeeds on third attempt' do
      stub_request(:get, url)
        .to_timeout
        .to_timeout
        .to_return(status: 200, body: 'ok')

      expect { described_class.get(url) }
        .to(output(/Retrying/).to_stdout)
      expect(WebMock).to(have_requested(:get, url).times(3))
    end

    it 'raises after exhausting retries' do
      stub_request(:get, url).to_timeout

      expect do
        described_class.get(url)
      end.to(raise_error(Net::OpenTimeout).and(output(/Aborting/).to_stdout))

      expect(WebMock).to(have_requested(:get, url).times(4))
    end

    it 'passes custom headers through to HTTParty' do
      stub_request(:get, url)
        .with(headers: { Authorization: 'token abc123' })
        .to_return(status: 200, body: 'ok')

      response = described_class.get(url, headers: { Authorization: 'token abc123' })
      expect(response.code).to(eq(200))
    end

    it 'respects custom max_retries' do
      stub_request(:get, url).to_timeout

      expect do
        described_class.get(url, max_retries: 1)
      end.to(raise_error(Net::OpenTimeout).and(output(/Aborting/).to_stdout))

      expect(WebMock).to(have_requested(:get, url).times(2))
    end
  end
end
