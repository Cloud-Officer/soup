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
end
