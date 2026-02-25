# frozen_string_literal: true

RSpec.describe(SOUP::Package) do
  describe '.sanitize_description' do
    it 'returns nil for nil input' do
      expect(described_class.sanitize_description(nil)).to(be_nil)
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

    it 'sets default values' do
      package = described_class.new('test-package')
      expect(package.package).to(eq('test-package'))
      expect(package.file).to(eq(''))
      expect(package.language).to(eq(''))
      expect(package.version).to(eq(''))
      expect(package.license).to(eq(''))
      expect(package.description).to(eq(''))
      expect(package.website).to(eq(''))
      expect(package.last_verified_at).to(eq(''))
      expect(package.risk_level).to(eq(''))
      expect(package.requirements).to(eq(''))
      expect(package.verification_reasoning).to(eq(''))
      expect(package.dependency).to(be(false))
    end
  end

  describe '#as_json' do
    it 'excludes file and dependency fields' do
      package = described_class.new('test-package')
      package.file = 'Gemfile.lock'
      package.dependency = true
      json = package.as_json

      expect(json).not_to(have_key(:file))
      expect(json).not_to(have_key(:dependency))
    end

    it 'includes all other fields' do
      package = described_class.new('test-package')
      package.language = 'Ruby'
      package.version = '1.0.0'
      package.license = 'MIT'
      package.description = 'A test package'
      package.website = 'https://example.com'
      json = package.as_json

      expect(json[:language]).to(eq('Ruby'))
      expect(json[:package]).to(eq('test-package'))
      expect(json[:version]).to(eq('1.0.0'))
      expect(json[:license]).to(eq('MIT'))
      expect(json[:description]).to(eq('A test package'))
      expect(json[:website]).to(eq('https://example.com'))
    end
  end

  describe '#to_json' do
    it 'returns valid JSON string' do
      package = described_class.new('test-package')
      package.language = 'Ruby'
      json_string = package.to_json

      parsed = JSON.parse(json_string)
      expect(parsed['package']).to(eq('test-package'))
      expect(parsed['language']).to(eq('Ruby'))
    end
  end
end
