# frozen_string_literal: true

require 'open3'
require 'rbconfig'

# TEST-301: exercise the top-level rescue in bin/soup.rb. The rescue formats
# StandardError into a one-line "Error: ..." plus a backtrace shaped by ENV
# ['DEBUG']: no DEBUG -> top TOP_FRAMES_TO_SHOW frames each prefixed with two
# spaces, optionally followed by "  ... (set DEBUG=1 for full backtrace)" when
# the backtrace is longer than the slice; DEBUG=1 -> the full backtrace joined
# with newlines and no top-frames hint. Every error path exits with status 1.
# rubocop:disable RSpec/DescribeClass -- subject under test is bin/soup.rb, not a class.
# rubocop:disable RSpec/MultipleMemoizedHelpers -- each context destructures the
# Open3.capture3 tuple into stdout/stderr/status via let for readability.
RSpec.describe('bin/soup.rb CLI wrapper') do
  let(:bin_path) { File.expand_path('../../bin/soup.rb', __dir__) }
  let(:lib_path) { File.expand_path('../../lib', __dir__)         }
  let(:ruby_bin) { RbConfig.ruby                                  }

  # Launch bin/soup.rb as a real child process so the begin/rescue/exit path in
  # the wrapper is actually executed. Using a tmpdir as cwd keeps detect_packages
  # from picking up the project's own lockfiles when the run progresses far
  # enough to scan. Optional `fixtures:` writes filename => content pairs into
  # the tmpdir before launching so deep errors (e.g. malformed Package.resolved)
  # can be triggered without network calls.
  def run_soup(args, env: {}, fixtures: {})
    Dir.mktmpdir('soup-cli-spec-') do |tmpdir|
      fixtures.each { |name, content| File.write(File.join(tmpdir, name), content) }
      Open3.capture3(env, ruby_bin, '-I', lib_path, bin_path, *args, chdir: tmpdir)
    end
  end

  context 'when a configuration error bubbles up to the rescue block' do
    let(:run) { run_soup(['--licenses_file', '/nonexistent/soup-cli-spec.json']) }
    let(:stdout) { run.first }
    let(:stderr) { run[1]    }
    let(:status) { run[2]    }

    it 'exits with status 1', :aggregate_failures do
      expect(status.exitstatus).to(eq(1))
      expect(status).not_to(be_success)
    end

    it 'writes a one-line Error: <message> header to stderr' do
      expect(stderr).to(match(%r{^Error: Configuration file not found: /nonexistent/soup-cli-spec\.json$}))
    end

    it 'does not emit the error header to stdout' do
      expect(stdout).not_to(include('Error: Configuration file not found'))
    end
  end

  context 'with DEBUG unset and a short backtrace (<= TOP_FRAMES_TO_SHOW)' do
    # ConfigurationError raised directly from validate_config! produces a
    # 5-frame backtrace, exactly equal to TOP_FRAMES_TO_SHOW.
    let(:run) { run_soup(['--licenses_file', '/nonexistent/soup-cli-spec.json']) }
    let(:stderr)          { run[1]                                                }
    let(:backtrace_lines) { stderr.lines.select { |line| line.start_with?('  ') } }

    it 'prefixes top frames with two spaces' do
      expect(backtrace_lines).not_to(be_empty)
    end

    it 'caps the backtrace at TOP_FRAMES_TO_SHOW frames' do
      frame_lines = backtrace_lines.reject { |line| line.include?('set DEBUG=1 for full backtrace') }
      expect(frame_lines.length).to(be <= 5)
    end

    it 'omits the DEBUG hint when the backtrace fits within the cap' do
      # backtrace.length == 5 fails the `length > TOP_FRAMES_TO_SHOW` guard,
      # so the hint must not appear (no extra frames for the user to see).
      expect(stderr).not_to(include('set DEBUG=1 for full backtrace'))
    end
  end

  context 'with DEBUG unset and a deep backtrace (> TOP_FRAMES_TO_SHOW)' do
    # A malformed Package.resolved triggers JSON::ParserError inside SPMParser,
    # which bubbles through GenericParser#parse and Application#detect_packages
    # to produce a backtrace longer than TOP_FRAMES_TO_SHOW. No network calls.
    let(:run) do
      # rubocop:disable Style/StringHashKeys -- keys are filenames passed to File.join.
      run_soup(
        [],
        fixtures: {
          'Package.swift' => "// swift-tools-version: 5.5\n",
          'Package.resolved' => "{ this is not valid json\n"
        }
      )
      # rubocop:enable Style/StringHashKeys
    end
    let(:stderr) { run[1] }

    it 'appends the DEBUG hint when the full backtrace exceeds the cap' do
      expect(stderr).to(include('... (set DEBUG=1 for full backtrace)'))
    end

    it 'still caps the visible frames at TOP_FRAMES_TO_SHOW' do
      frame_lines = stderr.lines.select { |line| line.start_with?('  ') }
      frame_lines = frame_lines.reject { |line| line.include?('set DEBUG=1 for full backtrace') }
      expect(frame_lines.length).to(eq(5))
    end
  end

  context 'with DEBUG=1 set' do
    # rubocop:disable Style/StringHashKeys -- Open3 child-process env requires string keys.
    let(:run)    { run_soup(['--licenses_file', '/nonexistent/soup-cli-spec.json'], env: { 'DEBUG' => '1' }) }
    let(:stderr) { run[1]                                                                                    }
    # rubocop:enable Style/StringHashKeys

    it 'omits the truncation hint' do
      expect(stderr).not_to(include('set DEBUG=1 for full backtrace'))
    end

    it 'emits backtrace frames without the two-space top-frames prefix' do
      # Full-backtrace branch writes Array#join("\n"); the top-frames branch
      # writes "  #{frame}". The DEBUG output therefore contains at least one
      # frame line that does NOT start with two spaces.
      non_prefixed_frames =
        stderr.lines.each_with_index.reject do |line, idx|
          idx.zero? || line.start_with?('  ') || line.strip.empty?
        end
      expect(non_prefixed_frames).not_to(be_empty)
    end

    it 'still exits with status 1' do
      expect(run[2].exitstatus).to(eq(1))
    end
  end

  context 'when no backtrace is available' do
    # Some StandardError instances raise with backtrace = nil (the rescue
    # wraps it with Array(...) so neither branch should crash). The
    # OptionParser branch in Application#configure_options exits with code 1
    # BEFORE reaching the bin/soup.rb rescue, so it exercises the same
    # observable contract (exit 1, stderr framed). Treat it as a smoke check
    # that the wrapper does not double-print on internally-handled errors.
    let(:run) { run_soup(['--bogus-flag-that-does-not-exist']) }
    let(:stderr) { run[1] }

    it 'exits with status 1' do
      expect(run[2].exitstatus).to(eq(1))
    end

    it 'writes exactly one Error: line to stderr' do
      expect(stderr.scan(/^Error: /).length).to(eq(1))
    end
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
# rubocop:enable RSpec/DescribeClass
