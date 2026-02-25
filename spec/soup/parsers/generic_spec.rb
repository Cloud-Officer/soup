# frozen_string_literal: true

RSpec.describe(SOUP::GenericParser) do
  subject(:generic_parser) { described_class.new }

  let(:mock_parser) { instance_double('Parser') } # rubocop:disable RSpec/VerifiedDoubleReference

  describe '#parse' do
    it 'raises on nil parser' do
      expect { generic_parser.parse(nil, 'file', {}) }
        .to(raise_error('No parser specified!'))
    end

    it 'raises on nil file' do
      expect { generic_parser.parse(mock_parser, nil, {}) }
        .to(raise_error('No file specified!'))
    end

    it 'raises on non-String file' do
      expect { generic_parser.parse(mock_parser, 123, {}) }
        .to(raise_error(TypeError, 'file expects a string'))
    end

    it 'raises on nil packages' do
      expect { generic_parser.parse(mock_parser, 'file', nil) }
        .to(raise_error('No packages specified!'))
    end

    it 'raises on non-Hash packages' do
      expect { generic_parser.parse(mock_parser, 'file', []) }
        .to(raise_error(TypeError, 'packages expects a hash'))
    end

    it 'delegates to parser with valid arguments' do
      packages = {}
      allow(mock_parser).to(receive(:parse).with('test_file', packages))
      generic_parser.parse(mock_parser, 'test_file', packages)
      expect(mock_parser).to(have_received(:parse).with('test_file', packages))
    end
  end
end
