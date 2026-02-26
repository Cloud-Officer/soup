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

  before do
    allow(File).to(receive(:read).and_call_original)
    allow(File).to(receive(:read).with('Package.resolved').and_return(resolved_file))
    allow(File).to(receive(:exist?).and_call_original)
    allow(File).to(receive(:exist?).with('Package.swift').and_return(true))
    allow(File).to(receive(:read).with('Package.swift').and_return(main_file_content))
    allow(ENV).to(receive(:fetch).and_call_original)
    allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', '').and_return(''))
  end

  context 'when parsing Package.resolved with GitHub API success' do
    before do
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    let(:packages) do
      result = {}
      parser.parse('Package.resolved', result)
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
      parser.parse('Package.resolved', packages)
      expect(packages).to(have_key('Alamofire'))
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
      parser.parse('Package.resolved', packages)
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
      parser.parse('Package.resolved', packages)
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
      parser.parse('Package.resolved', packages)
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
      parser.parse('Package.resolved', packages)
      expect(packages).to(be_empty)
    end
  end

  context 'when Package.swift does not exist but Tuist Dependencies.swift does' do
    before do
      allow(File).to(receive(:read).with('Tuist/Package.resolved').and_return(resolved_file))
      allow(File).to(receive(:exist?).with('Tuist/Package.swift').and_return(false))
      allow(File).to(receive(:exist?).with('Tuist/Dependencies.swift').and_return(true))
      allow(File).to(receive(:read).with('Tuist/Dependencies.swift').and_return(main_file_content))
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    it 'uses Tuist Dependencies.swift as main file' do
      packages = {}
      parser.parse('Tuist/Package.resolved', packages)
      expect(packages).to(have_key('Alamofire'))
    end
  end

  context 'when only xcodeproj exists' do
    before do
      allow(File).to(receive(:exist?).with('Package.swift').and_return(false))
      allow(File).to(receive(:exist?).with('Package.resolvedTuist/Dependencies.swift').and_return(false))
      allow(File).to(receive(:exist?).with('Package.xcodeproj/project.pbxproj').and_return(true))
      allow(File).to(receive(:read).with('Package.xcodeproj/project.pbxproj').and_return(main_file_content))
      stub_request(:get, 'https://api.github.com/repos/Alamofire/Alamofire')
        .to_return(status: 200, body: github_response)
    end

    it 'uses xcodeproj as main file' do
      packages = {}
      parser.parse('Package.resolved', packages)
      expect(packages).to(have_key('Alamofire'))
    end
  end

  context 'when no main file exists' do
    before do
      allow(File).to(receive(:exist?).with('Package.swift').and_return(false))
      allow(File).to(receive(:exist?).with('Package.resolvedTuist/Dependencies.swift').and_return(false))
      allow(File).to(receive(:exist?).with('Package.xcodeproj/project.pbxproj').and_return(false))
    end

    it 'raises an error' do
      packages = {}
      expect { parser.parse('Package.resolved', packages) }
        .to(raise_error('No main file found!'))
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
      parser.parse('Package.resolved', packages)
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
      expect { parser.parse('Package.resolved', packages) }
        .to(raise_error(/rate limit/))
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
      expect { parser.parse('Package.resolved', packages) }
        .to(raise_error(/Bad credentials/))
    end
  end
end
