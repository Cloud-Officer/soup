# frozen_string_literal: true

require 'tmpdir'

# Exercises the manual-entries parser and the vendored-JS coverage gate end to
# end: a committed vendored file with no SOUP entry must fail the run, and one
# declared in the manual file must pass.
RSpec.describe(SOUP::Application) do
  let(:root) { Dir.mktmpdir('soup-app-') }

  after { FileUtils.rm_rf(root) }

  def write(relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def run(manual_entries, vendored: ['vendor/javascript/tiptap-pro.js'])
    write('config/licenses.json', '["MIT"]')
    write('config/exceptions.json', '[]')
    write('config/soup-manual.json', manual_entries.to_json)
    vendored.each { |relative| write(relative, '// vendored') }

    argv = [
      '--soup',
      '--auto_reply',
      '--licenses_file',
      File.join(root, 'config/licenses.json'),
      '--exceptions_file',
      File.join(root, 'config/exceptions.json'),
      '--manual_file',
      File.join(root, 'config/soup-manual.json'),
      '--cache_file',
      File.join(root, '.soup.json'),
      '--markdown_file',
      File.join(root, 'docs/soup.md'),
      '--vendored_globs',
      'vendor/javascript/**/*.js',
      '--skip_bundler',
      '--skip_composer',
      '--skip_gradle',
      '--skip_importmap',
      '--skip_npm',
      '--skip_pip',
      '--skip_spm',
      '--skip_yarn'
    ]

    # detect_packages globs Dir.pwd by design, so the gate must run in `root`.
    Dir.chdir(root) { described_class.new(argv).execute } # rubocop:disable ThreadSafety/DirChdir
  end

  it 'fails when a vendored JS file has no manual SOUP entry', :aggregate_failures do
    exit_code = nil
    expect { exit_code = run([]) }
      .to(output(/tiptap-pro\.js has no SOUP entry/).to_stderr)
    expect(exit_code).to(eq(SOUP::Status::ERROR_EXIT_CODE))
  end

  it 'passes and records the entry when the vendored file is declared', :aggregate_failures do
    entries = [{ package: 'tiptap-pro', file: 'vendor/javascript/tiptap-pro.js', license: 'MIT', version: '1.0.0' }]
    exit_code = run(entries)
    expect(exit_code).to(eq(SOUP::Status::SUCCESS_EXIT_CODE))
    expect(File.read(File.join(root, 'docs/soup.md'))).to(include('tiptap-pro'))
  end

  it 'passes when the entry declares the vendored file by bare filename' do
    entries = [{ package: 'tiptap-pro', file: 'tiptap-pro.js', license: 'MIT', version: '1.0.0' }]
    expect(run(entries)).to(eq(SOUP::Status::SUCCESS_EXIT_CODE))
  end

  it 'fails when the entry declares a same-named file in another directory', :aggregate_failures do
    entries = [{ package: 'tiptap-pro', file: 'app/assets/tiptap-pro.js', license: 'MIT', version: '1.0.0' }]
    exit_code = nil
    expect { exit_code = run(entries) }
      .to(output(%r{vendor/javascript/tiptap-pro\.js has no SOUP entry}).to_stderr)
    expect(exit_code).to(eq(SOUP::Status::ERROR_EXIT_CODE))
  end

  it 'fails naming the undeclared path when two vendored files share a basename', :aggregate_failures do
    entries = [{ package: 'editor', file: 'vendor/javascript/a/editor.js', license: 'MIT', version: '1.0.0' }]
    exit_code = nil
    expect { exit_code = run(entries, vendored: %w[vendor/javascript/a/editor.js vendor/javascript/b/editor.js]) }
      .to(output(%r{\AVendored file vendor/javascript/b/editor\.js has no SOUP entry[^\n]*\n\z}).to_stderr)
    expect(exit_code).to(eq(SOUP::Status::ERROR_EXIT_CODE))
  end
end
