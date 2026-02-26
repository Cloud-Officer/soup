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

  context 'with successful registry response' do
    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 200, body: registry_response)
    end

    let(:packages) do
      result = {}
      parser.parse('package-lock.json', result)
      result
    end

    it 'parses packages and skips empty root key and dev dependencies', :aggregate_failures do
      expect(packages).to(have_key('lodash'))
      expect(packages).not_to(have_key('dev-only'))
      expect(packages).not_to(have_key(''))
    end

    it 'sets language to JS and extracts package details', :aggregate_failures do
      expect(packages['lodash'].language).to(eq('JS'))
      expect(packages['lodash'].version).to(eq('4.17.21'))
      expect(packages['lodash'].license).to(eq('MIT'))
      expect(packages['lodash'].description).to(eq('Lodash library'))
      expect(packages['lodash'].website).to(eq('https://lodash.com/'))
    end
  end

  context 'with non-200 response' do
    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 404, body: 'Not Found')
    end

    it 'skips on non-200 response' do
      packages = {}
      parser.parse('package-lock.json', packages)
      expect(packages).to(be_empty)
    end
  end

  it 'skips on timeout', :aggregate_failures do
    stub_request(:get, 'https://registry.npmjs.org/lodash').to_timeout
    packages = {}
    expect { parser.parse('package-lock.json', packages) }
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
      parser.parse('package-lock.json', packages)
      expect(packages['lodash'].license).to(eq('NOASSERTION'))
    end
  end

  context 'when version is not found in registry' do
    before do
      stub_request(:get, 'https://registry.npmjs.org/lodash')
        .to_return(status: 200, body: { versions: {} }.to_json)
    end

    it 'handles version not found in registry' do
      packages = {}
      parser.parse('package-lock.json', packages)
      expect(packages).to(be_empty)
    end
  end
end
