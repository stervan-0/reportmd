# frozen_string_literal: true

require 'fileutils'
require 'stringio'
require 'tmpdir'
require_relative '../lib/reportmd/cli'

RSpec.describe Reportmd::CLI do
  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    code = described_class.run(args, stdout: out, stderr: err)
    [code, out.string, err.string]
  end

  def write_file(name, text)
    path = File.join(@dir, name)
    File.write(path, text)
    path
  end

  # PDF まで作れる環境（Pandoc・XeLaTeX・xeCJK・設定の既定フォント）かどうか
  def pdf_build_ready?
    return false unless system('pandoc', '--version', out: File::NULL, err: File::NULL)
    return false unless system('xelatex', '--version', out: File::NULL, err: File::NULL)
    return false if `kpsewhich xeCJK.sty 2>/dev/null`.strip.empty?

    fonts = `fc-list : family 2>/dev/null`.downcase
    fonts.include?('ipaexmincho') && fonts.include?('ipaexgothic') && fonts.include?('noto sans mono cjk jp')
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  describe 'コマンドの振り分け' do
    it '--version でバージョンを表示し、0 を返す' do
      code, out, = run_cli('--version')
      expect(code).to eq(0)
      expect(out).to eq("reportmd #{Reportmd::VERSION}\n")
    end

    it '--help で使い方を表示し、0 を返す' do
      code, out, = run_cli('--help')
      expect(code).to eq(0)
      expect(out).to include('reportmd build')
    end

    it '引数がなければ使い方を表示し、1 を返す' do
      code, _out, err = run_cli
      expect(code).to eq(1)
      expect(err).to include('reportmd build')
    end

    it '不明なコマンドは 1 を返す' do
      code, _out, err = run_cli('foo')
      expect(code).to eq(1)
      expect(err).to include('不明なコマンド')
    end
  end

  describe 'build の入力チェック' do
    it '入力ファイルがなければ 1 を返す' do
      code, _out, err = run_cli('build')
      expect(code).to eq(1)
      expect(err).to include('入力ファイルを1つ指定')
    end

    it '存在しない入力ファイルは 1 を返す' do
      code, _out, err = run_cli('build', File.join(@dir, 'nothing.rmd'))
      expect(code).to eq(1)
      expect(err).to include('入力ファイルが見つかりません')
    end

    it '不明なオプションは 1 を返す' do
      input = write_file('a.rmd', "本文\n")
      code, _out, err = run_cli('build', input, '--foo')
      expect(code).to eq(1)
      expect(err).to include('--foo')
    end

    it '不正な設定は、項目名つきのエラーにして 1 を返す' do
      input = write_file('a.rmd', "本文\n")
      write_file('setting.json', '{ "text": { "font_size": "99pt" } }')
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to include('text.font_size')
    end

    it '独自構文のエラーは、ファイル名と行番号つきで表示する' do
      input = write_file('a.rmd', "本文\n\n$$\nx\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to include("#{input}:3: error: 数式ブロック")
    end
  end

  describe 'PDF の生成' do
    before { skip 'PDF 生成に必要なツールやフォントがありません' unless pdf_build_ready? }

    let(:source) { "# テスト\n\n1ページ目の本文です。\n\n^\n\n2ページ目の本文です。\n" }

    it '入力と同じ場所に、同名の PDF を出力する（2ページに分かれる）' do
      input = write_file('report.rmd', source)
      code, out, err = run_cli('build', input)
      expect(err).to eq('')
      expect(code).to eq(0)
      pdf = File.join(@dir, 'report.pdf')
      expect(out).to include(pdf)
      expect(File.binread(pdf, 4)).to eq('%PDF')
      if system('pdfinfo', '--help', out: File::NULL, err: File::NULL)
        expect(`pdfinfo #{pdf}`).to match(/Pages:\s+2/)
      end
    end

    it '-o で出力先を指定できる' do
      input = write_file('report.rmd', source)
      output = File.join(@dir, 'out.pdf')
      code, = run_cli('build', input, '-o', output)
      expect(code).to eq(0)
      expect(File.exist?(output)).to be(true)
    end

    it '出力先のディレクトリがなければ 1 を返す' do
      input = write_file('report.rmd', source)
      code, _out, err = run_cli('build', input, '-o', File.join(@dir, 'nothing', 'out.pdf'))
      expect(code).to eq(1)
      expect(err).to include('出力先のディレクトリがありません')
    end

    it '存在しないフォントを指定したら、フォント名を示して 1 を返す' do
      input = write_file('report.rmd', source)
      write_file('setting.json', '{ "font": { "main": "NoSuchFontXYZ" } }')
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to include('NoSuchFontXYZ')
    end

    it '未対応の設定は警告するが、PDF は出力する' do
      input = write_file('report.rmd', source)
      write_file('setting.json', '{ "caption": { "figure_label": "Fig." } }')
      code, _out, err = run_cli('build', input)
      expect(code).to eq(0)
      expect(err).to include('warning')
      expect(File.exist?(File.join(@dir, 'report.pdf'))).to be(true)
    end

    it '--keep-temp で一時ファイルを残す' do
      input = write_file('report.rmd', source)
      code, _out, err = run_cli('build', input, '--keep-temp')
      expect(code).to eq(0)
      kept = err[/一時ファイルを残しました: (.+)$/, 1]
      expect(kept).not_to be_nil
      expect(File.exist?(File.join(kept, 'body.md'))).to be(true)
      FileUtils.rm_rf(kept)
    end

    it '日本語のフロントマターのタイトルが、PDF のメタデータに入る' do
      input = write_file('report.rmd', "---\ntitle: 実験レポート\n---\n\n本文\n")
      code, = run_cli('build', input)
      expect(code).to eq(0)
      if system('pdfinfo', '--help', out: File::NULL, err: File::NULL)
        expect(`pdfinfo #{File.join(@dir, 'report.pdf')}`).to include('実験レポート')
      end
    end
  end

  describe 'PDF の生成（右揃え・中央揃えの位置）' do
    A4_WIDTH = 595.276
    MARGIN_25MM = 70.866

    before do
      skip 'PDF 生成に必要なツールやフォントがありません' unless pdf_build_ready?
      skip 'pdftotext がありません' unless system('pdftotext', '-v', out: File::NULL, err: File::NULL)
    end

    # PDF 内の単語ごとの位置 { 単語 => [xMin, xMax] } を取り出す
    def word_positions(pdf)
      html = IO.popen(['pdftotext', '-bbox', pdf, '-'], &:read).force_encoding('UTF-8')
      html.scan(%r{xMin="([\d.]+)" yMin="[\d.]+" xMax="([\d.]+)" yMax="[\d.]+">(.*?)</word>}m)
          .to_h { |x_min, x_max, text| [text, [x_min.to_f, x_max.to_f]] }
    end

    it '右揃えは右余白の位置に、中央揃えはページの中央に配置される' do
      input = write_file('align.rmd', "<-> 実験レポート\n\n--> 大阪工業大学\n\n- 項目\n- --> 右の項目\n")
      code, = run_cli('build', input)
      expect(code).to eq(0)

      words = word_positions(File.join(@dir, 'align.pdf'))
      center = words.fetch('実験レポート').sum / 2
      expect(center).to be_within(1.0).of(A4_WIDTH / 2)
      expect(words.fetch('大阪工業大学').last).to be_within(1.0).of(A4_WIDTH - MARGIN_25MM)
      expect(words.fetch('右の項目').last).to be_within(1.0).of(A4_WIDTH - MARGIN_25MM)
    end

    it '設定の余白を変えると、右揃えの位置も変わる' do
      input = write_file('align.rmd', "--> 大阪工業大学\n")
      write_file('setting.json', '{ "page": { "margin": { "right": "40mm" } } }')
      code, = run_cli('build', input)
      expect(code).to eq(0)

      right_edge = word_positions(File.join(@dir, 'align.pdf')).fetch('大阪工業大学').last
      expect(right_edge).to be_within(1.0).of(A4_WIDTH - 40 * 72 / 25.4)
    end

    it '段落の1行目は、paragraph_indent の分だけ字下げされる（1字 = 10.5pt）' do
      input = write_file('align.rmd', "段落の本文です。\n")
      code, = run_cli('build', input)
      expect(code).to eq(0)

      left = word_positions(File.join(@dir, 'align.pdf')).fetch('段落の本文です。').first
      expect(left).to be_within(1.0).of(MARGIN_25MM + 10.5)
    end
  end

  describe 'PDF の生成（見出しの番号と字下げ）' do
    A4_WIDTH = 595.276 unless defined?(A4_WIDTH)
    MARGIN_25MM = 70.866 unless defined?(MARGIN_25MM)
    PT_PER_TEXPT = 0.99626 # TeX の 1pt は PDF 上では 0.99626 単位

    before do
      skip 'PDF 生成に必要なツールやフォントがありません' unless pdf_build_ready?
      skip 'pdftotext がありません' unless system('pdftotext', '-v', out: File::NULL, err: File::NULL)
    end

    # PDF 内の単語の { text:, x_min:, x_max:, height: } を、出現順に取り出す
    def words_in(pdf)
      html = IO.popen(['pdftotext', '-bbox', pdf, '-'], &:read).force_encoding('UTF-8')
      html.scan(%r{xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>}m)
          .map { |x0, y0, x1, y1, text| { text: text, x_min: x0.to_f, x_max: x1.to_f, height: y1.to_f - y0.to_f } }
    end

    def word(words, text)
      words.find { |w| w[:text] == text } || raise("PDF に #{text.inspect} が見つかりません")
    end

    let(:source) do
      "#1 はじめに\n\n本文\n\n#2 背景\n\n#3 詳細\n\n#2 目的\n\n#1 まとめ\n\n# 番号なし\n"
    end

    it '番号が 1、1.1、1.1.1、1.2、2 の順に付き、標準の # 見出しには付かない' do
      input = write_file('h.rmd', source)
      code, = run_cli('build', input)
      expect(code).to eq(0)

      text = `pdftotext -layout #{File.join(@dir, 'h.pdf')} -`.force_encoding('UTF-8')
      expect(text).to match(/^\s*1\s+はじめに/)
      expect(text).to match(/^\s*1\.1\s+背景/)
      expect(text).to match(/^\s*1\.1\.1\s+詳細/)
      expect(text).to match(/^\s*1\.2\s+目的/)
      expect(text).to match(/^\s*2\s+まとめ/)
      expect(text).to match(/^\s*番号なし\s*$/)
    end

    it '既定では、レベルに応じて 0字・1字・2字だけ字下げされる（番号なしの見出しも同じ）' do
      input = write_file('h.rmd', source)
      run_cli('build', input)
      words = words_in(File.join(@dir, 'h.pdf'))

      one_char = 10.5 * PT_PER_TEXPT
      expect(word(words, '1')[:x_min]).to be_within(0.5).of(MARGIN_25MM)
      expect(word(words, '1.1')[:x_min]).to be_within(0.5).of(MARGIN_25MM + one_char)
      expect(word(words, '1.1.1')[:x_min]).to be_within(0.5).of(MARGIN_25MM + one_char * 2)
      expect(word(words, '番号なし')[:x_min]).to be_within(0.5).of(MARGIN_25MM)
    end

    it 'heading.indents の設定で字下げ量を変えられる' do
      write_file('setting.json', '{ "heading": { "indents": [0, 0, 0] } }')
      input = write_file('h.rmd', source)
      code, = run_cli('build', input)
      expect(code).to eq(0)

      words = words_in(File.join(@dir, 'h.pdf'))
      expect(word(words, '1.1')[:x_min]).to be_within(0.5).of(MARGIN_25MM)
      expect(word(words, '1.1.1')[:x_min]).to be_within(0.5).of(MARGIN_25MM)
    end

    it 'レベル1の見出しは、本文より大きい文字で組まれる（heading.sizes の設定で変わる）' do
      input = write_file('h.rmd', "#1 はじめに\n\n本文です。\n")
      run_cli('build', input)
      words = words_in(File.join(@dir, 'h.pdf'))
      default_ratio = word(words, 'はじめに')[:height] / word(words, '本文です。')[:height]
      expect(default_ratio).to be > 1.2

      write_file('setting.json', '{ "heading": { "sizes": ["20pt", "12pt", "10.5pt"] } }')
      run_cli('build', input)
      big_ratio = word(words_in(File.join(@dir, 'h.pdf')), 'はじめに')[:height] / word(words, '本文です。')[:height]
      expect(big_ratio).to be > default_ratio * 1.3
    end

    it 'heading.bold を false にすると、見出しの文字が細くなる' do
      skip 'pdftoppm がありません' unless system('pdftoppm', '-v', out: File::NULL, err: File::NULL)
      input = write_file('h.rmd', "#1 はじめに\n")
      run_cli('build', input)
      bold_size = render_ink(File.join(@dir, 'h.pdf'), 'bold')

      write_file('setting.json', '{ "heading": { "bold": false } }')
      run_cli('build', input)
      thin_size = render_ink(File.join(@dir, 'h.pdf'), 'thin')

      expect(bold_size).to be > thin_size * 1.15
    end

    # 1ページ目を PGM（白黒画像）にして、黒い部分の量（濃さの合計）を返す
    def render_ink(pdf, name)
      prefix = File.join(@dir, name)
      system('pdftoppm', '-r', '100', '-gray', '-f', '1', '-l', '1', pdf, prefix, exception: true)
      image = Dir.glob("#{prefix}*.pgm").first
      pixels = File.binread(image).unpack('C*')
      pixels.last(pixels.length - header_length(pixels)).sum { |v| 255 - v }
    end

    # PGM（P5）のヘッダ（形式・幅高さ・最大値の3行分）のバイト数
    def header_length(bytes)
      newlines = 0
      bytes.each_with_index do |byte, i|
        newlines += 1 if byte == 10
        return i + 1 if newlines == 3
      end
      0
    end

    it '見出しのフォントが見つからなければ、設定名を示してエラーにする' do
      write_file('setting.json', '{ "heading": { "font": "NoSuchHeadingFontXYZ" } }')
      input = write_file('h.rmd', "#1 a\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to include('NoSuchHeadingFontXYZ')
      expect(err).to include('heading.font')
    end

    it 'レベルが飛んだ見出しは、警告を出すが PDF は出力する' do
      input = write_file('h.rmd', "#1 a\n\n#3 b\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(0)
      expect(err).to include("#{input}:3: warning: 見出しレベルが飛んでいます")
      expect(File.exist?(File.join(@dir, 'h.pdf'))).to be(true)
    end
  end
end
