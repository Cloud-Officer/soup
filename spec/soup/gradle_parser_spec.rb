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

  def lockfile_path
    write_fixture(main_file_name, main_file) unless main_file.nil?
    write_fixture(lockfile_name, Array(lock_content).join)
  end

  # TEST-12: the lockfile and its sibling build script are written to a
  # per-example tmpdir. Which manifest exists is expressed by writing it or not
  # -- `main_file_name` selects the Groovy or Kotlin DSL, and a nil `main_file`
  # writes neither -- so the parser's real Errno::ENOENT fallback runs instead
  # of a stubbed one.
  def lockfile_name = 'buildscript-gradle.lockfile'

  def main_file_name = 'build.gradle'

  context 'when Maven Central search succeeds' do
    let(:packages) { {} }

    before do
      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: maven_response)

      parser.parse(lockfile_path, packages)
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
      parser.parse(lockfile_path, packages)
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
        parser.parse(lockfile_path, packages)
        pkg = packages['com.example:library']
        expect(pkg.license).to(eq('MIT License'))
        expect(pkg.description).to(eq('Fallback description'))
      end
    end

    context 'when first repository URL fails' do
      before do
        stub_request(:get, 'https://maven.google.com/com/example/library/1.0.0/library-1.0.0.pom')
          .to_return(status: 404)

        stub_request(:get, %r{plugins\.gradle\.org/m2/.*com/example/library/1\.0\.0/library-1\.0\.0\.pom})
          .to_return(status: 200, body: pom_xml)

        # Stub remaining repos in case they get hit
        stub_request(:get, /jitpack\.io/).to_return(status: 404)
        stub_request(:get, /oss\.sonatype\.org/).to_return(status: 404)
      end

      it 'tries multiple repository URLs until one succeeds' do
        packages = {}
        parser.parse(lockfile_path, packages)
        expect(packages).to(have_key('com.example:library'))
      end
    end

    context 'when every fallback repository returns a non-200' do
      # Regression test for BUG-07: the warn used to be a one-liner that
      # dropped the URL, HTTP status, and response body, making maven-side
      # failures opaque. It now uses BaseParser#http_error_message so the
      # operator sees status + url + truncated body.
      before do
        stub_request(:get, /maven\.google\.com/).to_return(status: 503, body: 'maven.google: gateway timeout')
        stub_request(:get, /plugins\.gradle\.org/).to_return(status: 503, body: 'plugins offline')
        stub_request(:get, /jitpack\.io/).to_return(status: 503, body: 'jitpack offline')
        stub_request(:get, /oss\.sonatype\.org/).to_return(status: 503, body: 'sonatype offline')
      end

      it 'warns with http_error_message and records the coordinate', :aggregate_failures do
        packages = {}
        expect { parser.parse(lockfile_path, packages) }
          .to(output(/HTTP 503.*com\.example:library 1\.0\.0.*\.pom.*offline/m).to_stderr)
        expect(packages['com.example:library']).to(have_attributes(version: '1.0.0', language: 'Kotlin', license: 'NOASSERTION'))
        expect(packages['com.example:library'].unresolved).to(be(true))
      end
    end
  end

  # Regression: search.maven.org's solrsearch endpoint chronically stops
  # responding (Net::ReadTimeout). HttpClient re-raises after its retries, and
  # that exception used to propagate through Parallel.map and abort the entire
  # SOUP run. It must instead fall through to the per-repository POM mirrors.
  context 'when Maven Central search times out' do
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

    context 'with a fallback repository that resolves the package' do
      before do
        stub_request(:get, %r{search\.maven\.org/solrsearch/select}).to_timeout
        stub_request(:get, 'https://maven.google.com/com/example/library/1.0.0/library-1.0.0.pom')
          .to_return(status: 200, body: pom_xml)
      end

      it 'falls through to the POM mirror instead of aborting', :aggregate_failures do
        packages = {}
        expect { parser.parse(lockfile_path, packages) }
          .not_to(raise_error)
        expect(packages['com.example:library'].license).to(eq('MIT License'))
      end
    end

    context 'when every source also times out' do
      before do
        stub_request(:get, /search\.maven\.org/).to_timeout
        stub_request(:get, /maven\.google\.com/).to_timeout
        stub_request(:get, /plugins\.gradle\.org/).to_timeout
        stub_request(:get, /jitpack\.io/).to_timeout
        stub_request(:get, /oss\.sonatype\.org/).to_timeout
      end

      it 'warns and records the coordinate without raising', :aggregate_failures do
        packages = {}
        expect { parser.parse(lockfile_path, packages) }
          .to(output(/all Maven lookups timed out/).to_stderr)
        expect(packages['com.example:library']).to(have_attributes(version: '1.0.0', license: 'NOASSERTION'))
        expect(packages['com.example:library'].unresolved).to(be(true))
      end
    end
  end

  context 'when package is not in main file' do
    let(:main_file) { 'no match here' }

    before do
      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: maven_response)
    end

    it 'marks dependency based on main file content' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages['com.example:library'].dependency).to(be(true))
    end
  end

  # BUG-003 regression: a transitive coordinate whose name is a substring of a
  # declared dependency (com.example:lib within com.example:library) must NOT be
  # flagged direct. The old String#include? scan of build.gradle mis-classified
  # it; manifest_mentions? anchors on a non-identifier boundary.
  context 'when a transitive coordinate is a substring of a declared dependency' do
    let(:lock_content) { ["com.example:lib:1.0.0=classpath\n"]   }
    let(:main_file)    { 'classpath "com.example:library:1.0.0"' }

    before do
      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: maven_response)
    end

    it 'classifies the substring coordinate as transitive' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages['com.example:lib'].dependency).to(be(true))
    end
  end

  context 'when only build.gradle.kts (Kotlin DSL) exists' do
    # Only the Kotlin DSL file is written, so the parser's real ENOENT rescue
    # on build.gradle drives the fallback.
    let(:main_file_name) { 'build.gradle.kts' }

    before do
      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: maven_response)
    end

    it 'falls back to build.gradle.kts instead of crashing', :aggregate_failures do
      packages = {}
      expect { parser.parse(lockfile_path, packages) }
        .not_to(raise_error)
      expect(packages).to(have_key('com.example:library'))
    end
  end

  context 'when neither build.gradle nor build.gradle.kts exists' do
    # No manifest of either name is written to the fixture dir.
    let(:main_file) { nil }

    it 'raises a clear error rather than a bare ENOENT' do
      packages = {}
      expect { parser.parse(lockfile_path, packages) }
        .to(raise_error(SOUP::InvalidLockfileError, /No build\.gradle or build\.gradle\.kts found/))
    end
  end

  context 'when parsing an application gradle.lockfile (runtime classpath)' do
    def lockfile_name = 'app/gradle.lockfile'

    def main_file_name = 'app/build.gradle'

    let(:lock_content) do
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

    let(:main_file) { 'implementation "androidx.activity:activity-compose:1.10.1"' }

    before do
      stub_request(:get, %r{search\.maven\.org/solrsearch/select})
        .to_return(status: 200, body: maven_response)
    end

    it 'derives the build.gradle path from the lockfile location' do
      packages = {}
      expect do
        parser.parse(lockfile_path, packages)
      end.not_to(raise_error)
    end

    it 'includes production runtime classpath entries', :aggregate_failures do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages).to(have_key('androidx.activity:activity-compose'))
      expect(packages).to(have_key('com.example:runtime-lib'))
    end

    it 'excludes test, debug-only, and compile-only configurations', :aggregate_failures do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages).not_to(have_key('androidx.test:runner'))
      expect(packages).not_to(have_key('com.example:debug-only'))
      expect(packages).not_to(have_key('com.example:compile-only'))
    end

    it 'flags transitive dependencies not declared in build.gradle', :aggregate_failures do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages['com.example:runtime-lib'].dependency).to(be(true))
      expect(packages['androidx.activity:activity-compose'].dependency).to(be(false))
    end
  end

  # TEST-04: malformed-lockfile coverage. The gradle lockfile is a plain
  # text format; the parser tolerates empty input and comment-only files,
  # and skips lines that don't have a key=value shape.
  describe '#parse with malformed input' do
    let(:packages) { {} }

    let(:main_file) { "dependencies {}\n" }

    context 'with an empty gradle.lockfile' do
      let(:lock_content) { [] }

      it 'parses without raising and adds no packages', :aggregate_failures do
        expect { parser.parse(lockfile_path, packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end

    context 'with a comment-only gradle.lockfile' do
      let(:lock_content) { ["# This is a Gradle generated file\n", "# Do not edit\n"] }

      it 'parses without raising and adds no packages', :aggregate_failures do
        expect { parser.parse(lockfile_path, packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end

    context 'with malformed lines missing the = separator' do
      let(:lock_content) { ["garbage line without equals\n", "another garbage line\n"] }

      it 'parses without raising and adds no packages (silently skipped)', :aggregate_failures do
        expect { parser.parse(lockfile_path, packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end

    # TEST-05: race where Dir.glob found the lockfile but it was deleted /
    # unreadable before File.readlines ran.
    context 'when the lockfile cannot be read' do
      # A path inside the fixture dir that was never written, so the real
      # File.readlines raises ENOENT instead of a stub simulating it.
      let(:lockfile_path) { File.join(fixture_dir, 'gone', 'buildscript-gradle.lockfile') }

      it 'surfaces Errno::ENOENT' do
        expect { parser.parse(lockfile_path, packages) }
          .to(raise_error(Errno::ENOENT))
      end
    end

    # TEST-12: a well-formed lockfile plus sibling build.gradle read off disk.
    context 'with a well-formed lockfile on disk' do
      let(:lock_content) do
        <<~LOCK
          # This is a Gradle lockfile
          com.example:library:1.0.0=classpath
        LOCK
      end

      let(:main_file) { 'classpath "com.example:library:1.0.0"' }

      before do
        stub_request(:get, %r{search\.maven\.org/solrsearch/select})
          .to_return(status: 200, body: maven_response)
      end

      it 'reads the lockfile + sibling build.gradle from disk without File stubs' do
        packages = {}
        parser.parse(lockfile_path, packages)
        expect(packages['com.example:library']).to(have_attributes(language: 'Kotlin', version: '1.0.0', license: 'Apache-2.0'))
      end
    end
  end

  # TEST-303: exercise parallel_each at a meaningful fan-out width so a
  # parser-local concurrency or ordering regression in Gradle is caught
  # by the spec suite, not just by NPM's existing scale guard.
  context 'with 100 packages (Parallel.map fan-out)' do
    let(:lock_content) do
      (1..100).map { |i| "com.example:lib-#{i}:1.0.0=classpath\n" }
    end

    let(:main_file) do
      (1..100).map { |i| %(classpath "com.example:lib-#{i}:1.0.0") }
              .join("\n")
    end

    let(:maven_response_for) do
      lambda do |i|
        {
          response: {
            numFound: 1,
            docs: [
              { l: 'Apache-2.0', p: "lib-#{i} description", home_page: 'https://example.com' }
            ]
          }
        }.to_json
      end
    end

    before do
      (1..100).each do |i|
        stub_request(:get, %r{search\.maven\.org/solrsearch/select.*a:%22lib-#{i}%22})
          .to_return(status: 200, body: maven_response_for.call(i))
      end
    end

    it 'parses all 100 classpath entries without raising and adds them to the hash', :aggregate_failures do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages.size).to(eq(100))
      expect(packages['com.example:lib-1']).to(have_attributes(language: 'Kotlin', version: '1.0.0', license: 'Apache-2.0'))
      expect(packages['com.example:lib-100']).to(have_attributes(language: 'Kotlin', version: '1.0.0', license: 'Apache-2.0'))
    end
  end
end
