# frozen_string_literal: true

require 'tempfile'
require 'tmpdir'

RSpec.describe(SOUP::Application) do
  let(:licenses_file) { Tempfile.new(['licenses', '.json']) }
  let(:exceptions_file) { Tempfile.new(['exceptions', '.json']) }
  let(:cache_file) { Tempfile.new(['cache', '.json']) }
  let(:markdown_file) { File.join(Dir.mktmpdir, 'soup.md') }

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

  describe '#execute' do
    it 'runs successfully with --licenses only and no detected packages' do
      app = described_class.new(
        [
          '--licenses',
          '--licenses_file',
          licenses_file.path,
          '--exceptions_file',
          exceptions_file.path,
          '--skip_bundler',
          '--skip_composer',
          '--skip_gradle',
          '--skip_npm',
          '--skip_pip',
          '--skip_spm',
          '--skip_yarn'
        ]
      )
      exit_code = app.execute
      expect(exit_code).to(eq(SOUP::Status::SUCCESS_EXIT_CODE))
    end

    it 'runs successfully with --soup and auto_reply' do
      app = described_class.new(
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
          markdown_file,
          '--skip_bundler',
          '--skip_composer',
          '--skip_gradle',
          '--skip_npm',
          '--skip_pip',
          '--skip_spm',
          '--skip_yarn'
        ]
      )
      exit_code = app.execute
      expect(exit_code).to(eq(SOUP::Status::SUCCESS_EXIT_CODE))
    end

    it 'raises when config file is missing' do
      app = described_class.new(
        [
          '--licenses',
          '--licenses_file',
          '/nonexistent/path.json',
          '--exceptions_file',
          exceptions_file.path,
          '--skip_bundler',
          '--skip_composer',
          '--skip_gradle',
          '--skip_npm',
          '--skip_pip',
          '--skip_spm',
          '--skip_yarn'
        ]
      )
      expect { app.execute }
        .to(raise_error(/Configuration file not found/))
    end

    it 'raises when config file has invalid JSON' do
      bad_file = nil
      bad_file = Tempfile.new(['bad', '.json'])
      bad_file.write('not json')
      bad_file.close

      app = described_class.new(
        [
          '--licenses',
          '--licenses_file',
          bad_file.path,
          '--exceptions_file',
          exceptions_file.path,
          '--skip_bundler',
          '--skip_composer',
          '--skip_gradle',
          '--skip_npm',
          '--skip_pip',
          '--skip_spm',
          '--skip_yarn'
        ]
      )
      expect { app.execute }
        .to(raise_error(/Invalid JSON/))
    ensure
      bad_file.unlink if bad_file && File.exist?(bad_file.path)
    end

    context 'with detected packages' do
      let(:composer_lock) do
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

      let(:composer_json) { '{"require":{"valid/pkg":"^1.0","bad/pkg":"^2.0","excepted-pkg":"^3.0","noassert/pkg":"^4.0"}}' }

      before do
        allow(Dir).to(receive(:glob).and_return([]))
        allow(Dir).to(receive(:glob).with("#{Dir.pwd}/**/composer.lock").and_return(['composer.lock']))
        allow(File).to(receive(:read).and_call_original)
        allow(File).to(receive(:read).with('composer.lock').and_return(composer_lock))
        allow(File).to(receive(:read).with('composer.json').and_return(composer_json))
      end

      it 'flags invalid licenses and sets error exit code' do
        app = described_class.new(
          [
            '--licenses',
            '--licenses_file',
            licenses_file.path,
            '--exceptions_file',
            exceptions_file.path,
            '--skip_bundler',
            '--skip_gradle',
            '--skip_npm',
            '--skip_pip',
            '--skip_spm',
            '--skip_yarn'
          ]
        )
        exit_code = app.execute
        expect(exit_code).to(eq(SOUP::Status::ERROR_EXIT_CODE))
      end

      it 'does not set error for NOASSERTION license' do
        noassert_lock = {
          packages: [
            { name: 'noassert/pkg', version: '1.0.0', license: ['NOASSERTION'], description: 'Test', homepage: '' }
          ],
          'packages-dev': []
        }.to_json
        allow(File).to(receive(:read).with('composer.lock').and_return(noassert_lock))
        allow(File).to(receive(:read).with('composer.json').and_return('{"require":{"noassert/pkg":"^1.0"}}'))

        app = described_class.new(
          [
            '--licenses',
            '--licenses_file',
            licenses_file.path,
            '--exceptions_file',
            exceptions_file.path,
            '--skip_bundler',
            '--skip_gradle',
            '--skip_npm',
            '--skip_pip',
            '--skip_spm',
            '--skip_yarn'
          ]
        )
        exit_code = app.execute
        expect(exit_code).to(eq(SOUP::Status::SUCCESS_EXIT_CODE))
      end

      it 'generates soup markdown with auto_reply' do
        app = described_class.new(
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
            markdown_file,
            '--skip_bundler',
            '--skip_gradle',
            '--skip_npm',
            '--skip_pip',
            '--skip_spm',
            '--skip_yarn'
          ]
        )
        app.execute

        expect(File.exist?(markdown_file)).to(be(true))
        content = File.read(markdown_file)
        expect(content).to(include('valid/pkg'))
      end

      it 'raises with no_prompt when risk_level is missing' do
        app = described_class.new(
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
            markdown_file,
            '--skip_bundler',
            '--skip_gradle',
            '--skip_npm',
            '--skip_pip',
            '--skip_spm',
            '--skip_yarn'
          ]
        )
        expect { app.execute }
          .to(raise_error(/No risk level found/))
      end

      it 'uses cached package data' do
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
            { name: 'valid/pkg', version: '1.0.0', license: ['MIT'], description: 'Test', homepage: 'https://example.com' }
          ],
          'packages-dev': []
        }.to_json
        allow(File).to(receive(:read).with('composer.lock').and_return(single_lock))
        allow(File).to(receive(:read).with('composer.json').and_return('{"require":{"valid/pkg":"^1.0"}}'))

        app = described_class.new(
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
            markdown_file,
            '--skip_bundler',
            '--skip_gradle',
            '--skip_npm',
            '--skip_pip',
            '--skip_spm',
            '--skip_yarn'
          ]
        )
        app.execute

        content = File.read(markdown_file)
        expect(content).to(include('2025-01-01'))
      end

      it 'marks dependencies with auto-filled fields' do
        dep_lock = {
          packages: [
            { name: 'dep/pkg', version: '1.0.0', license: ['MIT'], description: 'A dep', homepage: '' }
          ],
          'packages-dev': []
        }.to_json
        allow(File).to(receive(:read).with('composer.lock').and_return(dep_lock))
        allow(File).to(receive(:read).with('composer.json').and_return('{"require":{}}'))

        app = described_class.new(
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
            markdown_file,
            '--skip_bundler',
            '--skip_gradle',
            '--skip_npm',
            '--skip_pip',
            '--skip_spm',
            '--skip_yarn'
          ]
        )
        app.execute

        content = File.read(markdown_file)
        expect(content).to(include('Dependency'))
      end

      it 'handles package with nil description' do
        nil_desc_lock = {
          packages: [
            { name: 'nil/pkg', version: '1.0.0', license: ['MIT'], description: nil, homepage: '' }
          ],
          'packages-dev': []
        }.to_json
        allow(File).to(receive(:read).with('composer.lock').and_return(nil_desc_lock))
        allow(File).to(receive(:read).with('composer.json').and_return('{"require":{"nil/pkg":"^1.0"}}'))

        app = described_class.new(
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
            markdown_file,
            '--skip_bundler',
            '--skip_gradle',
            '--skip_npm',
            '--skip_pip',
            '--skip_spm',
            '--skip_yarn'
          ]
        )
        expect { app.execute }
          .not_to(raise_error)
      end

      it 'reads cached packages from file when it exists' do
        cached_data = { test: { risk_level: 'Low' } }
        File.write(cache_file.path, JSON.generate(cached_data))

        app = described_class.new(
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
            markdown_file,
            '--skip_bundler',
            '--skip_composer',
            '--skip_gradle',
            '--skip_npm',
            '--skip_pip',
            '--skip_spm',
            '--skip_yarn'
          ]
        )
        exit_code = app.execute
        expect(exit_code).to(eq(SOUP::Status::SUCCESS_EXIT_CODE))
      end

      it 'handles non-existent cache file' do
        app = described_class.new(
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
            markdown_file,
            '--skip_bundler',
            '--skip_composer',
            '--skip_gradle',
            '--skip_npm',
            '--skip_pip',
            '--skip_spm',
            '--skip_yarn'
          ]
        )
        exit_code = app.execute
        expect(exit_code).to(eq(SOUP::Status::SUCCESS_EXIT_CODE))
      end
    end
  end
end
