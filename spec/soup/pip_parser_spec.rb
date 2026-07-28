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

  def requirements_path
    write_fixture('requirements.in', requirements_in_content) unless requirements_in_content.nil?
    write_fixture('requirements.txt', requirements_content)
  end

  # TEST-12: requirements.txt (and the sibling requirements.in, when the case
  # needs one) are written to a per-example tmpdir. Whether the .in file exists
  # is expressed by writing it or not, so the parser's real File.exist? check
  # runs instead of a stubbed one.
  def requirements_in_content = nil

  context 'when parsing all three packages' do
    before do
      stub_request(:get, 'https://pypi.org/pypi/requests/json')
        .to_return(status: 200, body: requests_response)
      stub_request(:get, 'https://pypi.org/pypi/flask/json')
        .to_return(status: 200, body: flask_response)
      stub_request(:get, 'https://pypi.org/pypi/boto3/json')
        .to_return(status: 200, body: boto3_response)
    end

    let(:packages) do
      result = {}
      parser.parse(requirements_path, result)
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
      expect(a_request(:get, 'https://pypi.org/pypi/boto3/json')).to(have_been_made)
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
    let(:requirements_in_content) { "requests\n"                       }
    let(:requirements_content)    { "requests==2.31.0\nflask==3.0.0\n" }

    before do
      stub_request(:get, 'https://pypi.org/pypi/requests/json')
        .to_return(status: 200, body: requests_response)
      stub_request(:get, 'https://pypi.org/pypi/flask/json')
        .to_return(status: 200, body: flask_response)
    end

    it 'uses .in file for dependency detection if it exists', :aggregate_failures do
      packages = {}
      parser.parse(requirements_path, packages)
      expect(packages['requests'].dependency).to(be(false))
      expect(packages['flask'].dependency).to(be(true))
    end
  end

  # CONS-001: a 404 usually means the package is private or simply absent from
  # PyPI. It is still a dependency, so it is recorded rather than dropped.
  context 'when the registry returns a non-200' do
    let(:requirements_content) { "requests==2.31.0\n" }
    let(:packages) { {} }

    before { stub_request(:get, 'https://pypi.org/pypi/requests/json').to_return(status: 404, body: 'Not Found') }

    it 'warns and records the package as unresolved', :aggregate_failures do
      expect { parser.parse(requirements_path, packages) }
        .to(output(/HTTP 404.*requests==2\.31\.0/m).to_stderr)
      expect(packages['requests']).to(have_attributes(version: '2.31.0', language: 'Python', license: 'NOASSERTION'))
      expect(packages['requests'].unresolved).to(be(true))
    end
  end

  # CONS-002: HttpClient re-raises Net::ReadTimeout once its retries are
  # exhausted. Before the fix that escaped fetch_package, propagated through
  # Parallel.map, and killed the whole scan with an untyped backtrace. It must
  # warn and omit just this package instead.
  context 'when the registry times out' do
    let(:requirements_content) { "requests==2.31.0\n" }
    let(:packages) { {} }

    before { stub_request(:get, 'https://pypi.org/pypi/requests/json').to_timeout }

    it 'records the package as unresolved instead of aborting the scan', :aggregate_failures do
      expect { parser.parse(requirements_path, packages) }
        .not_to(raise_error)
      expect(packages['requests']).to(have_attributes(version: '2.31.0', language: 'Python', license: 'NOASSERTION'))
      expect(packages['requests'].unresolved).to(be(true))
    end

    it 'names the package as name==version in the skip warning' do
      expect { parser.parse(requirements_path, packages) }
        .to(output(/Skipping requests==2\.31\.0: network timeout after retries/).to_stderr)
    end
  end

  # CONS-003 regression: the sibling .in path used to be derived with an
  # unanchored `file.gsub('.txt', '.in')`, which rewrote every ".txt" in the
  # whole path -- so /builds/my.txt.d/requirements.txt looked for
  # /builds/my.in.d/requirements.in. That file never exists, so
  # read_direct_dependencies silently returned [] and every Python package was
  # misclassified as transitive with no warning. A real directory named
  # "my.txt.d" is written here so the path genuinely contains the substring.
  context 'when the lockfile lives in a directory whose name contains ".txt"' do
    let(:requirements_in_content) { "requests\n"                       }
    let(:requirements_content)    { "requests==2.31.0\nflask==3.0.0\n" }

    def requirements_path
      write_fixture('my.txt.d/requirements.in', requirements_in_content)
      write_fixture('my.txt.d/requirements.txt', requirements_content)
    end

    before do
      stub_request(:get, 'https://pypi.org/pypi/requests/json')
        .to_return(status: 200, body: requests_response)
      stub_request(:get, 'https://pypi.org/pypi/flask/json')
        .to_return(status: 200, body: flask_response)
    end

    it 'still resolves the sibling requirements.in without corrupting the path', :aggregate_failures do
      packages = {}
      parser.parse(requirements_path, packages)
      expect(packages['requests'].dependency).to(be(false))
      expect(packages['flask'].dependency).to(be(true))
    end
  end

  # BUG-003 regression: a transitive package whose name is a substring of a
  # declared requirement (requests within requests-oauthlib) must NOT be flagged
  # direct. The old String#include? scan of requirements.in mis-classified it.
  context 'when a transitive package name is a substring of a declared requirement' do
    let(:requirements_in_content) { "requests-oauthlib\n" }
    let(:requirements_content) { "requests==2.31.0\n" }

    before do
      stub_request(:get, 'https://pypi.org/pypi/requests/json')
        .to_return(status: 200, body: requests_response)
    end

    it 'classifies the substring package as transitive' do
      packages = {}
      parser.parse(requirements_path, packages)
      expect(packages['requests'].dependency).to(be(true))
    end
  end

  # The .in / lockfile names are compared with PEP 503 normalization, so a
  # declared "Flask_Login" still matches the resolved "flask-login".
  context 'when the declared name differs only by case and separators' do
    let(:requirements_in_content) { "Flask_Login\n" }
    let(:requirements_content) { "flask-login==0.6.3\n" }

    before do
      stub_request(:get, 'https://pypi.org/pypi/flask-login/json')
        .to_return(status: 200, body: flask_response)
    end

    it 'classifies the normalized match as a direct dependency' do
      packages = {}
      parser.parse(requirements_path, packages)
      expect(packages['flask-login'].dependency).to(be(false))
    end
  end

  context 'when home_page is nil' do
    let(:requirements_content) { "simple==1.0.0\n" }

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
      stub_request(:get, 'https://pypi.org/pypi/simple/json')
        .to_return(status: 200, body: nil_homepage_response)
    end

    it 'handles nil home_page' do
      packages = {}
      parser.parse(requirements_path, packages)
      expect(packages['simple'].website).to(be_nil)
    end
  end

  # QUAL-003 regression: pypi.python.org was retired in April 2018 and only
  # answers through a permanent 301 to pypi.org, costing an extra round-trip per
  # package against the HTTP timeout. Both domains are stubbed here so the
  # expectation fails on a revert instead of merely erroring on an unregistered
  # request.
  context 'when resolving the PyPI registry host' do
    let(:requirements_content) { "requests==2.31.0\n" }

    before do
      stub_request(:get, 'https://pypi.org/pypi/requests/json')
        .to_return(status: 200, body: requests_response)
      stub_request(:get, 'https://pypi.python.org/pypi/requests/json')
        .to_return(status: 200, body: requests_response)
    end

    it 'queries pypi.org and never the retired pypi.python.org domain', :aggregate_failures do
      packages = {}
      parser.parse(requirements_path, packages)
      expect(a_request(:get, 'https://pypi.org/pypi/requests/json')).to(have_been_made)
      expect(a_request(:get, 'https://pypi.python.org/pypi/requests/json')).not_to(have_been_made)
    end
  end

  context 'when a requirement uses a non-`==` constraint' do
    let(:requirements_content) { "requests>=2.31.0\nflask~=3.0.0\ndjango!=4.0\n" }

    it 'skips loose constraints with a stderr warning instead of issuing a doomed 404 request', :aggregate_failures do
      packages = {}
      expect { parser.parse(requirements_path, packages) }
        .to(output(/only exact `==` version pins are supported/).to_stderr)
      expect(WebMock).not_to(have_requested(:get, /pypi\.org/))
      expect(packages).to(be_empty)
    end
  end

  # BUG-001 regression: a pinned package carrying a trailing inline comment
  # (PEP 508 / `pip-compile --annotation-style=line`) must be parsed, not
  # silently dropped. Before the fix, `next if line.include?('#')` skipped the
  # whole line; full-line comments must still be skipped via the blank guard.
  context 'when a requirement line has a trailing inline comment' do
    let(:requirements_content) do
      "# full-line comment\nrequests==2.31.0  # security pin\nflask==3.0.0  # pinned for CVE\n"
    end

    before do
      stub_request(:get, 'https://pypi.org/pypi/requests/json')
        .to_return(status: 200, body: requests_response)
      stub_request(:get, 'https://pypi.org/pypi/flask/json')
        .to_return(status: 200, body: flask_response)
    end

    it 'strips the inline comment and parses the package', :aggregate_failures do
      packages = {}
      parser.parse(requirements_path, packages)
      expect(packages['requests'].version).to(eq('2.31.0'))
      expect(packages['flask'].version).to(eq('3.0.0'))
      expect(packages.size).to(eq(2))
    end
  end

  context 'when license is empty and no classifiers exist' do
    let(:requirements_content) { "pkg==1.0.0\n" }

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
      stub_request(:get, 'https://pypi.org/pypi/pkg/json')
        .to_return(status: 200, body: empty_license_response)
    end

    it 'handles empty license and no classifiers' do
      packages = {}
      parser.parse(requirements_path, packages)
      expect(packages['pkg'].license).to(be_nil)
    end
  end

  # TEST-04: malformed-input coverage. requirements.txt is a plain text format;
  # the parser skips blank/comment lines and raises on lines with loose
  # constraints (covered in the existing "loose constraints" context).
  describe '#parse with malformed input' do
    let(:packages) { {} }

    context 'with an empty requirements.txt' do
      let(:requirements_content) { '' }

      it 'parses without raising and adds no packages', :aggregate_failures do
        expect { parser.parse(requirements_path, packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end

    context 'with a comment-and-blank-line-only requirements.txt' do
      let(:requirements_content) { "# header comment\n\n  \n# another comment\n" }

      it 'parses without raising and adds no packages', :aggregate_failures do
        expect { parser.parse(requirements_path, packages) }
          .not_to(raise_error)
        expect(packages).to(be_empty)
      end
    end

    # TEST-05: race where Dir.glob found the lockfile but it was deleted /
    # unreadable before File.foreach ran.
    context 'when requirements.txt cannot be read' do
      # A path inside the fixture dir that was never written, so the real
      # File.foreach raises ENOENT instead of a stub simulating it.
      def requirements_path = File.join(fixture_dir, 'gone', 'requirements.txt')

      it 'surfaces Errno::ENOENT' do
        expect { parser.parse(requirements_path, packages) }
          .to(raise_error(Errno::ENOENT))
      end
    end

    # TEST-12: a requirements.txt mixing pins, comments and blank lines.
    context 'with pins mixed among comments and blank lines' do
      before do
        body = {
          info: {
            summary: 'HTTP library',
            home_page: 'https://example.com',
            classifiers: ['License :: OSI Approved :: Apache Software License'],
            license: ''
          }
        }.to_json
        stub_request(:get, 'https://pypi.org/pypi/requests/json')
          .to_return(status: 200, body: body)
      end

      let(:requirements_content) { "# top-level comment\nrequests==2.31.0\n\n" }

      it 'reads pinned requirements from disk and skips comments/blanks' do
        parser.parse(requirements_path, packages)
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
        stub_request(:get, "https://pypi.org/pypi/pkg-#{i}/json").to_return(status: 200, body: body)
      end
    end

    it 'parses all 100 requirements without raising and adds them to the hash', :aggregate_failures do
      packages = {}
      parser.parse(requirements_path, packages)
      expect(packages.size).to(eq(100))
      expect(packages['pkg-1']).to(have_attributes(language: 'Python', version: '1.0.0'))
      expect(packages['pkg-100']).to(have_attributes(language: 'Python', version: '1.0.0'))
    end
  end
end
