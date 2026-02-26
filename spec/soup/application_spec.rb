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

  def stub_composer_files(lock_content, json_content)
    allow(Dir).to(receive(:glob).and_return([]))
    allow(Dir).to(receive(:glob).with("#{Dir.pwd}/**/composer.lock").and_return(['composer.lock']))
    allow(File).to(receive(:read).and_call_original)
    allow(File).to(receive(:read).with('composer.lock').and_return(lock_content))
    allow(File).to(receive(:read).with('composer.json').and_return(json_content))
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

    context 'when config file is missing' do
      def missing_licenses_args
        ['--licenses', '--licenses_file', '/nonexistent/path.json', '--exceptions_file', exceptions_file.path] + skip_all_parsers
      end

      it 'raises when config file is missing' do
        app = described_class.new(missing_licenses_args)
        expect { app.execute }
          .to(raise_error(/Configuration file not found/))
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
          .to(raise_error(/Invalid JSON/))
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

      it 'raises with no_prompt when risk_level is missing' do
        app = described_class.new(soup_no_prompt_args(skip: skip_parsers_except_composer))
        expect { app.execute }
          .to(raise_error(/No risk level found/))
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
          .to(raise_error(/No risk level found/))
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
