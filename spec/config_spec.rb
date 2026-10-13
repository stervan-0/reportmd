# frozen_string_literal: true

require 'tmpdir'
require 'json'
require_relative '../lib/reportmd/config'

RSpec.describe Reportmd::Config do
  def write_json(dir, name, data)
    path = File.join(dir, name)
    File.write(path, data.is_a?(String) ? data : JSON.generate(data))
    path
  end

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  describe 'デフォルト設定' do
    it '設定ファイルがなければ、内蔵のデフォルト値を使う' do
      config = described_class.load
      expect(config.dig('document', 'paper')).to eq('a4')
      expect(config.dig('text', 'font_size')).to eq('10.5pt')
      expect(config.source).to be_nil
      expect(config.warnings).to eq([])
    end

    it '表の既定は三線表（上下 0.8pt、見出しの下が太い 1.2pt、縦線なし）' do
      rules = described_class.load.dig('table', 'rules')
      expect(rules).to eq('top' => '0.8pt', 'header' => '1.2pt', 'bottom' => '0.8pt',
                          'rows' => false, 'vertical' => false, 'sides' => false)
    end
  end

  describe '表の設定' do
    it '書いた罫線だけを変え、ほかの罫線は既定のまま' do
      path = write_json(@dir, 's.json', { table: { rules: { vertical: '0.4pt', top: false } } })
      rules = described_class.load(explicit_path: path).dig('table', 'rules')
      expect(rules).to include('vertical' => '0.4pt', 'top' => false, 'bottom' => '0.8pt')
    end

    it '文字サイズは null（本文と同じ）と pt 単位の両方を受け付ける' do
      %w[9pt].push(nil).each do |size|
        path = write_json(@dir, 's.json', { table: { font_size: size } })
        expect(described_class.load(explicit_path: path).dig('table', 'font_size')).to eq(size)
      end
    end
  end

  describe '設定ファイルの探索' do
    it '入力ファイルと同じ場所の setting.json を使う' do
      write_json(@dir, 'setting.json', { text: { font_size: '12pt' } })
      config = described_class.load(input_path: File.join(@dir, 'report.rmd'))
      expect(config.dig('text', 'font_size')).to eq('12pt')
      expect(config.source).to eq(File.join(@dir, 'setting.json'))
    end

    it '-c で指定したファイルを、同じ場所の setting.json より優先する' do
      write_json(@dir, 'setting.json', { text: { font_size: '12pt' } })
      other = write_json(@dir, 'other.json', { text: { font_size: '11pt' } })
      config = described_class.load(explicit_path: other, input_path: File.join(@dir, 'report.rmd'))
      expect(config.dig('text', 'font_size')).to eq('11pt')
    end

    it '指定された設定ファイルがなければエラーにする' do
      expect { described_class.load(explicit_path: File.join(@dir, 'nothing.json')) }
        .to raise_error(Reportmd::ConfigError, /見つかりません/)
    end
  end

  describe '統合' do
    it '書かれていない項目は、デフォルトで補う（入れ子も項目単位）' do
      path = write_json(@dir, 's.json', { page: { margin: { top: '30mm' } } })
      config = described_class.load(explicit_path: path)
      expect(config.dig('page', 'margin', 'top')).to eq('30mm')
      expect(config.dig('page', 'margin', 'left')).to eq('25mm')
    end

    it 'オブジェクトであるべき項目が違う型ならエラーにする' do
      path = write_json(@dir, 's.json', { page: { margin: '25mm' } })
      expect { described_class.load(explicit_path: path) }
        .to raise_error(Reportmd::ConfigError, /page\.margin/)
    end
  end

  describe '検証' do
    {
      '用紙サイズ' => [{ document: { paper: 'a3' } }, /document\.paper/],
      '余白の単位' => [{ page: { margin: { top: '25' } } }, /page\.margin\.top/],
      '文字サイズの範囲' => [{ text: { font_size: '30pt' } }, /text\.font_size/],
      '行間の型' => [{ text: { line_spacing: '1.5' } }, /text\.line_spacing/],
      '字下げの範囲' => [{ text: { paragraph_indent: 9 } }, /text\.paragraph_indent/],
      'ページ番号の型' => [{ page: { numbering: 'yes' } }, /page\.numbering/],
      'フォント名の特殊文字' => [{ font: { main: 'A}B' } }, /font\.main/],
      '見出しサイズの個数' => [{ heading: { sizes: ['14pt'] } }, /heading\.sizes/],
      'キャプション位置' => [{ caption: { table_position: 'left' } }, /caption\.table_position/],
      '表の配置' => [{ table: { position: 'right' } }, /table\.position/],
      '表の幅' => [{ table: { width: '50%' } }, /table\.width/],
      '表の文字サイズ' => [{ table: { font_size: '4pt' } }, /table\.font_size/],
      '表の行の高さ' => [{ table: { row_spacing: 5 } }, /table\.row_spacing/],
      'セルの余白' => [{ table: { cell_padding: 6 } }, /table\.cell_padding/],
      '表の見出しの太字' => [{ table: { header: { bold: 'yes' } } }, /table\.header\.bold/],
      '表の見出しの揃え' => [{ table: { header: { align: 'middle' } } }, /table\.header\.align/],
      '罫線の太さ' => [{ table: { rules: { top: '1' } } }, /table\.rules\.top/],
      '罫線に true' => [{ table: { rules: { vertical: true } } }, /table\.rules\.vertical/]
    }.each do |name, (data, pattern)|
      it "#{name}が不正ならエラーにし、項目名を示す" do
        path = write_json(@dir, 's.json', data)
        expect { described_class.load(explicit_path: path) }
          .to raise_error(Reportmd::ConfigError, pattern)
      end
    end

    it 'JSONとして不正なファイルはエラーにする' do
      path = write_json(@dir, 's.json', '{ "text": { "font_size": "12pt" } "x": 1 }')
      expect { described_class.load(explicit_path: path) }
        .to raise_error(Reportmd::ConfigError, /JSON/) { |e| expect(e.file).to eq(path) }
    end

    {
      'カンマの抜け' => ["{\n  \"text\": {\n    \"font_size\": \"12pt\"\n    \"line_spacing\": 1.5\n  }\n}", 4],
      '末尾の余分なカンマ' => ["{\n  \"a\": 1,\n  \"b\": 2,\n}\n", 4],
      'クォートのないキー' => ["{\n  \"a\": {\n    b: 1\n  }\n}", 3],
      '閉じ括弧の抜け' => ["{\n  \"a\": [1, 2\n}\n", 3],
      '後ろの余分な文字' => ["{\n  \"a\": 1\n}\n}\n", 4]
    }.each do |name, (text, line)|
      it "JSON の構文エラー（#{name}）は、崩れた位置の行番号を示す" do
        path = write_json(@dir, 's.json', text)
        expect { described_class.load(explicit_path: path) }
          .to raise_error(Reportmd::ConfigError) { |e| expect(e.line).to eq(line) }
      end
    end

    it '値が不正なときは、設定ファイルのパスを示す' do
      path = write_json(@dir, 's.json', { text: { font_size: '30pt' } })
      expect { described_class.load(explicit_path: path) }
        .to raise_error(Reportmd::ConfigError) { |e| expect(e.file).to eq(path) }
    end

    it '最上位がオブジェクトでなければエラーにする' do
      path = write_json(@dir, 's.json', '[1, 2]')
      expect { described_class.load(explicit_path: path) }
        .to raise_error(Reportmd::ConfigError, /オブジェクト/)
    end
  end

  describe '警告' do
    it '未知のキーは警告して無視する' do
      path = write_json(@dir, 's.json', { text: { colour: 'red' }, foo: 1 })
      config = described_class.load(explicit_path: path)
      expect(config.warnings).to include('未知の設定キーを無視します: text.colour')
      expect(config.warnings).to include('未知の設定キーを無視します: foo')
      expect(config.values.dig('text')).not_to have_key('colour')
    end

    it '未対応として登録された設定をユーザーが書いた場合は警告する' do
      stub_const('Reportmd::Config::NOT_YET_SUPPORTED', %w[caption])
      path = write_json(@dir, 's.json', { caption: { figure_label: 'Fig.' } })
      config = described_class.load(explicit_path: path)
      expect(config.warnings.join).to include('caption')
    end

    it '対応済みの設定（heading、caption）を書いても、警告しない' do
      path = write_json(@dir, 's.json', { heading: { bold: false }, caption: { figure_label: 'Fig.' } })
      expect(described_class.load(explicit_path: path).warnings).to eq([])
    end

    it '未対応の設定を書いていなければ、警告しない' do
      path = write_json(@dir, 's.json', { text: { font_size: '12pt' } })
      expect(described_class.load(explicit_path: path).warnings).to eq([])
    end
  end
end
