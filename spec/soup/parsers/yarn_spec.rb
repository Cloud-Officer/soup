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

  it 'parses via YarnLockParser and calls NPM registry' do
    stub_request(:get, 'https://registry.npmjs.org/lodash')
      .to_return(status: 200, body: registry_response)

    packages = {}
    parser.parse('yarn.lock', packages)
    expect(packages).to(have_key('lodash'))
    expect(packages['lodash'].language).to(eq('JS'))
    expect(packages['lodash'].version).to(eq('4.17.21'))
    expect(packages['lodash'].license).to(eq('MIT'))
  end

  it 'skips vendor packages' do
    allow(File).to(
      receive(:read).with('package.json')
                                       .and_return('{"dependencies":{"lodash": "file:vendor/lodash"}}')
    )

    packages = {}
    parser.parse('yarn.lock', packages)
    expect(packages).to(be_empty)
  end

  it 'raises on non-200 response' do
    stub_request(:get, 'https://registry.npmjs.org/lodash')
      .to_return(status: 500, body: 'Server Error')

    packages = {}
    expect { parser.parse('yarn.lock', packages) }
      .to(raise_error(RuntimeError))
  end

  it 'handles timeout gracefully' do
    stub_request(:get, 'https://registry.npmjs.org/lodash')
      .to_timeout

    packages = {}
    expect { parser.parse('yarn.lock', packages) }
      .not_to(raise_error)
    expect(packages).to(be_empty)
  end

  it 'converts Unlicense to NOASSERTION' do
    response = {
      versions: {
        '4.17.21': {
          license: 'Unlicense',
          description: 'Test',
          homepage: 'https://example.com'
        }
      }
    }.to_json

    stub_request(:get, 'https://registry.npmjs.org/lodash')
      .to_return(status: 200, body: response)

    packages = {}
    parser.parse('yarn.lock', packages)
    expect(packages['lodash'].license).to(eq('NOASSERTION'))
  end
end
