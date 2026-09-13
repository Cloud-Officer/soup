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

  def maven_central = 'https://repo1.maven.org/maven2'

  def maven_google = 'https://maven.google.com'

  def any_repository = /repo1\.maven\.org|maven\.google\.com|plugins\.gradle\.org|jitpack\.io|oss\.sonatype\.org/

  def pom_url(repository, coordinate)
    group_id, artifact_id, version = coordinate.split(':')
    "#{repository}/#{group_id.tr('.', '/')}/#{artifact_id}/#{version}/#{artifact_id}-#{version}.pom"
  end

  def stub_pom(coordinate, body: '', status: 200, repository: maven_central)
    stub_request(:get, pom_url(repository, coordinate)).to_return(status: status, body: body)
  end

  def real_pom(name) = File.read(File.expand_path("../fixtures/gradle/#{name}.pom", __dir__))

  def pom_xml(licenses: ['MIT License'], parent: nil, description: 'A library for example')
    parent_xml =
      if parent
        group_id, artifact_id, version = parent.split(':')
        "<parent><groupId>#{group_id}</groupId><artifactId>#{artifact_id}</artifactId><version>#{version}</version></parent>"
      end

    licenses_xml = licenses.map { |name| "<license><name>#{name}</name></license>" }

    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <project xmlns="http://maven.apache.org/POM/4.0.0">
        #{parent_xml}
        <licenses>#{licenses_xml.join}</licenses>
        <description>#{description}</description>
        <url>https://example.com</url>
      </project>
    XML
  end

  def parse_packages
    packages = {}
    parser.parse(lockfile_path, packages)
    packages
  end

  context 'when Maven Central serves the POM' do
    let(:packages) { parse_packages }

    before { stub_pom('com.example:library:1.0.0', body: pom_xml) }

    it 'parses lockfile and only processes classpath entries', :aggregate_failures do
      expect(packages).to(have_key('Kotlin:com.example:library'))
      expect(packages).not_to(have_key('Kotlin:com.example:other'))
    end

    it 'sets language to Kotlin' do
      expect(packages['Kotlin:com.example:library'].language).to(eq('Kotlin'))
    end

    it 'extracts license, description and website from the POM', :aggregate_failures do
      expect(packages['Kotlin:com.example:library'])
        .to(have_attributes(version: '1.0.0', license: 'MIT License', description: 'A library for example', website: 'https://example.com'))
      expect(packages['Kotlin:com.example:library'].unresolved).to(be_falsey)
    end

    it 'does not query the search.maven.org search API' do
      packages
      expect(a_request(:get, /search\.maven\.org/)).not_to(have_been_made)
    end
  end

  context 'with real published POMs' do
    let(:main_file) { 'implementation "com.google.guava:guava:33.0.0-jre"' }

    context 'when the license is only declared in the parent POM (guava)' do
      let(:lock_content) { ["com.google.guava:guava:33.0.0-jre=classpath\n"] }

      before do
        stub_pom('com.google.guava:guava:33.0.0-jre', body: real_pom('guava-33.0.0-jre'))
        stub_pom('com.google.guava:guava-parent:33.0.0-jre', body: real_pom('guava-parent-33.0.0-jre'))
      end

      it 'inherits the license from guava-parent and keeps its own description and website', :aggregate_failures do
        pkg = parse_packages['Kotlin:com.google.guava:guava']
        expect(pkg.license).to(eq('Apache License, Version 2.0'))
        expect(pkg.description).to(start_with('Guava is a suite of core and expanded libraries'))
        expect(pkg.website).to(eq('https://github.com/google/guava'))
      end
    end

    context 'when the POM declares its own license (okhttp)' do
      let(:lock_content) { ["com.squareup.okhttp3:okhttp:4.12.0=classpath\n"] }

      before { stub_pom('com.squareup.okhttp3:okhttp:4.12.0', body: real_pom('okhttp-4.12.0')) }

      it 'records the license without looking for a parent' do
        expect(parse_packages['Kotlin:com.squareup.okhttp3:okhttp'].license).to(eq('The Apache Software License, Version 2.0'))
      end
    end

    context 'when the artifact is only on Google Maven (androidx core)' do
      let(:lock_content) { ["androidx.core:core:1.12.0=classpath\n"] }

      before do
        stub_pom('androidx.core:core:1.12.0', status: 404)
        stub_pom('androidx.core:core:1.12.0', body: real_pom('core-1.12.0'), repository: maven_google)
      end

      it 'falls through to maven.google.com and reads the license' do
        expect(parse_packages['Kotlin:androidx.core:core'].license).to(eq('The Apache Software License, Version 2.0'))
      end
    end
  end

  context 'when the POM lists several licenses' do
    before { stub_pom('com.example:library:1.0.0', body: pom_xml(licenses: ['Apache-2.0', 'MIT'])) }

    it 'joins every license name' do
      expect(parse_packages['Kotlin:com.example:library'].license).to(eq('Apache-2.0, MIT'))
    end
  end

  context 'when no POM names a license' do
    before { stub_request(:get, any_repository).to_return(status: 404) }

    it 'records NOASSERTION when the POM has no licenses and no parent' do
      stub_pom('com.example:library:1.0.0', body: pom_xml(licenses: []))
      expect(parse_packages['Kotlin:com.example:library'].license).to(eq('NOASSERTION'))
    end

    it 'records NOASSERTION when the parent POM cannot be found' do
      stub_pom('com.example:library:1.0.0', body: pom_xml(licenses: [], parent: 'com.example:parent:1.0.0'))
      expect(parse_packages['Kotlin:com.example:library'].license).to(eq('NOASSERTION'))
    end

    it 'records NOASSERTION when the parent reference is incomplete' do
      stub_pom('com.example:library:1.0.0', body: pom_xml(licenses: [], parent: 'com.example:parent'))
      expect(parse_packages['Kotlin:com.example:library'].license).to(eq('NOASSERTION'))
    end
  end

  context 'when the parent chain is deeper than the POM depth limit' do
    before do
      stub_pom('com.example:library:1.0.0', body: pom_xml(licenses: [], parent: 'com.example:chain-1:1.0.0'))
      (1..4).each { |i| stub_pom("com.example:chain-#{i}:1.0.0", body: pom_xml(licenses: [], parent: "com.example:chain-#{i + 1}:1.0.0")) }
      stub_pom('com.example:chain-5:1.0.0', body: pom_xml(licenses: ['MIT License']))
    end

    it 'stops after five POMs without fetching further ancestors', :aggregate_failures do
      expect(parse_packages['Kotlin:com.example:library'].license).to(eq('NOASSERTION'))
      expect(a_request(:get, /chain-5/)).not_to(have_been_made)
    end
  end

  context 'when the parent POM is only on Maven Central' do
    before do
      stub_request(:get, any_repository).to_return(status: 404)
      stub_pom('com.example:library:1.0.0', body: pom_xml(licenses: [], parent: 'com.example:parent:1.0.0'), repository: maven_google)
      stub_pom('com.example:parent:1.0.0', body: pom_xml(licenses: ['BSD-3-Clause']))
    end

    it 'looks the parent up on Maven Central after the serving repository' do
      expect(parse_packages['Kotlin:com.example:library'].license).to(eq('BSD-3-Clause'))
    end
  end

  context 'when the first repositories do not have the POM' do
    before do
      stub_request(:get, any_repository).to_return(status: 404)
      stub_request(:get, %r{plugins\.gradle\.org/m2/com/example/library/1\.0\.0/library-1\.0\.0\.pom}).to_return(status: 200, body: pom_xml)
    end

    it 'tries multiple repository URLs until one succeeds' do
      expect(parse_packages['Kotlin:com.example:library'].license).to(eq('MIT License'))
    end
  end

  context 'when every repository returns a non-200' do
    # Regression test for BUG-07: the warn used to be a one-liner that
    # dropped the URL, HTTP status, and response body, making maven-side
    # failures opaque. It now uses BaseParser#http_error_message so the
    # operator sees status + url + truncated body.
    before { stub_request(:get, any_repository).to_return(status: 503, body: 'repository offline') }

    it 'warns with http_error_message and records the coordinate', :aggregate_failures do
      packages = {}
      expect { parser.parse(lockfile_path, packages) }
        .to(output(/HTTP 503.*com\.example:library 1\.0\.0.*\.pom.*offline/m).to_stderr)
      expect(packages['Kotlin:com.example:library']).to(have_attributes(version: '1.0.0', language: 'Kotlin', license: 'NOASSERTION'))
      expect(packages['Kotlin:com.example:library'].unresolved).to(be(true))
    end
  end

  # A Net::ReadTimeout on one repository must fall through to the next, not abort the run.
  context 'when a repository times out' do
    context 'with a later repository that resolves the package' do
      before do
        stub_request(:get, /repo1\.maven\.org/).to_timeout
        stub_pom('com.example:library:1.0.0', body: pom_xml, repository: maven_google)
      end

      it 'falls through to the next repository instead of aborting', :aggregate_failures do
        packages = {}
        expect { parser.parse(lockfile_path, packages) }
          .not_to(raise_error)
        expect(packages['Kotlin:com.example:library'].license).to(eq('MIT License'))
      end
    end

    context 'when every repository times out' do
      before { stub_request(:get, any_repository).to_timeout }

      it 'warns and records the coordinate without raising', :aggregate_failures do
        packages = {}
        expect { parser.parse(lockfile_path, packages) }
          .to(output(/all Maven lookups timed out/).to_stderr)
        expect(packages['Kotlin:com.example:library']).to(have_attributes(version: '1.0.0', license: 'NOASSERTION'))
        expect(packages['Kotlin:com.example:library'].unresolved).to(be(true))
      end
    end
  end

  context 'with a POM for every coordinate on Maven Central' do
    before { stub_request(:get, %r{repo1\.maven\.org/maven2/.+\.pom}).to_return(status: 200, body: pom_xml) }

    context 'when package is not in main file' do
      let(:main_file) { 'no match here' }

      it 'marks dependency based on main file content' do
        expect(parse_packages['Kotlin:com.example:library'].dependency).to(be(true))
      end
    end

    # BUG-003 regression: a transitive coordinate whose name is a substring of a
    # declared dependency (com.example:lib within com.example:library) must NOT be
    # flagged direct. The old String#include? scan of build.gradle mis-classified
    # it; manifest_mentions? anchors on a non-identifier boundary.
    context 'when a transitive coordinate is a substring of a declared dependency' do
      let(:lock_content) { ["com.example:lib:1.0.0=classpath\n"]   }
      let(:main_file)    { 'classpath "com.example:library:1.0.0"' }

      it 'classifies the substring coordinate as transitive' do
        expect(parse_packages['Kotlin:com.example:lib'].dependency).to(be(true))
      end
    end

    context 'when only build.gradle.kts (Kotlin DSL) exists' do
      # Only the Kotlin DSL file is written, so the parser's real ENOENT rescue
      # on build.gradle drives the fallback.
      let(:main_file_name) { 'build.gradle.kts' }

      it 'falls back to build.gradle.kts instead of crashing', :aggregate_failures do
        packages = {}
        expect { parser.parse(lockfile_path, packages) }
          .not_to(raise_error)
        expect(packages).to(have_key('Kotlin:com.example:library'))
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

      it 'derives the build.gradle path from the lockfile location' do
        expect { parse_packages }
          .not_to(raise_error)
      end

      it 'includes production runtime classpath entries', :aggregate_failures do
        packages = parse_packages
        expect(packages).to(have_key('Kotlin:androidx.activity:activity-compose'))
        expect(packages).to(have_key('Kotlin:com.example:runtime-lib'))
      end

      it 'excludes test, debug-only, and compile-only configurations', :aggregate_failures do
        packages = parse_packages
        expect(packages).not_to(have_key('Kotlin:androidx.test:runner'))
        expect(packages).not_to(have_key('Kotlin:com.example:debug-only'))
        expect(packages).not_to(have_key('Kotlin:com.example:compile-only'))
      end

      it 'flags transitive dependencies not declared in build.gradle', :aggregate_failures do
        packages = parse_packages
        expect(packages['Kotlin:com.example:runtime-lib'].dependency).to(be(true))
        expect(packages['Kotlin:androidx.activity:activity-compose'].dependency).to(be(false))
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

      it 'parses all 100 classpath entries without raising and adds them to the hash', :aggregate_failures do
        packages = parse_packages
        expect(packages.size).to(eq(100))
        expect(packages['Kotlin:com.example:lib-1']).to(have_attributes(language: 'Kotlin', version: '1.0.0', license: 'MIT License'))
        expect(packages['Kotlin:com.example:lib-100']).to(have_attributes(language: 'Kotlin', version: '1.0.0', license: 'MIT License'))
      end
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

      before { stub_pom('com.example:library:1.0.0', body: pom_xml) }

      it 'reads the lockfile + sibling build.gradle from disk without File stubs' do
        parser.parse(lockfile_path, packages)
        expect(packages['Kotlin:com.example:library']).to(have_attributes(language: 'Kotlin', version: '1.0.0', license: 'MIT License'))
      end
    end
  end
end
