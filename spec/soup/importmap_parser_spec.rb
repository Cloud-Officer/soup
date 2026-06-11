# frozen_string_literal: true

RSpec.describe(SOUP::ImportmapParser) do
  subject(:parser) { described_class.new }

  def registry_body(version, latest: version)
    {
      'dist-tags': { latest: latest },
      versions: {
        version => {
          license: 'MIT',
          description: "desc for #{version}",
          homepage: 'https://example.com/'
        }
      }
    }.to_json
  end

  let(:importmap) do
    <<~RUBY
      pin 'application'
      pin 'turbo_confirm', to: 'turbo_confirm.js'
      pin '@tiptap/starter-kit', to: 'https://esm.sh/@tiptap/starter-kit@3.1.0'
      pin '@tiptap/pm/state', to: 'https://esm.sh/@tiptap/pm@3.1.0/state'
      pin 'highlight.js', to: 'https://ga.jspm.io/npm:highlight.js@11.9.0/es/index.js'
      pin 'tributejs', to: 'https://cdn.jsdelivr.net/npm/tributejs@5.1.3/+esm'
      pin '@rails/ujs', to: 'https://ga.jspm.io/npm:@rails/ujs@7.0.4/lib/assets/compiled/rails-ujs.js'
      pin 'yjs', to: 'https://esm.sh/yjs'
    RUBY
  end

  let(:file) { write_fixture('config/importmap.rb', importmap) }

  let(:packages) do
    result = {}
    parser.parse(file, result)
    result
  end

  before do
    stub_request(:get, 'https://registry.npmjs.org/@tiptap/starter-kit').to_return(status: 200, body: registry_body('3.1.0'))
    stub_request(:get, 'https://registry.npmjs.org/@tiptap/pm').to_return(status: 200, body: registry_body('3.1.0'))
    stub_request(:get, 'https://registry.npmjs.org/highlight.js').to_return(status: 200, body: registry_body('11.9.0'))
    stub_request(:get, 'https://registry.npmjs.org/tributejs').to_return(status: 200, body: registry_body('5.1.3'))
    stub_request(:get, 'https://registry.npmjs.org/@rails/ujs').to_return(status: 200, body: registry_body('7.0.4'))
    stub_request(:get, 'https://registry.npmjs.org/yjs').to_return(status: 200, body: registry_body('13.6.0'))
  end

  it 'skips local and non-http pins', :aggregate_failures do
    expect(packages).not_to(have_key('application'))
    expect(packages).not_to(have_key('turbo_confirm'))
  end

  it 'derives scoped name and version from an esm.sh url', :aggregate_failures do
    pkg = packages['@tiptap/starter-kit']
    expect(pkg.version).to(eq('3.1.0'))
    expect(pkg.language).to(eq('JS'))
    expect(pkg.license).to(eq('MIT'))
    expect(pkg.dependency).to(be(false))
  end

  it 'maps a scoped subpath pin to its base package', :aggregate_failures do
    expect(packages).to(have_key('@tiptap/pm'))
    expect(packages['@tiptap/pm'].version).to(eq('3.1.0'))
  end

  it 'derives name and version from jspm npm: and jsdelivr npm/ urls', :aggregate_failures do
    expect(packages['highlight.js'].version).to(eq('11.9.0'))
    expect(packages['tributejs'].version).to(eq('5.1.3'))
    expect(packages['@rails/ujs'].version).to(eq('7.0.4'))
  end

  it 'resolves an unpinned pin to the registry latest dist-tag' do
    expect(packages['yjs'].version).to(eq('13.6.0'))
  end

  context 'with a non-200 response' do
    let(:importmap) { "pin 'marked', to: 'https://esm.sh/marked@12.0.0'\n" }

    before { stub_request(:get, 'https://registry.npmjs.org/marked').to_return(status: 404, body: 'Not Found') }

    it 'skips the package' do
      expect(packages).to(be_empty)
    end
  end

  context 'when the version is absent from the registry' do
    let(:importmap) { "pin 'marked', to: 'https://esm.sh/marked@99.0.0'\n" }

    before { stub_request(:get, 'https://registry.npmjs.org/marked').to_return(status: 200, body: registry_body('12.0.0')) }

    it 'warns and omits the package', :aggregate_failures do
      expect { packages }
        .to(output(/version not present/).to_stderr)
      expect(packages).to(be_empty)
    end
  end
end
