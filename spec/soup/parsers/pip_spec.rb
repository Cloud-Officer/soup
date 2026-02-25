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
    allow(File).to(receive(:open).and_call_original)

    file_io = StringIO.new(requirements_content)
    allow(File).to(receive(:open).with('requirements.txt', 'r').and_return(file_io))
  end

  it 'parses requirements line by line, skips comments and empty lines' do
    stub_request(:get, 'https://pypi.python.org/pypi/requests/json')
      .to_return(status: 200, body: requests_response)
    stub_request(:get, 'https://pypi.python.org/pypi/flask/json')
      .to_return(status: 200, body: flask_response)
    stub_request(:get, 'https://pypi.python.org/pypi/boto3/json')
      .to_return(status: 200, body: boto3_response)

    packages = {}
    parser.parse('requirements.txt', packages)
    expect(packages).to(have_key('requests'))
    expect(packages).to(have_key('flask'))
    expect(packages).to(have_key('boto3[crt]'))
    expect(packages.size).to(eq(3))
  end

  it 'strips environment markers from line' do
    stub_request(:get, 'https://pypi.python.org/pypi/requests/json')
      .to_return(status: 200, body: requests_response)
    stub_request(:get, 'https://pypi.python.org/pypi/flask/json')
      .to_return(status: 200, body: flask_response)
    stub_request(:get, 'https://pypi.python.org/pypi/boto3/json')
      .to_return(status: 200, body: boto3_response)

    packages = {}
    parser.parse('requirements.txt', packages)
    expect(packages['flask'].version).to(eq('3.0.0'))
  end

  it 'strips extras brackets from package name in URL' do
    stub_request(:get, 'https://pypi.python.org/pypi/requests/json')
      .to_return(status: 200, body: requests_response)
    stub_request(:get, 'https://pypi.python.org/pypi/flask/json')
      .to_return(status: 200, body: flask_response)
    stub_request(:get, 'https://pypi.python.org/pypi/boto3/json')
      .to_return(status: 200, body: boto3_response)

    packages = {}
    parser.parse('requirements.txt', packages)
    expect(a_request(:get, 'https://pypi.python.org/pypi/boto3/json')).to(have_been_made)
  end

  it 'extracts license from classifiers first' do
    stub_request(:get, 'https://pypi.python.org/pypi/requests/json')
      .to_return(status: 200, body: requests_response)
    stub_request(:get, 'https://pypi.python.org/pypi/flask/json')
      .to_return(status: 200, body: flask_response)
    stub_request(:get, 'https://pypi.python.org/pypi/boto3/json')
      .to_return(status: 200, body: boto3_response)

    packages = {}
    parser.parse('requirements.txt', packages)
    expect(packages['requests'].license).to(eq('Apache Software License'))
  end

  it 'falls back to license field when classifiers are empty' do
    stub_request(:get, 'https://pypi.python.org/pypi/requests/json')
      .to_return(status: 200, body: requests_response)
    stub_request(:get, 'https://pypi.python.org/pypi/flask/json')
      .to_return(status: 200, body: flask_response)
    stub_request(:get, 'https://pypi.python.org/pypi/boto3/json')
      .to_return(status: 200, body: boto3_response)

    packages = {}
    parser.parse('requirements.txt', packages)
    expect(packages['flask'].license).to(eq('BSD-3-Clause'))
  end

  it 'uses .in file for dependency detection if it exists' do
    allow(File).to(receive(:exist?).with('requirements.in').and_return(true))
    allow(File).to(receive(:read).and_call_original)
    allow(File).to(receive(:read).with('requirements.in').and_return("requests\n"))

    file_io = StringIO.new("requests==2.31.0\nflask==3.0.0\n")
    allow(File).to(receive(:open).with('requirements.txt', 'r').and_return(file_io))

    stub_request(:get, 'https://pypi.python.org/pypi/requests/json')
      .to_return(status: 200, body: requests_response)
    stub_request(:get, 'https://pypi.python.org/pypi/flask/json')
      .to_return(status: 200, body: flask_response)

    packages = {}
    parser.parse('requirements.txt', packages)
    expect(packages['requests'].dependency).to(be(false))
    expect(packages['flask'].dependency).to(be(true))
  end

  it 'handles nil home_page' do
    nil_homepage_response = {
      info: {
        summary: 'A package',
        home_page: nil,
        classifiers: ['License :: OSI Approved :: MIT License'],
        license: ''
      }
    }.to_json

    file_io = StringIO.new("simple==1.0.0\n")
    allow(File).to(receive(:open).with('requirements.txt', 'r').and_return(file_io))
    stub_request(:get, 'https://pypi.python.org/pypi/simple/json')
      .to_return(status: 200, body: nil_homepage_response)

    packages = {}
    parser.parse('requirements.txt', packages)
    expect(packages['simple'].website).to(be_nil)
  end

  it 'handles empty license and no classifiers' do
    empty_license_response = {
      info: {
        summary: 'A package',
        home_page: '',
        classifiers: [],
        license: nil
      }
    }.to_json

    file_io = StringIO.new("pkg==1.0.0\n")
    allow(File).to(receive(:open).with('requirements.txt', 'r').and_return(file_io))
    stub_request(:get, 'https://pypi.python.org/pypi/pkg/json')
      .to_return(status: 200, body: empty_license_response)

    packages = {}
    parser.parse('requirements.txt', packages)
    expect(packages['pkg'].license).to(be_nil)
  end

  it 'sets language to Python' do
    stub_request(:get, 'https://pypi.python.org/pypi/requests/json')
      .to_return(status: 200, body: requests_response)
    stub_request(:get, 'https://pypi.python.org/pypi/flask/json')
      .to_return(status: 200, body: flask_response)
    stub_request(:get, 'https://pypi.python.org/pypi/boto3/json')
      .to_return(status: 200, body: boto3_response)

    packages = {}
    parser.parse('requirements.txt', packages)
    expect(packages['requests'].language).to(eq('Python'))
  end
end
