# frozen_string_literal: true

RSpec.describe(SOUP::SPMParser) do
  subject(:parser) { described_class.new }

  let(:resolved_file) do
    {
      pins: [
        {
          identity: 'alamofire',
          location: 'https://github.com/Alamofire/Alamofire.git',
          state: { version: '5.9.0' }
        }
      ]
    }.to_json
  end

  let(:main_file_content) { '.package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.0.0")' }

  let(:github_response) do
    {
      name: 'Alamofire',
      private: false,
      license: { spdx_id: 'MIT ' },
      description: 'Elegant HTTP Networking. More details here.',
      html_url: 'https://github.com/Alamofire/Alamofire '
    }.to_json
  end

  def lockfile_path
    write_fixture(manifest_name, main_file_content) unless manifest_name.nil?
    write_fixture(resolved_name, resolved_file)
  end

  # TEST-12: Package.resolved and whichever Swift manifest the case needs are
  # written to a per-example tmpdir. The manifest-discovery chain (Package.swift
  # -> Tuist/Dependencies.swift -> *.xcodeproj/project.pbxproj -> enclosing
  # pbxproj) is then driven by which files actually exist on disk, exercising the
  # parser's real File.exist? walk instead of a stubbed one.
  def manifest_name = 'Package.swift'

  def resolved_name = 'Package.resolved'

  # ENV stubbing is out of scope for the TEST-12 fixture migration.
  before do
    allow(ENV).to(receive(:fetch).and_call_original)
    allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', '').and_return(''))
  end

  # CONS-002: HttpClient re-raises Net::ReadTimeout once its retries are
  # exhausted. Before the fix that escaped fetch_package, propagated through
  # Parallel.map, and killed the whole scan with an untyped backtrace -- even
  # though this parser already warn-and-skipped on a generic non-200, so it was
  # inconsistent with itself.
  context 'when the GitHub API times out' do
    let(:packages) { {} }

    before { stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire').to_timeout }

    it 'skips the pin instead of aborting the scan', :aggregate_failures do
      expect { parser.parse(lockfile_path, packages) }
        .not_to(raise_error)
      expect(packages).to(be_empty)
    end

    it 'names the pin in the skip warning' do
      expect { parser.parse(lockfile_path, packages) }
        .to(output(/Skipping alamofire: network timeout after retries/).to_stderr)
    end
  end

  context 'when parsing Package.resolved with GitHub API success' do
    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    let(:packages) do
      result = {}
      parser.parse(lockfile_path, result)
      result
    end

    it 'parses Package.resolved and calls GitHub API', :aggregate_failures do
      expect(packages).to(have_key('Alamofire'))
      expect(packages['Alamofire'].language).to(eq('Swift'))
      expect(packages['Alamofire'].version).to(eq('5.9.0'))
      expect(packages['Alamofire'].license).to(eq('MIT'))
      expect(packages['Alamofire'].description).to(eq('Elegant HTTP Networking'))
    end
  end

  context 'when GITHUB_TOKEN is set' do
    before do
      allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', '').and_return('ghp_test123'))
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .with(headers: { Authorization: 'token ghp_test123' })
        .to_return(status: 200, body: github_response)
    end

    it 'sends GitHub token header when GITHUB_TOKEN is set' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages).to(have_key('Alamofire'))
    end
  end

  # BUG-003 regression: a transitive package whose repo name is a substring of a
  # declared package (Alamofire within AlamofireImage) must NOT be flagged
  # direct. The old String#include? scan of the manifest mis-classified it;
  # manifest_mentions? anchors on a non-identifier boundary.
  context 'when a package name is a substring of a declared package' do
    let(:main_file_content) { '.package(url: "https://github.com/SomeOrg/AlamofireImage.git", from: "1.0.0")' }

    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    it 'classifies the substring package as transitive', :aggregate_failures do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages).to(have_key('Alamofire'))
      expect(packages['Alamofire'].dependency).to(be(true))
    end
  end

  context 'when repository has no license' do
    let(:no_license_response) do
      {
        name: 'Alamofire',
        private: false,
        license: nil,
        description: 'Elegant HTTP Networking. More details here.',
        html_url: 'https://github.com/Alamofire/Alamofire'
      }.to_json
    end

    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: no_license_response)
    end

    it 'handles repositories with no license', :aggregate_failures do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages).to(have_key('Alamofire'))
      expect(packages['Alamofire'].license).to(be_nil)
    end
  end

  context 'when repository is private' do
    let(:private_response) do
      {
        name: 'Alamofire',
        private: true,
        license: { spdx_id: 'MIT' },
        description: 'Private repo',
        html_url: 'https://github.com/Alamofire/Alamofire'
      }.to_json
    end

    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: private_response)
    end

    it 'skips private repositories' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages).to(be_empty)
    end
  end

  context 'with old format (object.pins with repositoryURL)' do
    let(:resolved_file) do
      {
        object: {
          pins: [
            {
              package: 'Alamofire',
              repositoryURL: 'https://github.com/Alamofire/Alamofire.git',
              state: { version: '5.9.0' }
            }
          ]
        }
      }.to_json
    end

    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    it 'supports old format' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages).to(have_key('Alamofire'))
    end
  end

  context 'with non-200 response' do
    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: [404, 'Not Found'], body: '{}')
    end

    it 'skips non-200 responses' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages).to(be_empty)
    end
  end

  context 'when Package.swift does not exist but Tuist Dependencies.swift does' do
    let(:manifest_name) { 'Tuist/Dependencies.swift' }
    let(:resolved_name) { 'Tuist/Package.resolved'   }

    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    it 'uses Tuist Dependencies.swift as main file' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages).to(have_key('Alamofire'))
    end
  end

  context 'when only xcodeproj exists' do
    let(:manifest_name) { 'Package.xcodeproj/project.pbxproj' }

    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    it 'uses xcodeproj as main file' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages).to(have_key('Alamofire'))
    end
  end

  context 'when Package.resolved is nested inside an Xcode-managed .xcodeproj bundle' do
    # Regression test: a standard Xcode project (not an SPM package, not Tuist)
    # stores Package.resolved at
    # <Name>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved.
    # None of the adjacent-file checks match, so the parser must walk up to the
    # enclosing .xcodeproj/project.pbxproj. Pre-fix this raised
    # InvalidLockfileError and aborted the whole soup run.
    let(:lockfile_path) do
      write_fixture('MyApp.xcodeproj/project.pbxproj', main_file_content)
      write_fixture('MyApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', resolved_file)
    end

    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    it 'reads the enclosing project.pbxproj as the main file', :aggregate_failures do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages).to(have_key('Alamofire'))
      # Named in the pbxproj => treated as a direct dependency, not transitive.
      expect(packages['Alamofire'].dependency).to(be(false))
    end
  end

  context 'when the project directory contains a dot in its name' do
    # Regression test for BUG-011: a previous implementation used
    # file.split('.').first to derive the xcodeproj path, which truncated
    # any path whose parent directory contained a dot.
    # A real directory literally named "foo.bar" on disk, so the path genuinely
    # contains the dot that the old split('.').first truncated at.
    let(:manifest_name) { 'foo.bar/MyProject/Package.xcodeproj/project.pbxproj' }
    let(:resolved_name) { 'foo.bar/MyProject/Package.resolved'                  }

    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    it 'resolves the xcodeproj sibling path without truncating at the first dot', :aggregate_failures do
      packages = {}
      expect { parser.parse(lockfile_path, packages) }
        .not_to(raise_error)
      expect(packages).to(have_key('Alamofire'))
    end
  end

  context 'when no main file exists' do
    # No Swift manifest of any name is written to the fixture dir.
    let(:manifest_name) { nil }

    it 'raises a SOUP::InvalidLockfileError naming the file' do
      packages = {}
      expect { parser.parse(lockfile_path, packages) }
        .to(raise_error(SOUP::InvalidLockfileError, /No Swift main file found/))
    end
  end

  context 'with git@ repository URLs' do
    let(:resolved_file) do
      {
        pins: [
          {
            identity: 'alamofire',
            location: 'git@github.com:Alamofire/Alamofire.git',
            state: { version: '5.9.0' }
          }
        ]
      }.to_json
    end

    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    it 'handles git@ repository URLs' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages).to(have_key('Alamofire'))
    end
  end

  context 'when rate limited' do
    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: [403, 'rate limit exceeded'], body: '{}')
    end

    it 'raises on rate limit' do
      packages = {}
      expect { parser.parse(lockfile_path, packages) }
        .to(raise_error(SOUP::RateLimitError, /rate limit/))
    end
  end

  context 'when rate limited with the real GitHub response shape' do
    # Regression test for BUG-05: GitHub returns the actionable string in the
    # response BODY (the `message` field), not in the HTTP reason phrase.
    # Pre-fix the parser only inspected `response.message` (reason phrase) so
    # this realistic 403 fell through to a silent return.
    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(
          status: [403, 'Forbidden'],
          body: { message: 'API rate limit exceeded for 1.2.3.4', documentation_url: '...' }.to_json
        )
    end

    it 'raises on rate limit even when the reason phrase does not contain the keyword' do
      packages = {}
      expect { parser.parse(lockfile_path, packages) }
        .to(raise_error(SOUP::RateLimitError, /rate limit/))
    end
  end

  context 'when GitHub returns a 5xx error' do
    # Regression test for BUG-06: the parser used to silently `return unless
    # response.code == 200` on non-200 responses, omitting the package from
    # the SOUP report with no diagnostic. It should warn via http_error_message
    # to match the discipline of every other parser post-PR #327.
    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: [502, 'Bad Gateway'], body: '<html>upstream timeout</html>')
    end

    it 'warns with status + url + package context and omits the package', :aggregate_failures do
      packages = {}
      expect { parser.parse(lockfile_path, packages) }
        .to(output(%r{HTTP 502 .*package=alamofire.*url=https://api\.github\.com/repos/Alamofire/Alamofire.*body=<html>upstream timeout</html>}m).to_stderr)
      expect(packages).to(be_empty)
    end
  end

  context 'when pin is branch-based (no version)' do
    let(:resolved_file) do
      {
        pins: [
          {
            identity: 'alamofire',
            location: 'https://github.com/Alamofire/Alamofire.git',
            state: { branch: 'main', revision: 'abc123' }
          }
        ]
      }.to_json
    end

    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    it 'records the branch as the pin identifier so the SOUP entry is not blank' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages['Alamofire'].version).to(eq('main'))
    end
  end

  context 'when pin is revision-only (no version, no branch)' do
    let(:resolved_file) do
      {
        pins: [
          {
            identity: 'alamofire',
            location: 'https://github.com/Alamofire/Alamofire.git',
            state: { revision: 'deadbeef' }
          }
        ]
      }.to_json
    end

    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    it 'falls back to the revision when neither version nor branch is set' do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages['Alamofire'].version).to(eq('deadbeef'))
    end
  end

  context 'with bad credentials' do
    before do
      allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', '').and_return('bad_token'))
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: [401, 'Bad credentials'], body: '{}')
    end

    it 'raises on bad credentials' do
      packages = {}
      expect { parser.parse(lockfile_path, packages) }
        .to(raise_error(SOUP::AuthenticationError, /Bad credentials/))
    end
  end

  # TEST-04: malformed-Package.resolved coverage. Locks in current behavior
  # so future error-handling improvements are deliberate, not accidental.
  describe '#parse with malformed input' do
    let(:packages) { {} }

    context 'with empty Package.resolved content' do
      let(:resolved_file) { '' }

      it 'raises JSON::ParserError' do
        expect { parser.parse(lockfile_path, packages) }
          .to(raise_error(JSON::ParserError))
      end
    end

    context 'with truncated JSON in Package.resolved' do
      let(:resolved_file) { '{"pins":[{"identity":"alamofire"' }

      it 'raises JSON::ParserError' do
        expect { parser.parse(lockfile_path, packages) }
          .to(raise_error(JSON::ParserError))
      end
    end

    context 'with non-JSON garbage in Package.resolved' do
      let(:resolved_file) { 'not json' }

      it 'raises JSON::ParserError' do
        expect { parser.parse(lockfile_path, packages) }
          .to(raise_error(JSON::ParserError))
      end
    end

    context 'with valid JSON but empty pins array' do
      let(:resolved_file) { '{"pins":[]}' }

      it 'parses without raising and adds no packages', :aggregate_failures do
        expect { parser.parse(lockfile_path, packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end

    # TEST-05: race where Dir.glob found the lockfile but it was deleted /
    # unreadable before File.read ran.
    context 'when Package.resolved cannot be read' do
      # A path inside the fixture dir that was never written, so the real
      # File.read raises ENOENT instead of a stub simulating it.
      let(:lockfile_path) { File.join(fixture_dir, 'gone', 'Package.resolved') }

      it 'surfaces Errno::ENOENT' do
        expect { parser.parse(lockfile_path, packages) }
          .to(raise_error(Errno::ENOENT))
      end
    end

    # TEST-12: a well-formed Package.resolved plus sibling Package.swift, read
    # straight off disk with the full GitHub metadata response.
    context 'with a well-formed Package.resolved on disk' do
      before do
        body = {
          name: 'Alamofire',
          private: false,
          license: { spdx_id: 'MIT' },
          description: 'Elegant HTTP Networking.',
          html_url: 'https://github.com/Alamofire/Alamofire'
        }.to_json
        stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
          .to_return(status: 200, body: body)
      end

      it 'reads Package.resolved + sibling Package.swift from disk without File stubs' do
        parser.parse(lockfile_path, packages)
        expect(packages['Alamofire']).to(have_attributes(language: 'Swift', version: '5.9.0', license: 'MIT'))
      end
    end
  end

  # TEST-303: exercise parallel_each at a meaningful fan-out width so a
  # parser-local concurrency or ordering regression in SPM is caught
  # by the spec suite, not just by NPM's existing scale guard.
  context 'with 100 packages (Parallel.map fan-out)' do
    let(:resolved_file) do
      pins =
        (1..100).map do |i|
          {
            identity: "pkg-#{i}",
            location: "https://github.com/example-org/pkg-#{i}.git",
            state: { version: '1.0.0' }
          }
        end
      { pins: pins }.to_json
    end

    let(:main_file_content) do
      (1..100).map { |i| %(.package(url: "https://github.com/example-org/pkg-#{i}.git", from: "1.0.0")) }
              .join("\n")
    end

    before do
      (1..100).each do |i|
        body = {
          name: "pkg-#{i}",
          private: false,
          license: { spdx_id: 'MIT' },
          description: "pkg-#{i} description",
          html_url: "https://github.com/example-org/pkg-#{i}"
        }.to_json
        stub_request(:get, "https://api.github.com/repos/example-org/pkg-#{i}").to_return(status: 200, body: body)
      end
    end

    it 'parses all 100 pins without raising and adds them to the hash', :aggregate_failures do
      packages = {}
      parser.parse(lockfile_path, packages)
      expect(packages.size).to(eq(100))
      expect(packages['pkg-1']).to(have_attributes(language: 'Swift', version: '1.0.0', license: 'MIT'))
      expect(packages['pkg-100']).to(have_attributes(language: 'Swift', version: '1.0.0', license: 'MIT'))
    end
  end

  # CONS-007: the dir == '.' branch was previously covered only incidentally, by
  # specs that stubbed File.read and so passed 'Package.resolved' rather than a
  # real path. Now that every fixture is an absolute tmpdir path, the helper is
  # asserted directly, the same way base_parser_spec exposes BaseParser's own
  # protected helpers.
  describe '#path_join' do
    subject(:helper) { helper_class.new }

    let(:helper_class) do
      Class.new(described_class) do
        public :path_join
      end
    end

    it 'returns the bare suffix when the directory is "."' do
      expect(helper.path_join('.', 'Package.swift')).to(eq('Package.swift'))
    end

    it 'joins the suffix onto a real directory without a leading "./"' do
      expect(helper.path_join('/tmp/proj', 'Package.swift')).to(eq('/tmp/proj/Package.swift'))
    end
  end
end
