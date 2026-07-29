# frozen_string_literal: true

require 'tempfile'
require 'tmpdir'

RSpec.describe(SOUP::Application) do
  let(:licenses_file)   { Tempfile.new(['licenses', '.json'])   }
  let(:exceptions_file) { Tempfile.new(['exceptions', '.json']) }
  let(:cache_file)      { Tempfile.new(['cache', '.json'])      }
  let(:markdown_file)   { File.join(Dir.mktmpdir, 'soup.md')    }

  before do
    licenses_file.write('["MIT", "Apache-2.0"]')
    licenses_file.close
    exceptions_file.write('["excepted-pkg"]')
    exceptions_file.close
    cache_file.write('{}')
    cache_file.close
  end

  after do
    licenses_file.unlink
    exceptions_file.unlink
    cache_file.unlink
    FileUtils.rm_rf(File.dirname(markdown_file))
  end

  def skip_all_parsers
    %w[--skip_bundler --skip_composer --skip_gradle --skip_npm --skip_pip --skip_spm --skip_yarn]
  end

  def skip_parsers_except_composer
    %w[--skip_bundler --skip_gradle --skip_npm --skip_pip --skip_spm --skip_yarn]
  end

  def skip_parsers_except_pip
    %w[--skip_bundler --skip_composer --skip_gradle --skip_npm --skip_spm --skip_yarn]
  end

  # Point detect_packages at a real requirements.txt whose registry lookup 404s,
  # so the PIP parser produces an unresolved package entry.
  def stub_unresolved_pip_package
    requirements = write_fixture('requirements.txt', "requests==2.31.0\n")
    allow(Dir).to(receive(:glob).and_return([]))
    allow(Dir).to(receive(:glob).with("#{Dir.pwd}/**/requirements.txt").and_return([requirements]))
    stub_request(:get, 'https://pypi.org/pypi/requests/json').to_return(status: 404, body: 'Not Found')
  end

  def cached_requests_entry(version:)
    {
      requests: {
        language: 'Python',
        package: 'requests',
        version: version,
        license: 'Apache Software License',
        description: 'HTTP for humans',
        website: 'https://requests.readthedocs.io',
        last_verified_at: '2026-01-01',
        risk_level: 'Low',
        requirements: 'Cached requirements',
        verification_reasoning: 'Cached reasoning'
      }
    }.to_json
  end

  # Runs a --soup scan over the stubbed requirements.txt and returns the entry
  # save_files wrote back to .soup.json.
  def scan_and_read_cached_requests
    described_class.new(soup_args(skip: skip_parsers_except_pip)).execute
    JSON.parse(File.read(cache_file.path))['requests']
  end

  def licenses_args(extra: [], skip: skip_all_parsers)
    ['--licenses', '--licenses_file', licenses_file.path, '--exceptions_file', exceptions_file.path] + extra + skip
  end

  def soup_args(extra: [], skip: skip_all_parsers)
    [
      '--soup',
      '--auto_reply',
      '--licenses_file',
      licenses_file.path,
      '--exceptions_file',
      exceptions_file.path,
      '--cache_file',
      cache_file.path,
      '--markdown_file',
      markdown_file
    ] + extra + skip
  end

  def soup_no_prompt_args(skip: skip_all_parsers)
    [
      '--soup',
      '--no_prompt',
      '--licenses_file',
      licenses_file.path,
      '--exceptions_file',
      exceptions_file.path,
      '--cache_file',
      cache_file.path,
      '--markdown_file',
      markdown_file
    ] + skip
  end

  def missing_soup_args
    [
      '--soup',
      '--auto_reply',
      '--licenses_file',
      '/nonexistent/path.json',
      '--exceptions_file',
      exceptions_file.path,
      '--cache_file',
      cache_file.path,
      '--markdown_file',
      markdown_file
    ] + skip_all_parsers
  end

  def write_existing_soup_files(cache_content, markdown_content)
    File.write(cache_file.path, cache_content)
    File.write(markdown_file, markdown_content)
  end

  def soup_nonexistent_cache_args
    [
      '--soup',
      '--auto_reply',
      '--licenses_file',
      licenses_file.path,
      '--exceptions_file',
      exceptions_file.path,
      '--cache_file',
      '/tmp/nonexistent_cache_12345.json',
      '--markdown_file',
      markdown_file
    ] + skip_all_parsers
  end

  # TEST-12: the lockfile and its sibling composer.json are written to a
  # per-example tmpdir and Dir.glob is pointed at the real path, so the parser
  # reads actual bytes. Dir stubbing stays -- detect_packages globs Dir.pwd, and
  # Dir is not File stubbing.
  def stub_composer_files(lock_content, json_content)
    write_fixture('composer.json', json_content)
    lockfile_path = write_fixture('composer.lock', lock_content)
    allow(Dir).to(receive(:glob).and_return([]))
    allow(Dir).to(receive(:glob).with("#{Dir.pwd}/**/composer.lock").and_return([lockfile_path]))
  end

  def default_composer_lock
    {
      packages: [
        {
          name: 'valid/pkg',
          version: '1.0.0',
          license: ['MIT'],
          description: 'A valid package',
          homepage: 'https://example.com'
        },
        {
          name: 'bad/pkg',
          version: '2.0.0',
          license: ['UNKNOWN-LICENSE'],
          description: 'A bad license package',
          homepage: 'https://example.com'
        },
        {
          name: 'excepted-pkg',
          version: '3.0.0',
          license: ['PROPRIETARY'],
          description: 'An excepted package',
          homepage: 'https://example.com'
        },
        {
          name: 'noassert/pkg',
          version: '4.0.0',
          license: ['NOASSERTION'],
          description: 'No assertion',
          homepage: 'https://example.com'
        }
      ],
      'packages-dev': []
    }.to_json
  end

  def default_composer_json
    '{"require":{"valid/pkg":"^1.0","bad/pkg":"^2.0","excepted-pkg":"^3.0","noassert/pkg":"^4.0"}}'
  end

  # CONS-006 regression: DEPENDENCY_TEXT used to be defined at the top level of
  # application.rb, so merely requiring soup leaked ::DEPENDENCY_TEXT into the
  # host program's Object namespace. It is now module-scoped and private, like
  # PARSER_REGISTRY below. The value itself stays covered by the markdown-output
  # example that asserts a transitive package renders "Dependency".
  describe 'DEPENDENCY_TEXT' do
    it 'does not leak into the global Object namespace' do
      expect(Object.const_defined?(:DEPENDENCY_TEXT)).to(be(false))
    end

    # Qualified access is what private_constant actually guards; Module#const_get
    # deliberately bypasses it, so asserting on const_get would pass either way.
    it 'is private on SOUP rather than publicly reachable' do
      expect { SOUP::DEPENDENCY_TEXT.to_s }
        .to(raise_error(NameError, /private constant/))
    end
  end

  # COM-001 regression: detect_packages used to carry a `next if
  # config[:parser].nil?` guard justified by a Podfile.lock entry that no longer
  # exists in the registry. The guard was removed as dead code, which is only
  # safe while every entry maps to a concrete parser: a nil placeholder would
  # now blow up on `config[:parser].new`. These examples lock that invariant in,
  # so reintroducing a nil entry fails here instead of at runtime. The registry
  # is private_constant, hence the module_eval reach-in.
  describe 'PARSER_REGISTRY' do
    subject(:registry) { SOUP.module_eval('PARSER_REGISTRY', __FILE__, __LINE__) }

    it 'maps every package file to a concrete parser class, never nil' do
      expect(registry.reject { |_file, config| config[:parser].is_a?(Class) }).to(be_empty)
    end

    it 'names a skip option that Options actually defines for every entry' do
      options = SOUP::Options.new(['--licenses', '--licenses_file', licenses_file.path, '--exceptions_file', exceptions_file.path]).parse
      expect(registry.reject { |_file, config| options.respond_to?(config[:skip]) }).to(be_empty)
    end
  end

  # CONS-001: a package whose registry lookup fails is still recorded, so the
  # register enumerates every component. When a previous run resolved it, that
  # metadata is restored rather than downgraded to NOASSERTION.
  describe 'unresolved packages' do
    before { stub_unresolved_pip_package }

    it 'records the package with NOASSERTION when nothing was cached', :aggregate_failures do
      entry = scan_and_read_cached_requests
      expect(entry['license']).to(eq('NOASSERTION'))
      expect(entry['version']).to(eq('2.31.0'))
    end

    it 'restores license, description and website from a same-version cache entry', :aggregate_failures do
      File.write(cache_file.path, cached_requests_entry(version: '2.31.0'))
      entry = scan_and_read_cached_requests
      expect(entry['license']).to(eq('Apache Software License'))
      expect(entry['description']).to(eq('HTTP for humans'))
      expect(entry['website']).to(eq('https://requests.readthedocs.io'))
    end

    # Licenses change between releases, so an older version's metadata must not
    # be carried onto a newly pinned one.
    it 'does not restore metadata cached against a different version' do
      File.write(cache_file.path, cached_requests_entry(version: '1.0.0'))
      expect(scan_and_read_cached_requests['license']).to(eq('NOASSERTION'))
    end
  end

  describe '#execute' do
    it 'runs successfully with --licenses only and no detected packages' do
      app = described_class.new(licenses_args)
      exit_code = app.execute
      expect(exit_code).to(eq(SOUP::Status::SUCCESS_EXIT_CODE))
    end

    it 'runs successfully with --soup and auto_reply' do
      app = described_class.new(soup_args)
      exit_code = app.execute
      expect(exit_code).to(eq(SOUP::Status::SUCCESS_EXIT_CODE))
    end

    context 'when CLI args trigger an OptionParser::ParseError subclass other than InvalidOption' do
      # Regression test for BUG-017: the configure_options rescue used to be
      # OptionParser::InvalidOption only, which let MissingArgument (and other
      # ParseError subclasses) escape with a stack trace instead of the
      # friendly "Error: ..." message + ERROR_EXIT_CODE.
      it 'exits with ERROR_EXIT_CODE on --licenses_file missing its required argument', :aggregate_failures do
        expect { described_class.new(['--licenses_file']) }
          .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(SOUP::Status::ERROR_EXIT_CODE)) }
                .and(output(/missing argument/).to_stderr))
      end
    end

    context 'when config file is missing' do
      def missing_licenses_args
        ['--licenses', '--licenses_file', '/nonexistent/path.json', '--exceptions_file', exceptions_file.path] + skip_all_parsers
      end

      it 'raises when config file is missing' do
        app = described_class.new(missing_licenses_args)
        expect { app.execute }
          .to(raise_error(SOUP::ConfigurationError, /Configuration file not found/))
      end

      # Regression test for BUG-08: when --soup is enabled (default) and
      # validate_config! raises before any state is populated, the ensure
      # block must NOT overwrite existing .soup.json / docs/soup.md with
      # empty content.
      it 'in --soup mode, preserves the existing cache and markdown when validate_config! raises', :aggregate_failures do
        write_existing_soup_files('{"existing/pkg":{"version":"1.0.0"}}', "# Existing SOUP\n")
        expect { described_class.new(missing_soup_args).execute }
          .to(raise_error(SOUP::ConfigurationError, /Configuration file not found/))
        expect(File.read(cache_file.path)).to(eq('{"existing/pkg":{"version":"1.0.0"}}'))
        expect(File.read(markdown_file)).to(eq("# Existing SOUP\n"))
      end
    end

    # CFG-001: the cache was the only JSON input not validated at startup.
    # read_cached_packages parsed it AFTER detect_packages had populated
    # @detected_packages, so a raw JSON::ParserError escaped through the
    # ensure-block save -- rewriting .soup.json with metadata-less entries and
    # blanking docs/soup.md, discarding previously entered IEC 62304 risk,
    # requirements and verification reasoning. Composer is stubbed here so
    # detection genuinely populates state; without the fix save_files' empty
    # -state guard would not fire and both files would be clobbered.
    context 'when the cache file has invalid JSON' do
      def corrupt_cache = '{"existing/pkg": {"version": "1.0.0"'

      def existing_markdown = "# Existing SOUP\n"

      before do
        stub_composer_files(default_composer_lock, default_composer_json)
        write_existing_soup_files(corrupt_cache, existing_markdown)
      end

      it 'raises a ConfigurationError naming the cache file' do
        expect { described_class.new(soup_args(skip: skip_parsers_except_composer)).execute }
          .to(raise_error(SOUP::ConfigurationError, /Invalid JSON in cache file/))
      end

      it 'leaves the existing cache and markdown untouched', :aggregate_failures do
        expect { described_class.new(soup_args(skip: skip_parsers_except_composer)).execute }
          .to(raise_error(SOUP::ConfigurationError))
        expect(File.read(cache_file.path)).to(eq(corrupt_cache))
        expect(File.read(markdown_file)).to(eq(existing_markdown))
      end
    end

    context 'when config file has invalid JSON' do
      let(:bad_file) do
        file = Tempfile.new(['bad', '.json'])
        file.write('not json')
        file.close
        file
      end

      after do
        bad_file.unlink if File.exist?(bad_file.path)
      end

      it 'raises when config file has invalid JSON' do
        args = ['--licenses', '--licenses_file', bad_file.path, '--exceptions_file', exceptions_file.path] + skip_all_parsers
        expect { described_class.new(args).execute }
          .to(raise_error(SOUP::ConfigurationError, /Invalid JSON/))
      end
    end

    context 'with detected packages' do
      before do
        stub_composer_files(default_composer_lock, default_composer_json)
      end

      it 'flags invalid licenses and sets error exit code' do
        app = described_class.new(licenses_args(skip: skip_parsers_except_composer))
        exit_code = app.execute
        expect(exit_code).to(eq(SOUP::Status::ERROR_EXIT_CODE))
      end

      it 'generates soup markdown with auto_reply', :aggregate_failures do
        app = described_class.new(soup_args(skip: skip_parsers_except_composer))
        app.execute
        expect(File.exist?(markdown_file)).to(be(true))
        content = File.read(markdown_file)
        expect(content).to(include('valid/pkg'))
      end

      it 'persists the parser-supplied description verbatim to the cache (no in-place mutation)' do
        # Regression test for QUAL-02: append_markdown_row used to mutate
        # package.description in place via Nokogiri.fragment.text + gsub, so
        # the persisted .soup.json contained the sanitized markdown version
        # instead of the parser-supplied description.
        described_class.new(soup_args(skip: skip_parsers_except_composer)).execute
        cached = JSON.parse(File.read(cache_file.path))
        expect(cached['valid/pkg']['description']).to(eq('A valid package'))
      end

      it 'raises with no_prompt when risk_level is missing' do
        app = described_class.new(soup_no_prompt_args(skip: skip_parsers_except_composer))
        expect { app.execute }
          .to(raise_error(SOUP::MissingMetadataError, /No risk level found/))
      end

      it 'reads cached packages from file when it exists' do
        File.write(cache_file.path, JSON.generate({ test: { risk_level: 'Low' } }))
        app = described_class.new(soup_args)
        exit_code = app.execute
        expect(exit_code).to(eq(SOUP::Status::SUCCESS_EXIT_CODE))
      end

      it 'handles non-existent cache file' do
        exit_code = described_class.new(soup_nonexistent_cache_args).execute
        expect(exit_code).to(eq(SOUP::Status::SUCCESS_EXIT_CODE))
      end
    end

    context 'with NOASSERTION license only' do
      before do
        noassert_lock = {
          packages: [
            {
              name: 'noassert/pkg',
              version: '1.0.0',
              license: ['NOASSERTION'],
              description: 'Test',
              homepage: ''
            }
          ],
          'packages-dev': []
        }.to_json
        stub_composer_files(noassert_lock, '{"require":{"noassert/pkg":"^1.0"}}')
      end

      it 'does not set error for NOASSERTION license' do
        app = described_class.new(licenses_args(skip: skip_parsers_except_composer))
        exit_code = app.execute
        expect(exit_code).to(eq(SOUP::Status::SUCCESS_EXIT_CODE))
      end
    end

    # BUG-006: config/licenses.json allowlists "Unlicense", but every parser
    # routed it through normalize_license, which rewrote it to NOASSERTION
    # before validate_license ran. The allowlist entry was therefore dead and
    # every Unlicense package warned "Invalid license NOASSERTION" on each run.
    context 'with an allowlisted Unlicense package' do
      before do
        File.write(licenses_file.path, '["MIT", "Apache-2.0", "Unlicense"]')
        unlicense_lock = {
          packages: [
            {
              name: 'unlicense/pkg',
              version: '1.0.0',
              license: ['Unlicense'],
              description: 'Public domain package',
              homepage: 'https://example.com'
            }
          ],
          'packages-dev': []
        }.to_json
        stub_composer_files(unlicense_lock, '{"require":{"unlicense/pkg":"^1.0"}}')
      end

      it 'validates against the allowlist without warning', :aggregate_failures do
        app = described_class.new(licenses_args(skip: skip_parsers_except_composer))
        expect { expect(app.execute).to(eq(SOUP::Status::SUCCESS_EXIT_CODE)) }
          .not_to(output(/Invalid license/).to_stderr)
      end

      it 'records the license as Unlicense rather than NOASSERTION' do
        app = described_class.new(soup_args(skip: skip_parsers_except_composer))
        app.execute
        expect(JSON.parse(File.read(cache_file.path))['unlicense/pkg']['license']).to(eq('Unlicense'))
      end
    end

    context 'with partial state on failure' do
      before do
        two_pkg_lock = {
          packages: [
            {
              name: 'first/pkg',
              version: '1.0.0',
              license: ['MIT'],
              description: 'First',
              homepage: 'https://example.com'
            },
            {
              name: 'second/pkg',
              version: '2.0.0',
              license: ['MIT'],
              description: 'Second',
              homepage: 'https://example.com'
            }
          ],
          'packages-dev': []
        }.to_json
        stub_composer_files(two_pkg_lock, '{"require":{"first/pkg":"^1.0","second/pkg":"^2.0"}}')
      end

      it 'saves partial state when check_packages raises an exception', :aggregate_failures do
        app = described_class.new(soup_no_prompt_args(skip: skip_parsers_except_composer))
        expect { app.execute }
          .to(raise_error(SOUP::MissingMetadataError, /No risk level found/))
        cache_content = JSON.parse(File.read(cache_file.path))
        expect(cache_content).not_to(be_empty)
      end
    end

    context 'with cached package data' do
      before do
        cached = {
          'valid/pkg': {
            last_verified_at: '2025-01-01',
            risk_level: 'Low',
            requirements: 'Required for HTTP',
            verification_reasoning: 'Well known'
          }
        }
        File.write(cache_file.path, JSON.generate(cached))
        single_lock = {
          packages: [
            {
              name: 'valid/pkg',
              version: '1.0.0',
              license: ['MIT'],
              description: 'Test',
              homepage: 'https://example.com'
            }
          ],
          'packages-dev': []
        }.to_json
        stub_composer_files(single_lock, '{"require":{"valid/pkg":"^1.0"}}')
      end

      it 'uses cached package data' do
        app = described_class.new(soup_args(skip: skip_parsers_except_composer))
        app.execute
        content = File.read(markdown_file)
        expect(content).to(include('2025-01-01'))
      end
    end

    context 'with dependency package' do
      before do
        dep_lock = {
          packages: [
            {
              name: 'dep/pkg',
              version: '1.0.0',
              license: ['MIT'],
              description: 'A dep',
              homepage: ''
            }
          ],
          'packages-dev': []
        }.to_json
        stub_composer_files(dep_lock, '{"require":{}}')
      end

      it 'marks dependencies with auto-filled fields' do
        app = described_class.new(soup_args(skip: skip_parsers_except_composer))
        app.execute
        content = File.read(markdown_file)
        expect(content).to(include('Dependency'))
      end
    end

    context 'with nil description package' do
      before do
        nil_desc_lock = {
          packages: [
            {
              name: 'nil/pkg',
              version: '1.0.0',
              license: ['MIT'],
              description: nil,
              homepage: ''
            }
          ],
          'packages-dev': []
        }.to_json
        stub_composer_files(nil_desc_lock, '{"require":{"nil/pkg":"^1.0"}}')
      end

      it 'handles package with nil description' do
        app = described_class.new(soup_args(skip: skip_parsers_except_composer))
        expect { app.execute }
          .not_to(raise_error)
      end
    end
  end
end
