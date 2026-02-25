# frozen_string_literal: true

RSpec.describe(SOUP::GradleParser) do
  subject(:parser) { described_class.new }

  let(:lock_content) do
    [
      "# This is a comment\n",
      "com.example:library:1.0.0=classpath\n",
      "com.example:other:2.0.0=runtime\n"
    ]
  end

  let(:main_file) { 'classpath "com.example:library:1.0.0"' }

  let(:maven_response) do
    {
      response: {
        numFound: 1,
        docs: [
          {
            l: 'Apache-2.0',
            p: 'A library for example',
            home_page: 'https://example.com'
          }
        ]
      }
    }.to_json
  end

  before do
    allow(File).to(receive(:readlines).and_call_original)
    allow(File).to(receive(:readlines).with('buildscript-gradle.lockfile').and_return(lock_content))
    allow(File).to(receive(:read).and_call_original)
    allow(File).to(receive(:read).with('build.gradle').and_return(main_file))
  end

  it 'parses lockfile and only processes classpath entries' do
    stub_request(:get, %r{search\.maven\.org/solrsearch/select})
      .to_return(status: 200, body: maven_response)

    packages = {}
    parser.parse('buildscript-gradle.lockfile', packages)
    expect(packages).to(have_key('com.example:library'))
    expect(packages).not_to(have_key('com.example:other'))
  end

  it 'sets language to Kotlin' do
    stub_request(:get, %r{search\.maven\.org/solrsearch/select})
      .to_return(status: 200, body: maven_response)

    packages = {}
    parser.parse('buildscript-gradle.lockfile', packages)
    expect(packages['com.example:library'].language).to(eq('Kotlin'))
  end

  it 'extracts details from Maven Central search API' do
    stub_request(:get, %r{search\.maven\.org/solrsearch/select})
      .to_return(status: 200, body: maven_response)

    packages = {}
    parser.parse('buildscript-gradle.lockfile', packages)
    pkg = packages['com.example:library']
    expect(pkg.version).to(eq('1.0.0'))
    expect(pkg.license).to(eq('Apache-2.0'))
    expect(pkg.description).to(eq('A library for example'))
  end

  context 'when Maven Central returns 0 results' do
    let(:empty_maven_response) do
      { response: { numFound: 0, docs: [] } }.to_json
    end

    let(:pom_xml) do
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <project>
          <licenses>
            <license>
              <name>MIT License</name>
            </license>
          </licenses>
          <description>Fallback description</description>
          <url>https://fallback.example.com</url>
        </project>
      XML
    end

    it 'falls back to POM XML from repository URLs' do
      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: empty_maven_response)

      stub_request(:get, 'https://maven.google.com/com/example/library/1.0.0/library-1.0.0.pom')
        .to_return(status: 200, body: pom_xml)

      packages = {}
      parser.parse('buildscript-gradle.lockfile', packages)
      pkg = packages['com.example:library']
      expect(pkg.license).to(eq('MIT License'))
      expect(pkg.description).to(eq('Fallback description'))
      expect(pkg.website).to(eq('https://fallback.example.com'))
    end

    it 'tries multiple repository URLs until one succeeds' do
      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: empty_maven_response)

      stub_request(:get, 'https://maven.google.com/com/example/library/1.0.0/library-1.0.0.pom')
        .to_return(status: 404)

      stub_request(:get, 'https://jcenter.bintray.com/com/example/library/1.0.0/library-1.0.0.pom')
        .to_return(status: 200, body: pom_xml)

      # Stub remaining repos in case they get hit
      stub_request(:get, /plugins\.gradle\.org/).to_return(status: 404)
      stub_request(:get, /jitpack\.io/).to_return(status: 404)
      stub_request(:get, /oss\.sonatype\.org/).to_return(status: 404)
      stub_request(:get, /maven\.pkg\.github\.com/).to_return(status: 404)

      packages = {}
      parser.parse('buildscript-gradle.lockfile', packages)
      expect(packages).to(have_key('com.example:library'))
    end
  end

  it 'marks dependency based on main file content' do
    stub_request(:get, %r{search\.maven\.org/solrsearch/select})
      .to_return(status: 200, body: maven_response)

    allow(File).to(receive(:read).with('build.gradle').and_return('no match here'))

    packages = {}
    parser.parse('buildscript-gradle.lockfile', packages)
    expect(packages['com.example:library'].dependency).to(be(true))
  end
end
