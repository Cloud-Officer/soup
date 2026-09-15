# frozen_string_literal: true

RSpec.describe(SOUP::GHAParser) do
  subject(:parser) { described_class.new }

  let(:workflow) do
    <<~YAML
      ---
      name: Build
      'on':
        schedule:
          - cron: '0 0 * * 1'
      jobs:
        build:
          runs-on: ubuntu-latest
          steps:
            # - uses: commented/out@v1
            - uses: actions/checkout@v7
            - uses: ./local-action
            - uses: docker://alpine:3.20
            - uses: github/codeql-action/init@v3
            - run: 'echo "uses: not/a-step@v1"'
        reusable:
          uses: octo-org/shared/.github/workflows/ci.yml@main
    YAML
  end

  let(:composite_action) do
    <<~YAML
      runs:
        using: composite
        steps:
          - uses: actions/checkout@v6
          - uses: Actions/Checkout@v7
    YAML
  end

  let(:packages) { {} }

  def repository_body(repository, license: 'MIT')
    {
      name: repository.split('/').last,
      private: false,
      license: license && { spdx_id: "#{license} " },
      description: "The #{repository} action. More details here.",
      html_url: "https://github.com/#{repository} "
    }.to_json
  end

  def fixture_files
    [write_fixture('.github/workflows/build.yml', workflow), write_fixture('lint/action.yml', composite_action)]
  end

  def parse_fixtures
    parser.parse(fixture_files, packages)
    packages
  end

  before do
    allow(ENV).to(receive(:fetch).and_call_original)
    allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', '').and_return(''))
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/[^/]+/[^/]+\z})
      .to_return { |request| { status: 200, body: repository_body(request.uri.path.delete_prefix('/repos/')) } }
  end

  it 'records one GHA package per referenced repository, ignoring local, docker, comment and script references' do
    expect(parse_fixtures.keys).to(contain_exactly('GHA:actions/checkout', 'GHA:github/codeql-action', 'GHA:octo-org/shared'))
  end

  it 'folds sub-path actions and reusable workflows into their repository', :aggregate_failures do
    expect(parse_fixtures['GHA:github/codeql-action'].version).to(eq('v3'))
    expect(packages['GHA:octo-org/shared'].version).to(eq('main'))
  end

  it 'merges every ref of a repository across files and spellings under its lowercase name', :aggregate_failures do
    expect(parse_fixtures['GHA:actions/checkout'].package).to(eq('actions/checkout'))
    expect(packages['GHA:actions/checkout'].version).to(eq('v6, v7'))
  end

  it 'takes license, description and website from the GitHub API', :aggregate_failures do
    package = parse_fixtures['GHA:actions/checkout']
    expect(package).to(have_attributes(language: 'GHA', license: 'MIT', description: 'The actions/checkout action', website: 'https://github.com/actions/checkout'))
    expect(package.dependency).to(be(false))
  end

  it 'records the first file that references the repository' do
    expect(parse_fixtures['GHA:actions/checkout'].file).to(end_with('.github/workflows/build.yml'))
  end

  context 'when the repository has no license' do
    before do
      stub_request(:get, 'https://api.github.com/repos/octo-org/shared')
        .to_return(status: 200, body: repository_body('octo-org/shared', license: nil))
    end

    it 'records the package without a license' do
      expect(parse_fixtures['GHA:octo-org/shared'].license).to(be_nil)
    end
  end

  context 'when the repository lookup returns 404' do
    before { stub_request(:get, 'https://api.github.com/repos/octo-org/shared').to_return(status: [404, 'Not Found'], body: '{"message":"Not Found"}') }

    it 'records the package as unresolved with its refs', :aggregate_failures do
      expect(parse_fixtures['GHA:octo-org/shared']).to(have_attributes(version: 'main', license: 'NOASSERTION', unresolved: true))
    end
  end

  context 'when the GitHub API times out' do
    before { stub_request(:get, 'https://api.github.com/repos/octo-org/shared').to_timeout }

    it 'records the package as unresolved instead of aborting the scan' do
      expect(parse_fixtures['GHA:octo-org/shared'].unresolved).to(be(true))
    end
  end

  context 'when rate limited' do
    before do
      stub_request(:get, 'https://api.github.com/repos/octo-org/shared')
        .to_return(status: [403, 'Forbidden'], body: { message: 'API rate limit exceeded for 1.2.3.4' }.to_json)
    end

    it 'raises' do
      expect { parse_fixtures }
        .to(raise_error(SOUP::RateLimitError, /rate limit/))
    end
  end

  context 'with bad credentials' do
    before { stub_request(:get, 'https://api.github.com/repos/octo-org/shared').to_return(status: [401, 'Unauthorized'], body: { message: 'Bad credentials' }.to_json) }

    it 'raises' do
      expect { parse_fixtures }
        .to(raise_error(SOUP::AuthenticationError, /Bad credentials/))
    end
  end

  context 'when GITHUB_TOKEN is set' do
    before { allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', '').and_return('ghp_test123')) }

    it 'sends the token to the GitHub API' do
      parse_fixtures
      expect(a_request(:get, 'https://api.github.com/repos/actions/checkout').with(headers: { Authorization: 'token ghp_test123' }))
        .to(have_been_made.once)
    end
  end

  context 'with an unrecognized uses reference' do
    let(:workflow) { "jobs:\n  build:\n    steps:\n      - uses: not-a-reference\n" }

    it 'warns and skips it', :aggregate_failures do
      expect { parse_fixtures }
        .to(output(/Skipping unrecognized uses reference not-a-reference/).to_stderr)
      expect(packages.keys).to(eq(['GHA:actions/checkout']))
    end
  end

  context 'with an empty file' do
    let(:workflow) { '' }

    it 'contributes no references' do
      expect(parse_fixtures.keys).to(eq(['GHA:actions/checkout']))
    end
  end

  context 'with invalid YAML' do
    let(:workflow) { "jobs: [\n" }

    it 'raises InvalidLockfileError naming the file' do
      expect { parse_fixtures }
        .to(raise_error(SOUP::InvalidLockfileError, %r{Invalid YAML in .*\.github/workflows/build\.yml}))
    end
  end
end
