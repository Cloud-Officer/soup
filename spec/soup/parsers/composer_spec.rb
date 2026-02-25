# frozen_string_literal: true

RSpec.describe(SOUP::ComposerParser) do
  subject(:parser) { described_class.new }

  let(:lock_file) do
    {
      packages: [
        {
          name: 'vendor/main-pkg',
          version: 'v1.2.3',
          license: ['MIT'],
          description: 'A main package. With more info.',
          homepage: 'https://example.com/main'
        }
      ],
      'packages-dev': [
        {
          name: 'vendor/dev-pkg',
          version: '2.0.0 ',
          license: ['Apache-2.0'],
          description: 'A dev package',
          homepage: 'https://example.com/dev '
        }
      ]
    }.to_json
  end

  let(:main_file) { '{"require":{"vendor/main-pkg":"^1.0"}}' }

  before do
    allow(File).to(receive(:read).and_call_original)
    allow(File).to(receive(:read).with('composer.lock').and_return(lock_file))
    allow(File).to(receive(:read).with('composer.json').and_return(main_file))
  end

  it 'parses packages and packages-dev' do
    packages = {}
    parser.parse('composer.lock', packages)
    expect(packages).to(have_key('vendor/main-pkg'))
    expect(packages).to(have_key('vendor/dev-pkg'))
  end

  it 'sets language to PHP' do
    packages = {}
    parser.parse('composer.lock', packages)
    expect(packages['vendor/main-pkg'].language).to(eq('PHP'))
  end

  it 'extracts version' do
    packages = {}
    parser.parse('composer.lock', packages)
    expect(packages['vendor/main-pkg'].version).to(eq('v1.2.3'))
    expect(packages['vendor/dev-pkg'].version).to(eq('2.0.0'))
  end

  it 'extracts license' do
    packages = {}
    parser.parse('composer.lock', packages)
    expect(packages['vendor/main-pkg'].license).to(eq('MIT'))
    expect(packages['vendor/dev-pkg'].license).to(eq('Apache-2.0'))
  end

  it 'extracts first sentence of description' do
    packages = {}
    parser.parse('composer.lock', packages)
    expect(packages['vendor/main-pkg'].description).to(eq('A main package'))
  end

  it 'marks non-main-file packages as dependencies' do
    packages = {}
    parser.parse('composer.lock', packages)
    expect(packages['vendor/main-pkg'].dependency).to(be(false))
    expect(packages['vendor/dev-pkg'].dependency).to(be(true))
  end

  context 'with parentheses in license' do
    let(:lock_file) do
      {
        packages: [
          {
            name: 'vendor/paren-pkg',
            version: '1.0.0',
            license: ['(MIT OR Apache-2.0)'],
            description: 'Test',
            homepage: 'https://example.com'
          }
        ],
        'packages-dev': []
      }.to_json
    end

    it 'strips parentheses and takes first license' do
      packages = {}
      parser.parse('composer.lock', packages)
      expect(packages['vendor/paren-pkg'].license).to(eq('MIT'))
    end
  end

  context 'with nil fields' do
    let(:lock_file) do
      {
        packages: [
          {
            name: 'vendor/nil-pkg',
            version: nil,
            license: nil,
            description: nil,
            homepage: nil
          }
        ],
        'packages-dev': []
      }.to_json
    end

    it 'handles nil version, license, description, and homepage' do
      packages = {}
      parser.parse('composer.lock', packages)
      pkg = packages['vendor/nil-pkg']
      expect(pkg.version).to(be_nil)
      expect(pkg.license).to(be_nil)
      expect(pkg.description).to(be_nil)
      expect(pkg.website).to(be_nil)
    end
  end

  context 'with URL license' do
    let(:lock_file) do
      {
        packages: [
          {
            name: 'vendor/url-pkg',
            version: '1.0.0',
            license: ['https://example.com/license'],
            description: 'Test',
            homepage: 'https://example.com'
          }
        ],
        'packages-dev': []
      }.to_json
    end

    it 'converts URL license to NOASSERTION' do
      packages = {}
      parser.parse('composer.lock', packages)
      expect(packages['vendor/url-pkg'].license).to(eq('NOASSERTION'))
    end
  end
end
