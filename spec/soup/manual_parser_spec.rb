# frozen_string_literal: true

RSpec.describe(SOUP::ManualParser) do
  subject(:parser) { described_class.new }

  let(:entries) do
    [
      {
        package: 'tiptap-pro',
        file: 'vendor/javascript/tiptap-pro.js',
        language: 'JS',
        version: '1.0.0',
        license: 'Commercial',
        description: 'Tiptap Pro toolkit',
        website: 'https://tiptap.dev/',
        risk_level: 'Low',
        requirements: 'Editor toolkit',
        verification_reasoning: 'Commercial subscription'
      },
      {
        package: 'prismjs',
        file: 'app/javascript/prism.js',
        version: '1.30.0',
        license: 'MIT'
      }
    ]
  end

  let(:file) { write_fixture('config/soup-manual.json', entries.to_json) }

  let(:packages) do
    result = {}
    parser.parse(file, result)
    result
  end

  it 'builds packages for each declared entry', :aggregate_failures do
    expect(packages.keys).to(contain_exactly('tiptap-pro', 'prismjs'))
    expect(packages['tiptap-pro'].license).to(eq('Commercial'))
    expect(packages['tiptap-pro'].file).to(eq('vendor/javascript/tiptap-pro.js'))
    expect(packages['tiptap-pro'].dependency).to(be(false))
  end

  it 'carries pre-declared verification fields through', :aggregate_failures do
    expect(packages['tiptap-pro'].risk_level).to(eq('Low'))
    expect(packages['tiptap-pro'].verification_reasoning).to(eq('Commercial subscription'))
  end

  it 'defaults language to JS when unspecified' do
    expect(packages['prismjs'].language).to(eq('JS'))
  end

  context 'when the file is not a JSON array' do
    let(:file) { write_fixture('config/soup-manual.json', '{}') }

    it 'raises' do
      expect { packages }
        .to(raise_error(SOUP::InvalidLockfileError, /must contain a JSON array/))
    end
  end

  context 'when an entry has no package name' do
    let(:file) { write_fixture('config/soup-manual.json', [{ version: '1.0.0' }].to_json) }

    it 'raises' do
      expect { packages }
        .to(raise_error(SOUP::InvalidLockfileError, /non-empty/))
    end
  end
end
