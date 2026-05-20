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

  context 'when Maven Central search succeeds' do
    let(:packages) { {} }

    before do
      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: maven_response)

      parser.parse('buildscript-gradle.lockfile', packages)
    end

    it 'parses lockfile and only processes classpath entries', :aggregate_failures do
      expect(packages).to(have_key('com.example:library'))
      expect(packages).not_to(have_key('com.example:other'))
    end

    it 'sets language to Kotlin' do
      expect(packages['com.example:library'].language).to(eq('Kotlin'))
    end

    it 'extracts details from Maven Central search API', :aggregate_failures do
      pkg = packages['com.example:library']
      expect(pkg.version).to(eq('1.0.0'))
      expect(pkg.license).to(eq('Apache-2.0'))
      expect(pkg.description).to(eq('A library for example'))
    end
  end

  context 'when Maven Central returns numFound 1 but empty docs' do
    let(:inconsistent_maven_response) do
      { response: { numFound: 1, docs: [] } }.to_json
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

    before do
      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: inconsistent_maven_response)

      stub_request(:get, 'https://maven.google.com/com/example/library/1.0.0/library-1.0.0.pom')
        .to_return(status: 200, body: pom_xml)
    end

    it 'falls back to POM XML instead of crashing' do
      packages = {}
      parser.parse('buildscript-gradle.lockfile', packages)
      expect(packages['com.example:library'].license).to(eq('MIT License'))
    end
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

    before do
      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: empty_maven_response)
    end

    context 'when first repository URL succeeds' do
      before do
        stub_request(:get, 'https://maven.google.com/com/example/library/1.0.0/library-1.0.0.pom')
          .to_return(status: 200, body: pom_xml)
      end

      it 'falls back to POM XML from repository URLs', :aggregate_failures do
        packages = {}
        parser.parse('buildscript-gradle.lockfile', packages)
        pkg = packages['com.example:library']
        expect(pkg.license).to(eq('MIT License'))
        expect(pkg.description).to(eq('Fallback description'))
      end
    end

    context 'when first repository URL fails' do
      before do
        stub_request(:get, 'https://maven.google.com/com/example/library/1.0.0/library-1.0.0.pom')
          .to_return(status: 404)

        stub_request(:get, 'https://jcenter.bintray.com/com/example/library/1.0.0/library-1.0.0.pom')
          .to_return(status: 200, body: pom_xml)

        # Stub remaining repos in case they get hit
        stub_request(:get, /plugins\.gradle\.org/).to_return(status: 404)
        stub_request(:get, /jitpack\.io/).to_return(status: 404)
        stub_request(:get, /oss\.sonatype\.org/).to_return(status: 404)
        stub_request(:get, /maven\.pkg\.github\.com/).to_return(status: 404)
      end

      it 'tries multiple repository URLs until one succeeds' do
        packages = {}
        parser.parse('buildscript-gradle.lockfile', packages)
        expect(packages).to(have_key('com.example:library'))
      end
    end
  end

  context 'when package is not in main file' do
    before do
      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: maven_response)

      allow(File).to(receive(:read).with('build.gradle').and_return('no match here'))
    end

    it 'marks dependency based on main file content' do
      packages = {}
      parser.parse('buildscript-gradle.lockfile', packages)
      expect(packages['com.example:library'].dependency).to(be(true))
    end
  end

  context 'when only build.gradle.kts (Kotlin DSL) exists' do
    before do
      allow(File).to(receive(:read).with('build.gradle').and_raise(Errno::ENOENT))
      allow(File).to(receive(:read).with('build.gradle.kts').and_return(main_file))

      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: maven_response)
    end

    it 'falls back to build.gradle.kts instead of crashing', :aggregate_failures do
      packages = {}
      expect { parser.parse('buildscript-gradle.lockfile', packages) }
        .not_to(raise_error)
      expect(packages).to(have_key('com.example:library'))
    end
  end

  context 'when neither build.gradle nor build.gradle.kts exists' do
    before do
      allow(File).to(receive(:read).with('build.gradle').and_raise(Errno::ENOENT))
      allow(File).to(receive(:read).with('build.gradle.kts').and_raise(Errno::ENOENT))
    end

    it 'raises a clear error rather than a bare ENOENT' do
      packages = {}
      expect { parser.parse('buildscript-gradle.lockfile', packages) }
        .to(raise_error(/No build\.gradle or build\.gradle\.kts found/))
    end
  end

  context 'when parsing an application gradle.lockfile (runtime classpath)' do
    let(:runtime_lock_content) do
      [
        "# Gradle dependency lock file\n",
        "androidx.activity:activity-compose:1.10.1=googleProdDebugRuntimeClasspath,googleProdReleaseRuntimeClasspath\n",
        "androidx.test:runner:1.5.2=googleProdReleaseUnitTestRuntimeClasspath\n",
        "com.example:debug-only:1.0.0=googleProdDebugRuntimeClasspath\n",
        "com.example:compile-only:1.0.0=googleProdReleaseCompileClasspath\n",
        "com.example:runtime-lib:2.0.0=runtimeClasspath\n",
        "empty:no-config:0=\n"
      ]
    end

    before do
      allow(File).to(receive(:readlines).with('app/gradle.lockfile').and_return(runtime_lock_content))
      allow(File).to(receive(:read).with('app/build.gradle').and_return('implementation "androidx.activity:activity-compose:1.10.1"'))

      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: maven_response)
    end

    it 'derives the build.gradle path from the lockfile location' do
      packages = {}
      expect do
        parser.parse('app/gradle.lockfile', packages)
      end.not_to(raise_error)
    end

    it 'includes production runtime classpath entries', :aggregate_failures do
      packages = {}
      parser.parse('app/gradle.lockfile', packages)
      expect(packages).to(have_key('androidx.activity:activity-compose'))
      expect(packages).to(have_key('com.example:runtime-lib'))
    end

    it 'excludes test, debug-only, and compile-only configurations', :aggregate_failures do
      packages = {}
      parser.parse('app/gradle.lockfile', packages)
      expect(packages).not_to(have_key('androidx.test:runner'))
      expect(packages).not_to(have_key('com.example:debug-only'))
      expect(packages).not_to(have_key('com.example:compile-only'))
    end

    it 'flags transitive dependencies not declared in build.gradle', :aggregate_failures do
      packages = {}
      parser.parse('app/gradle.lockfile', packages)
      expect(packages['com.example:runtime-lib'].dependency).to(be(true))
      expect(packages['androidx.activity:activity-compose'].dependency).to(be(false))
    end
  end

  # TEST-04: malformed-lockfile coverage. The gradle lockfile is a plain
  # text format; the parser tolerates empty input and comment-only files,
  # and skips lines that don't have a key=value shape.
  describe '#parse with malformed input' do
    let(:packages) { {} }

    before do
      allow(File).to(receive(:read).and_call_original)
      allow(File).to(receive(:read).with('build.gradle').and_return("dependencies {}\n"))
      allow(File).to(receive(:read).with('build.gradle.kts').and_raise(Errno::ENOENT))
    end

    context 'with an empty gradle.lockfile' do
      before do
        allow(File).to(receive(:readlines).with('buildscript-gradle.lockfile').and_return([]))
      end

      it 'parses without raising and adds no packages', :aggregate_failures do
        expect { parser.parse('buildscript-gradle.lockfile', packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end

    context 'with a comment-only gradle.lockfile' do
      let(:lines) { ["# This is a Gradle generated file\n", "# Do not edit\n"] }

      before do
        allow(File).to(receive(:readlines).with('buildscript-gradle.lockfile').and_return(lines))
      end

      it 'parses without raising and adds no packages', :aggregate_failures do
        expect { parser.parse('buildscript-gradle.lockfile', packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end

    context 'with malformed lines missing the = separator' do
      let(:lines) { ["garbage line without equals\n", "another garbage line\n"] }

      before do
        allow(File).to(receive(:readlines).with('buildscript-gradle.lockfile').and_return(lines))
      end

      it 'parses without raising and adds no packages (silently skipped)', :aggregate_failures do
        expect { parser.parse('buildscript-gradle.lockfile', packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end
  end
end
