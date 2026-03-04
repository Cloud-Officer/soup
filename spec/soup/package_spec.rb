# frozen_string_literal: true

RSpec.describe(SOUP::Package) do
  describe '.sanitize_description' do
    it 'returns nil for nil input' do
      expect(described_class.sanitize_description(nil)).to(be_nil)
    end

    it 'returns nil for empty string input' do
      expect(described_class.sanitize_description('')).to(be_nil)
    end

    it 'returns nil for empty string with first_sentence' do
      expect(described_class.sanitize_description('', first_sentence: true)).to(be_nil)
    end

    it 'returns nil when first_sentence splits to empty result' do
      expect(described_class.sanitize_description("\n", first_sentence: true)).to(be_nil)
    end

    it 'extracts first sentence when first_sentence is true' do
      text = 'First sentence. Second sentence'
      expect(described_class.sanitize_description(text, first_sentence: true)).to(eq('First sentence'))
    end

    it 'extracts first line when first_sentence is true' do
      text = "First line\nSecond line"
      expect(described_class.sanitize_description(text, first_sentence: true)).to(eq('First line'))
    end

    it 'wraps URLs in angle brackets' do
      text = 'Visit https://example.com for details'
      expect(described_class.sanitize_description(text)).to(eq('Visit <https://example.com> for details'))
    end

    it 'wraps http URLs in angle brackets' do
      text = 'Visit http://example.com for details'
      expect(described_class.sanitize_description(text)).to(eq('Visit <http://example.com> for details'))
    end

    it 'strips markdown characters when strip_markdown is true' do
      text = '_bold_ [link](url) !image |table|'
      expect(described_class.sanitize_description(text, strip_markdown: true)).to(eq('bold link(url) image table'))
    end

    it 'applies first_sentence and strip_markdown together' do
      text = '_First_ sentence. Second sentence'
      result = described_class.sanitize_description(text, first_sentence: true, strip_markdown: true)
      expect(result).to(eq('First sentence'))
    end
  end

  describe '#initialize' do
    it 'raises on nil package' do
      expect { described_class.new(nil) }
        .to(raise_error('No package specified!'))
    end

    context 'with default values' do
      let(:package) { described_class.new('test-package') }

      it 'sets package name and empty string defaults', :aggregate_failures do
        expect(package.package).to(eq('test-package'))
        expect(package.file).to(eq(''))
        expect(package.language).to(eq(''))
        expect(package.version).to(eq(''))
        expect(package.license).to(eq(''))
      end

      it 'sets remaining empty string defaults', :aggregate_failures do
        expect(package.description).to(eq(''))
        expect(package.website).to(eq(''))
        expect(package.last_verified_at).to(eq(''))
        expect(package.risk_level).to(eq(''))
        expect(package.requirements).to(eq(''))
      end

      it 'sets verification_reasoning and dependency defaults', :aggregate_failures do
        expect(package.verification_reasoning).to(eq(''))
        expect(package.dependency).to(be(false))
      end
    end
  end

  describe '#as_json' do
    let(:package) { described_class.new('test-package') }

    context 'when file and dependency are set' do
      before do
        package.file = 'Gemfile.lock'
        package.dependency = true
      end

      it 'excludes file and dependency fields', :aggregate_failures do
        json = package.as_json
        expect(json).not_to(have_key(:file))
        expect(json).not_to(have_key(:dependency))
      end
    end

    context 'when all fields are populated' do
      before do
        package.language = 'Ruby'
        package.version = '1.0.0'
        package.license = 'MIT'
        package.description = 'A test package'
        package.website = 'https://example.com'
      end

      it 'includes all other fields', :aggregate_failures do
        expect(package.as_json[:language]).to(eq('Ruby'))
        expect(package.as_json[:package]).to(eq('test-package'))
        expect(package.as_json[:version]).to(eq('1.0.0'))
        expect(package.as_json[:license]).to(eq('MIT'))
        expect(package.as_json[:description]).to(eq('A test package'))
      end

      it 'includes the website field' do
        json = package.as_json
        expect(json[:website]).to(eq('https://example.com'))
      end
    end
  end

  describe '#to_json' do
    let(:package) do
      p = described_class.new('test-package')
      p.language = 'Ruby'
      p
    end

    it 'returns valid JSON string', :aggregate_failures do
      parsed = JSON.parse(package.to_json)
      expect(parsed['package']).to(eq('test-package'))
      expect(parsed['language']).to(eq('Ruby'))
    end
  end
end
