# frozen_string_literal: true

RSpec.describe(SOUP::PIPParser) do
  subject(:parser) { described_class.new }

  let(:requirements_content) do
    <<~TXT
      requests==2.31.0
      # this is a comment
      flask==3.0.0;python_version>="3.8"

      boto3[crt]==1.34.0
    TXT
  end

  let(:requests_response) do
    {
      info: {
        summary: 'HTTP library. For humans.',
        home_page: 'https://requests.readthedocs.io ',
        classifiers: ['License :: OSI Approved :: Apache Software License'],
        license: ''
      }
    }.to_json
  end

  let(:flask_response) do
    {
      info: {
        summary: 'Flask web framework',
        home_page: 'https://flask.palletsprojects.com',
        classifiers: [],
        license: "BSD-3-Clause\nSome additional text"
      }
    }.to_json
  end

  let(:boto3_response) do
    {
      info: {
        summary: 'AWS SDK for Python',
        home_page: 'https://aws.amazon.com/sdk-for-python/',
        classifiers: ['License :: OSI Approved :: Apache Software License'],
        license: 'Apache-2.0'
      }
    }.to_json
  end

  before do
    allow(File).to(receive(:exist?).and_call_original)
    allow(File).to(receive(:exist?).with('requirements.in').and_return(false))
    allow(File).to(receive(:foreach).and_call_original)
    foreach_stub = receive(:foreach).with('requirements.txt')
    requirements_content.lines.each { |line| foreach_stub.and_yield(line) }
    allow(File).to(foreach_stub)
  end

  context 'when parsing all three packages' do
    before do
      stub_request(:get, 'https://pypi.python.org/pypi/requests/json')
        .to_return(status: 200, body: requests_response)
      stub_request(:get, 'https://pypi.python.org/pypi/flask/json')
        .to_return(status: 200, body: flask_response)
      stub_request(:get, 'https://pypi.python.org/pypi/boto3/json')
        .to_return(status: 200, body: boto3_response)
    end

    let(:packages) do
      result = {}
      parser.parse('requirements.txt', result)
      result
    end

    it 'parses requirements line by line, skips comments and empty lines', :aggregate_failures do
      expect(packages).to(have_key('requests'))
      expect(packages).to(have_key('flask'))
      expect(packages).to(have_key('boto3[crt]'))
      expect(packages.size).to(eq(3))
    end

    it 'strips environment markers from line' do
      expect(packages['flask'].version).to(eq('3.0.0'))
    end

    it 'strips extras brackets from package name in URL' do
      packages
      expect(a_request(:get, 'https://pypi.python.org/pypi/boto3/json')).to(have_been_made)
    end

    it 'extracts license from classifiers first' do
      expect(packages['requests'].license).to(eq('Apache Software License'))
    end

    it 'falls back to license field when classifiers are empty' do
      expect(packages['flask'].license).to(eq('BSD-3-Clause'))
    end

    it 'sets language to Python' do
      expect(packages['requests'].language).to(eq('Python'))
    end
  end

  context 'when .in file exists for dependency detection' do
    before do
      allow(File).to(receive(:exist?).with('requirements.in').and_return(true))
      allow(File).to(receive(:read).and_call_original)
      allow(File).to(receive(:read).with('requirements.in').and_return("requests\n"))

      foreach_stub = receive(:foreach).with('requirements.txt')
      "requests==2.31.0\nflask==3.0.0\n".lines.each { |line| foreach_stub.and_yield(line) }
      allow(File).to(foreach_stub)

      stub_request(:get, 'https://pypi.python.org/pypi/requests/json')
        .to_return(status: 200, body: requests_response)
      stub_request(:get, 'https://pypi.python.org/pypi/flask/json')
        .to_return(status: 200, body: flask_response)
    end

    it 'uses .in file for dependency detection if it exists', :aggregate_failures do
      packages = {}
      parser.parse('requirements.txt', packages)
      expect(packages['requests'].dependency).to(be(false))
      expect(packages['flask'].dependency).to(be(true))
    end
  end

  context 'when home_page is nil' do
    let(:nil_homepage_response) do
      {
        info: {
          summary: 'A package',
          home_page: nil,
          classifiers: ['License :: OSI Approved :: MIT License'],
          license: ''
        }
      }.to_json
    end

    before do
      allow(File).to(receive(:foreach).with('requirements.txt').and_yield("simple==1.0.0\n"))
      stub_request(:get, 'https://pypi.python.org/pypi/simple/json')
        .to_return(status: 200, body: nil_homepage_response)
    end

    it 'handles nil home_page' do
      packages = {}
      parser.parse('requirements.txt', packages)
      expect(packages['simple'].website).to(be_nil)
    end
  end

  context 'when a requirement uses a non-`==` constraint' do
    before do
      allow(File).to(
        receive(:foreach).with('requirements.txt')
                         .and_yield("requests>=2.31.0\n")
                         .and_yield("flask~=3.0.0\n")
                         .and_yield("django!=4.0\n")
      )
    end

    it 'skips loose constraints with a stderr warning instead of issuing a doomed 404 request', :aggregate_failures do
      packages = {}
      expect { parser.parse('requirements.txt', packages) }
        .to(output(/only exact `==` version pins are supported/).to_stderr)
      expect(WebMock).not_to(have_requested(:get, /pypi\.python\.org/))
      expect(packages).to(be_empty)
    end
  end

  context 'when license is empty and no classifiers exist' do
    let(:empty_license_response) do
      {
        info: {
          summary: 'A package',
          home_page: '',
          classifiers: [],
          license: nil
        }
      }.to_json
    end

    before do
      allow(File).to(receive(:foreach).with('requirements.txt').and_yield("pkg==1.0.0\n"))
      stub_request(:get, 'https://pypi.python.org/pypi/pkg/json')
        .to_return(status: 200, body: empty_license_response)
    end

    it 'handles empty license and no classifiers' do
      packages = {}
      parser.parse('requirements.txt', packages)
      expect(packages['pkg'].license).to(be_nil)
    end
  end

  # TEST-04: malformed-input coverage. requirements.txt is a plain text format;
  # the parser skips blank/comment lines and raises on lines with loose
  # constraints (covered in the existing "loose constraints" context).
  describe '#parse with malformed input' do
    let(:packages) { {} }

    before do
      allow(File).to(receive(:exist?).and_call_original)
      allow(File).to(receive(:exist?).with('requirements.in').and_return(false))
    end

    context 'with an empty requirements.txt' do
      before do
        allow(File).to(receive(:foreach).with('requirements.txt'))
      end

      it 'parses without raising and adds no packages', :aggregate_failures do
        expect { parser.parse('requirements.txt', packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end

    context 'with a comment-and-blank-line-only requirements.txt' do
      before do
        ["# header comment\n", "\n", "  \n", "# another comment\n"].each do |line|
          allow(File).to(receive(:foreach).with('requirements.txt').and_yield(line))
        end
      end

      it 'parses without raising and adds no packages', :aggregate_failures do
        expect { parser.parse('requirements.txt', packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end

    # TEST-05: race where Dir.glob found the lockfile but it was deleted /
    # unreadable before File.foreach ran.
    context 'when requirements.txt cannot be read' do
      before do
        allow(File).to(
          receive(:foreach)
                    .with('requirements.txt').and_raise(Errno::ENOENT.new('requirements.txt'))
        )
      end

      it 'surfaces Errno::ENOENT' do
        expect { parser.parse('requirements.txt', packages) }
          .to(raise_error(Errno::ENOENT))
      end
    end

    # TEST-12 follow-up: parser exercised against a real requirements.txt
    # via SoupFixtureHelpers. Stubs the .in / foreach defaults from the outer
    # before are bypassed via and_call_original so real File.foreach reads
    # the tmpdir fixture.
    context 'with a real requirements.txt fixture on disk' do
      before do
        allow(File).to(receive(:exist?).and_call_original)
        allow(File).to(receive(:foreach).and_call_original)
        body = {
          info: {
            summary: 'HTTP library',
            home_page: 'https://example.com',
            classifiers: ['License :: OSI Approved :: Apache Software License'],
            license: ''
          }
        }.to_json
        stub_request(:get, 'https://pypi.python.org/pypi/requests/json')
          .to_return(status: 200, body: body)
      end

      it 'reads pinned requirements from disk and skips comments/blanks' do
        lockfile_path = write_fixture('requirements.txt', "# top-level comment\nrequests==2.31.0\n\n")
        parser.parse(lockfile_path, packages)
        expect(packages['requests']).to(have_attributes(language: 'Python', version: '2.31.0'))
      end
    end
  end

  # TEST-303: exercise parallel_each at a meaningful fan-out width so a
  # parser-local concurrency or ordering regression in PIP is caught
  # by the spec suite, not just by NPM's existing scale guard.
  context 'with 100 packages (Parallel.map fan-out)' do
    let(:requirements_content) do
      (1..100).map { |i| "pkg-#{i}==1.0.0\n" }
              .join
    end

    before do
      (1..100).each do |i|
        body = {
          info: {
            summary: "pkg-#{i}",
            home_page: 'https://example.com',
            classifiers: ['License :: OSI Approved :: MIT License'],
            license: ''
          }
        }.to_json
        stub_request(:get, "https://pypi.python.org/pypi/pkg-#{i}/json").to_return(status: 200, body: body)
      end
    end

    it 'parses all 100 requirements without raising and adds them to the hash', :aggregate_failures do
      packages = {}
      parser.parse('requirements.txt', packages)
      expect(packages.size).to(eq(100))
      expect(packages['pkg-1']).to(have_attributes(language: 'Python', version: '1.0.0'))
      expect(packages['pkg-100']).to(have_attributes(language: 'Python', version: '1.0.0'))
    end
  end
end
