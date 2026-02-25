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

  before do
    allow(File).to(receive(:read).and_call_original)
    allow(File).to(receive(:read).with('package-lock.json').and_return(lock_file))
    allow(File).to(receive(:read).with('package.json').and_return(main_file))
  end

  it 'parses packages and skips empty root key and dev dependencies' do
    stub_request(:get, 'https://registry.npmjs.org/lodash')
      .to_return(status: 200, body: registry_response)

    packages = {}
    parser.parse('package-lock.json', packages)
    expect(packages).to(have_key('lodash'))
    expect(packages).not_to(have_key('dev-only'))
    expect(packages).not_to(have_key(''))
  end

  it 'sets language to JS and extracts package details' do
    stub_request(:get, 'https://registry.npmjs.org/lodash')
      .to_return(status: 200, body: registry_response)

    packages = {}
    parser.parse('package-lock.json', packages)
    pkg = packages['lodash']
    expect(pkg.language).to(eq('JS'))
    expect(pkg.version).to(eq('4.17.21'))
    expect(pkg.license).to(eq('MIT'))
    expect(pkg.description).to(eq('Lodash library'))
    expect(pkg.website).to(eq('https://lodash.com/'))
  end

  it 'skips on non-200 response' do
    stub_request(:get, 'https://registry.npmjs.org/lodash')
      .to_return(status: 404, body: 'Not Found')

    packages = {}
    parser.parse('package-lock.json', packages)
    expect(packages).to(be_empty)
  end

  it 'skips on timeout' do
    stub_request(:get, 'https://registry.npmjs.org/lodash')
      .to_timeout

    packages = {}
    expect { parser.parse('package-lock.json', packages) }
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
    parser.parse('package-lock.json', packages)
    expect(packages['lodash'].license).to(eq('NOASSERTION'))
  end

  it 'handles version not found in registry' do
    response = { versions: {} }.to_json
    stub_request(:get, 'https://registry.npmjs.org/lodash')
      .to_return(status: 200, body: response)

    packages = {}
    parser.parse('package-lock.json', packages)
    expect(packages).to(be_empty)
  end
end
