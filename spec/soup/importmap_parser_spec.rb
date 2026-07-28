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

    it 'records the package as unresolved rather than dropping it', :aggregate_failures do
      expect(packages['marked']).to(have_attributes(version: '12.0.0', language: 'JS', license: 'NOASSERTION'))
      expect(packages['marked'].unresolved).to(be(true))
    end
  end

  # QUAL-002: the npm registry returns `license` as a plain String for modern
  # packages but as the legacy object form { "type": ..., "url": ... } for older
  # ones. Importmap consumes the same per-version payload as the NPM and Yarn
  # parsers, so it must coerce it the same way -- an uncoerced Hash flows through
  # to Application#validate_license, where `license.downcase` raises NoMethodError
  # and aborts the entire run. These examples cover the importmap call site, which
  # previously only ever exercised the String form.
  context 'when the registry returns a legacy object-form license' do
    let(:importmap) { "pin 'marked', to: 'https://esm.sh/marked@12.0.0'\n" }

    def licensed_body(license, version = '12.0.0')
      entry = { description: 'desc', homepage: 'https://example.com/' }
      entry[:license] = license unless license.nil?

      { 'dist-tags': { latest: version }, versions: { version => entry } }.to_json
    end

    before do
      stub_request(:get, 'https://registry.npmjs.org/marked')
        .to_return(status: 200, body: licensed_body({ type: 'MIT', url: 'https://example.com/LICENSE' }))
    end

    it 'coerces the object to its type string rather than leaving a Hash', :aggregate_failures do
      expect(packages['marked'].license).to(eq('MIT'))
      expect(packages['marked'].license).to(be_a(String))
    end

    context 'when the registry omits the license entirely' do
      before do
        stub_request(:get, 'https://registry.npmjs.org/marked').to_return(status: 200, body: licensed_body(nil))
      end

      it 'yields an empty string rather than a nil that breaks downstream matching' do
        expect(packages['marked'].license).to(eq(''))
      end
    end
  end

  # QUAL-001: the GET + post-retry timeout rescue now lives in
  # BaseParser#npm_registry_response. Importmap is the one caller that does NOT
  # pass a `label`, because the version is only resolved from the response it is
  # still waiting on -- so its warning must name the package alone, with no
  # "@version" suffix (unlike the NPM and Yarn parsers). This path had no spec
  # before the extraction.
  context 'when the registry times out' do
    let(:importmap) { "pin 'marked', to: 'https://esm.sh/marked@12.0.0'\n" }

    before { stub_request(:get, 'https://registry.npmjs.org/marked').to_timeout }

    it 'records the package and names it without a version in the warning', :aggregate_failures do
      expect { packages }
        .to(output(/Skipping marked: network timeout after retries/).to_stderr)
      expect(packages['marked']).to(have_attributes(version: '12.0.0', license: 'NOASSERTION'))
      expect(packages['marked'].unresolved).to(be(true))
    end
  end

  context 'when the version is absent from the registry' do
    let(:importmap) { "pin 'marked', to: 'https://esm.sh/marked@99.0.0'\n" }

    before { stub_request(:get, 'https://registry.npmjs.org/marked').to_return(status: 200, body: registry_body('12.0.0')) }

    it 'warns and records the package as unresolved', :aggregate_failures do
      expect { packages }
        .to(output(/version not present/).to_stderr)
      expect(packages['marked']).to(have_attributes(version: '99.0.0', license: 'NOASSERTION'))
      expect(packages['marked'].unresolved).to(be(true))
    end
  end
end
