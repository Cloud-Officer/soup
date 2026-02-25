# frozen_string_literal: true

RSpec.describe(SOUP::Options) do
  describe '#parse' do
    it 'sets default values' do
      options = described_class.new([]).parse
      expect(options.auto_reply).to(be(false))
      expect(options.cache_file).to(eq('.soup.json'))
      expect(options.ignored_folders).to(eq([]))
      expect(options.licenses_check).to(be(true))
      expect(options.no_prompt).to(be(false))
      expect(options.skip_bundler).to(be(false))
      expect(options.skip_cocoapods).to(be(false))
      expect(options.skip_composer).to(be(false))
      expect(options.skip_gradle).to(be(false))
      expect(options.skip_npm).to(be(false))
      expect(options.skip_pip).to(be(false))
      expect(options.skip_spm).to(be(false))
      expect(options.skip_yarn).to(be(false))
      expect(options.soup_check).to(be(true))
    end

    it 'enables only licenses_check with --licenses' do
      options = described_class.new(['--licenses']).parse
      expect(options.licenses_check).to(be(true))
      expect(options.soup_check).to(be(false))
    end

    it 'enables only soup_check with --soup' do
      options = described_class.new(['--soup']).parse
      expect(options.licenses_check).to(be(false))
      expect(options.soup_check).to(be(true))
    end

    it 'enables both when neither --licenses nor --soup is given' do
      options = described_class.new([]).parse
      expect(options.licenses_check).to(be(true))
      expect(options.soup_check).to(be(true))
    end

    it 'parses --skip_bundler' do
      options = described_class.new(['--skip_bundler']).parse
      expect(options.skip_bundler).to(be(true))
    end

    it 'parses --skip_composer' do
      options = described_class.new(['--skip_composer']).parse
      expect(options.skip_composer).to(be(true))
    end

    it 'parses --skip_gradle' do
      options = described_class.new(['--skip_gradle']).parse
      expect(options.skip_gradle).to(be(true))
    end

    it 'parses --skip_npm' do
      options = described_class.new(['--skip_npm']).parse
      expect(options.skip_npm).to(be(true))
    end

    it 'parses --skip_pip' do
      options = described_class.new(['--skip_pip']).parse
      expect(options.skip_pip).to(be(true))
    end

    it 'parses --skip_spm' do
      options = described_class.new(['--skip_spm']).parse
      expect(options.skip_spm).to(be(true))
    end

    it 'parses --skip_yarn' do
      options = described_class.new(['--skip_yarn']).parse
      expect(options.skip_yarn).to(be(true))
    end

    it 'parses --cache_file with value' do
      options = described_class.new(['--cache_file', 'custom.json']).parse
      expect(options.cache_file).to(eq('custom.json'))
    end

    it 'parses --exceptions_file with value' do
      options = described_class.new(['--exceptions_file', '/tmp/exc.json']).parse
      expect(options.exceptions_file).to(eq('/tmp/exc.json'))
    end

    it 'parses --licenses_file with value' do
      options = described_class.new(['--licenses_file', '/tmp/lic.json']).parse
      expect(options.licenses_file).to(eq('/tmp/lic.json'))
    end

    it 'parses --markdown_file with value' do
      options = described_class.new(['--markdown_file', '/tmp/soup.md']).parse
      expect(options.markdown_file).to(eq('/tmp/soup.md'))
    end

    it 'parses --ignored_folders as comma-separated list' do
      options = described_class.new(['--ignored_folders', 'vendor,node_modules,dist']).parse
      expect(options.ignored_folders).to(eq(%w[vendor node_modules dist]))
    end

    it 'parses --no_prompt' do
      options = described_class.new(['--no_prompt']).parse
      expect(options.no_prompt).to(be(true))
    end

    it 'parses --auto_reply' do
      options = described_class.new(['--auto_reply']).parse
      expect(options.auto_reply).to(be(true))
    end

    it 'parses multiple flags combined' do
      options = described_class.new(['--licenses', '--skip_npm', '--no_prompt', '--cache_file', 'test.json']).parse
      expect(options.licenses_check).to(be(true))
      expect(options.soup_check).to(be(false))
      expect(options.skip_npm).to(be(true))
      expect(options.no_prompt).to(be(true))
      expect(options.cache_file).to(eq('test.json'))
    end

    it 'raises OptionParser::InvalidOption for unknown flags' do
      expect { described_class.new(['--unknown_flag']).parse }
        .to(raise_error(OptionParser::InvalidOption))
    end
  end
end
