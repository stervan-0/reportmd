# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'stringio'
require 'tmpdir'
require 'zlib'
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
      setting = write_file('setting.json', '{ "text": { "font_size": "99pt" } }')
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to start_with("#{setting}: error: 設定 text.font_size の値が不正です")
    end

    it 'JSON の構文エラーは、設定ファイル名と行番号つきで表示する' do
      input = write_file('a.rmd', "本文\n")
      setting = write_file('setting.json', "{\n  \"text\": {\n    \"font_size\": \"12pt\",\n  }\n}\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to start_with("#{setting}:4: error: 設定ファイルがJSONとして不正です")
    end

    it '-c で指定した設定ファイルがなければ、そのファイル名つきで表示する' do
      input = write_file('a.rmd', "本文\n")
      missing = File.join(@dir, 'none.json')
      code, _out, err = run_cli('build', input, '-c', missing)
      expect(code).to eq(1)
      expect(err).to start_with("#{missing}: error: 設定ファイルが見つかりません")
    end

    it '入力ファイルがなければ、そのファイル名つきで表示する' do
      missing = File.join(@dir, 'none.rmd')
      code, _out, err = run_cli('build', missing)
      expect(code).to eq(1)
      expect(err).to start_with("#{missing}: error: 入力ファイルが見つかりません")
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
      setting = write_file('setting.json', '{ "font": { "main": "NoSuchFontXYZ" } }')
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      # フォントは設定ファイルの問題なので、設定ファイル名を示す
      expect(err).to start_with("#{setting}: error: フォント「NoSuchFontXYZ」が見つかりません")
    end

    it '未知の設定キーは警告するが、PDF は出力する' do
      input = write_file('report.rmd', source)
      setting = write_file('setting.json', '{ "unknown_key": 1 }')
      code, _out, err = run_cli('build', input)
      expect(code).to eq(0)
      expect(err).to include("#{setting}: warning: 未知の設定キーを無視します: unknown_key")
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

    it 'フロントマターの対応外のキーは、ファイル名と行番号つきで警告するが、PDF は出力する' do
      input = write_file('report.rmd', "---\ntitle: 実験レポート\ngeometry: margin=1mm\n---\n\n本文\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(0)
      expect(err).to include("#{input}:3: warning: 対応外のフロントマターのキーを無視します: geometry")
      expect(File.exist?(File.join(@dir, 'report.pdf'))).to be(true)
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

  describe 'PDF の生成（2スペースの字下げ）' do
    before do
      skip 'PDF 生成に必要なツールやフォントがありません' unless pdf_build_ready?
      skip 'pdftotext がありません' unless system('pdftotext', '-v', out: File::NULL, err: File::NULL)
    end

    def left_of(pdf, text)
      html = IO.popen(['pdftotext', '-bbox', pdf, '-'], &:read).force_encoding('UTF-8')
      html.scan(%r{xMin="([\d.]+)" yMin="[\d.]+" xMax="[\d.]+" yMax="[\d.]+">(.*?)</word>}m)
          .to_h { |x, t| [t, x.to_f] }.fetch(text)
    end

    it 'paragraph_indent が 0 でも、2スペース始まりの段落だけ1字（10.5pt）下がる' do
      input = write_file('ind.rmd', "字下げなし\n\n  字下げあり\n")
      write_file('setting.json', '{ "text": { "paragraph_indent": 0 } }')
      code, = run_cli('build', input)
      expect(code).to eq(0)

      pdf = File.join(@dir, 'ind.pdf')
      expect(left_of(pdf, '字下げなし')).to be_within(1.0).of(70.866)
      expect(left_of(pdf, '字下げあり')).to be_within(1.0).of(70.866 + 10.5)
    end

    it 'paragraph_indent が 2 のとき、2スペース始まりの段落は1字になる（足し算しない）' do
      input = write_file('ind.rmd', "通常段落\n\n  二スペース\n")
      write_file('setting.json', '{ "text": { "paragraph_indent": 2 } }')
      code, = run_cli('build', input)
      expect(code).to eq(0)

      pdf = File.join(@dir, 'ind.pdf')
      expect(left_of(pdf, '通常段落')).to be_within(1.0).of(70.866 + 21)
      expect(left_of(pdf, '二スペース')).to be_within(1.0).of(70.866 + 10.5)
    end
  end

  describe '図表の記法のエラー' do
    it '直後に表がない ![t:...] は、ファイル名と行番号つきでエラーにして 1 を返す' do
      input = write_file('a.rmd', "本文\n\n![t:なし]\n\n本文\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to include("#{input}:3: error: ![t:...] の直後に表がありません")
    end

    it '画像のパスがない ![f:...] は、行番号つきでエラーにして 1 を返す' do
      input = write_file('a.rmd', "![f:パスなし]\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to include("#{input}:1: error: 図には画像のパスが必要です")
    end
  end

  describe 'PDF の生成（図表の番号とキャプション）' do
    PNG_1PX = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
    PAGE_WIDTH = 595.276 unless defined?(PAGE_WIDTH)
    TEXT_WIDTH_PT = 453.544 # A4 の幅から左右の余白 25mm を引いた本文幅

    before do
      skip 'PDF 生成に必要なツールやフォントがありません' unless pdf_build_ready?
      skip 'pdftotext がありません' unless system('pdftotext', '-v', out: File::NULL, err: File::NULL)
      File.binwrite(File.join(@dir, 'img.png'), Base64.decode64(PNG_1PX))
    end

    # PDF 内の単語の { text:, x_min:, x_max:, y_min:, y_max: } を、出現順に取り出す
    def pdf_words(pdf)
      html = IO.popen(['pdftotext', '-bbox', pdf, '-'], &:read).force_encoding('UTF-8')
      html.scan(%r{xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>}m)
          .map { |x0, y0, x1, y1, text| { text: text, x_min: x0.to_f, y_min: y0.to_f, x_max: x1.to_f, y_max: y1.to_f } }
    end

    def pdf_word(words, text)
      words.find { |w| w[:text] == text } || raise("PDF に #{text.inspect} が見つかりません")
    end

    def build_pdf(rmd, setting: nil)
      write_file('setting.json', setting) if setting
      input = write_file('fig.rmd', rmd)
      code, _out, err = run_cli('build', input)
      expect(code).to eq(0), err
      File.join(@dir, 'fig.pdf')
    end

    let(:table) { "| 条件 | 結果 |\n|---|---|\n| A | 10 |\n" }
    let(:figure_doc) { "前の段落です。\n\n![f:システム構成図](img.png){width=40%}\n\n次の段落です。\n" }

    it '図と表は別々に、出現順に 図1、図2、表1、表2 と採番され、タイトルが付く' do
      rmd = "![f:一つ目](img.png){width=20%}\n\n![t:表の一つ目]\n#{table}\n" \
            "![f:二つ目](img.png){width=20%}\n\n![t:表の二つ目]\n#{table}"
      text = `pdftotext -layout #{build_pdf(rmd)} -`.force_encoding('UTF-8')
      expect(text).to match(/図\s*1\s*一つ目/)
      expect(text).to match(/図\s*2\s*二つ目/)
      expect(text).to match(/表\s*1\s*表の一つ目/)
      expect(text).to match(/表\s*2\s*表の二つ目/)
    end

    it 'タイトルが空なら、番号だけが表示される' do
      rmd = "![f](img.png){width=20%}\n\n![t]\n#{table}"
      text = `pdftotext -layout #{build_pdf(rmd)} -`.force_encoding('UTF-8')
      expect(text).to match(/図\s*1\s*$/)
      expect(text).to match(/表\s*1\s*$/)
    end

    it '図のキャプションは、既定では画像の下に、ページの中央に置かれる' do
      words = pdf_words(build_pdf(figure_doc))
      before = pdf_word(words, '前の段落です。')
      caption = pdf_word(words, 'システム構成図')
      after = pdf_word(words, '次の段落です。')

      image_height = 0.4 * TEXT_WIDTH_PT
      expect(caption[:y_min] - before[:y_max]).to be > image_height
      expect(after[:y_min] - caption[:y_max]).to be < 30

      line = words.select { |w| (w[:y_min] - caption[:y_min]).abs < 1 }
      center = (line.map { |w| w[:x_min] }.min + line.map { |w| w[:x_max] }.max) / 2
      expect(center).to be_within(1.5).of(PAGE_WIDTH / 2)
    end

    it 'figure_position を top にすると、図のキャプションが画像の上に置かれる' do
      words = pdf_words(build_pdf(figure_doc, setting: '{ "caption": { "figure_position": "top" } }'))
      before = pdf_word(words, '前の段落です。')
      caption = pdf_word(words, 'システム構成図')
      after = pdf_word(words, '次の段落です。')

      expect(caption[:y_min] - before[:y_max]).to be < 40
      expect(after[:y_min] - caption[:y_max]).to be > 0.4 * TEXT_WIDTH_PT
    end

    it '表のキャプションは、既定では表の上に置かれる' do
      words = pdf_words(build_pdf("![t:実験結果]\n#{table}"))
      expect(pdf_word(words, '実験結果')[:y_max]).to be < pdf_word(words, '条件')[:y_min]
    end

    it 'table_position を bottom にすると、表のキャプションが表の下に置かれる' do
      words = pdf_words(build_pdf("![t:実験結果]\n#{table}", setting: '{ "caption": { "table_position": "bottom" } }'))
      expect(pdf_word(words, '実験結果')[:y_min]).to be > pdf_word(words, '10')[:y_max]
    end

    it '設定でラベルを変えられる' do
      setting = '{ "caption": { "figure_label": "Fig.", "table_label": "Table" } }'
      rmd = "![f:図の例](img.png){width=20%}\n\n![t:表の例]\n#{table}"
      text = `pdftotext -layout #{build_pdf(rmd, setting: setting)} -`.force_encoding('UTF-8')
      expect(text).to match(/Fig\.\s*1\s*図の例/)
      expect(text).to match(/Table\s*1\s*表の例/)
    end

    it '全角コロンの記法は、図表として扱わず、警告を出す（PDF は出力する）' do
      input = write_file('fig.rmd', "![f：全角](img.png){width=20%}\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(0)
      expect(err).to include("#{input}:1: warning:")
      expect(`pdftotext -layout #{File.join(@dir, 'fig.pdf')} -`.force_encoding('UTF-8')).not_to match(/図\s*1/)
    end

    it '@名前 の参照が、PDF の本文で「図1」「表1」になる' do
      rmd = "@sys に示すように、結果は @resultにまとめた。\n\n" \
            "![f:構成](img.png){#sys width=20%}\n\n![t:結果]{#result}\n#{table}"
      text = `pdftotext #{build_pdf(rmd)} -`.force_encoding('UTF-8')
      expect(text).to match(/図\s*1\s*に示すように、結果は表\s*1\s*にまとめた。/)
    end

    it '参照先がない名前と、重複した名前は警告するが、PDF は出力する' do
      rmd = "@nothing を参照。\n\n![f:a](img.png){#dup width=20%}\n\n![f:b](img.png){#dup width=20%}\n"
      input = write_file('fig.rmd', rmd)
      code, _out, err = run_cli('build', input)
      expect(code).to eq(0)
      expect(err).to include("#{input}:5: warning: 図表の名前 #dup は、3 行目でも使われています")
      expect(err).to include("#{input}: warning: 参照先の図表が見つかりません: @nothing")
    end

    # 幅 width、高さ height の、真っ白な PNG（グレースケール 8bit）を作る
    def blank_png(width, height)
      chunk = lambda do |type, data|
        [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
      end
      raw = ("\x00".b + ("\xFF".b * width)) * height
      "\x89PNG\r\n\x1a\n".b +
        chunk.call('IHDR', [width, height, 8, 0, 0, 0, 0].pack('NNCCCCC')) +
        chunk.call('IDAT', Zlib::Deflate.deflate(raw)) +
        chunk.call('IEND', ''.b)
    end

    it '幅を指定していない大きな画像は、本文幅に収まるよう縮小される' do
      skip 'pdfimages がありません' unless system('pdfimages', '-v', out: File::NULL, err: File::NULL)
      File.binwrite(File.join(@dir, 'big.png'), blank_png(2000, 40))
      pdf = build_pdf("![f:大きい図](big.png)\n\n本文\n")

      # pdfimages -list の x-ppi 列から、PDF 上の画像の幅（pt）を求める
      row = `pdfimages -list #{pdf}`.lines.grep(/\A\s*1\s+0\s+image/).first
      columns = row.split
      width_px = columns[3].to_f
      ppi = columns[12].to_f
      displayed_pt = width_px / ppi * 72
      expect(displayed_pt).to be <= TEXT_WIDTH_PT + 1
      expect(displayed_pt).to be > TEXT_WIDTH_PT - 5 # 本文幅いっぱいまで縮小される
    end
  end

  describe 'PDF の生成（表の書式）' do
    before { skip 'PDF 生成に必要なツールやフォントがありません' unless pdf_build_ready? }

    A4_WIDTH = 595.276 unless defined?(A4_WIDTH)
    MARGIN_25MM = 70.866 unless defined?(MARGIN_25MM)

    let(:rmd) { "![t:結果]\n| 条件 | 測定値 |\n|:---|---:|\n| 左端 | 右端 |\n| A | 10 |\n" }

    def table_words(setting = nil)
      write_file('setting.json', setting) if setting
      input = write_file('table.rmd', rmd)
      code, _out, err = run_cli('build', input)
      expect(code).to eq(0), err
      html = IO.popen(['pdftotext', '-bbox', File.join(@dir, 'table.pdf'), '-'], &:read).force_encoding('UTF-8')
      html.scan(%r{xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>}m)
          .to_h { |x0, y0, x1, y1, text| [text, { x_min: x0.to_f, y_min: y0.to_f, x_max: x1.to_f, y_max: y1.to_f }] }
    end

    # --keep-temp で残したプリアンブル
    def preamble(setting)
      write_file('setting.json', setting)
      input = write_file('table.rmd', rmd)
      code, _out, err = run_cli('build', input, '--keep-temp')
      expect(code).to eq(0), err
      kept = err[/一時ファイルを残しました: (.+)$/, 1]
      text = File.read(File.join(kept, 'preamble.tex'))
      FileUtils.rm_rf(kept)
      text
    end

    it '既定では、表をページの中央に置く' do
      words = table_words
      center = (words.fetch('左端')[:x_min] + words.fetch('右端')[:x_max]) / 2
      expect(center).to be_within(2.0).of(A4_WIDTH / 2)
    end

    it 'position が left なら、表を本文の左端に置く（セルの余白の分だけ内側に文字が来る）' do
      words = table_words('{ "table": { "position": "left", "cell_padding": "6pt" } }')
      expect(words.fetch('左端')[:x_min]).to be_within(1.0).of(MARGIN_25MM + 6)
    end

    it 'width が full なら、表を本文幅いっぱいに広げる' do
      words = table_words('{ "table": { "width": "full", "cell_padding": "6pt" } }')
      expect(words.fetch('左端')[:x_min]).to be_within(1.0).of(MARGIN_25MM + 6)
      expect(words.fetch('右端')[:x_max]).to be_within(1.0).of(A4_WIDTH - MARGIN_25MM - 6)
    end

    it 'font_size で、表の中の文字だけを小さくできる（キャプションは本文と同じ）' do
      normal = table_words
      small = table_words('{ "table": { "font_size": "8pt" } }')
      height = ->(words, text) { words.fetch(text)[:y_max] - words.fetch(text)[:y_min] }
      expect(height.call(small, '左端') / height.call(normal, '左端')).to be_within(0.05).of(8 / 10.5)
      expect(height.call(small, '結果')).to be_within(0.1).of(height.call(normal, '結果'))
    end

    it 'row_spacing を大きくすると、行の間隔が広がる' do
      gap = ->(words) { words.fetch('A')[:y_min] - words.fetch('左端')[:y_min] }
      normal = gap.call(table_words('{ "table": { "row_spacing": 1.0 } }'))
      wide = gap.call(table_words('{ "table": { "row_spacing": 2.0 } }'))
      expect(wide / normal).to be_within(0.1).of(2.0)
    end

    it '既定のプリアンブルは三線表（上下 0.8pt、見出しの下 1.2pt、縦線と行の間の線なし）' do
      text = preamble('{}')
      expect(text).to include('\\newcommand{\\reportmdruletop}{\\noalign{\\hrule height 0.8pt}}')
      expect(text).to include('\\newcommand{\\reportmdruleheader}{\\noalign{\\hrule height 1.2pt}}')
      expect(text).to include('\\newcommand{\\reportmdrulebottom}{\\noalign{\\hrule height 0.8pt}}')
      expect(text).to include('\\newcommand{\\reportmdrulerows}{}')
      expect(text).to include('\\newcommand{\\reportmdvrule}{}')
      expect(text).to include('\\newcommand{\\reportmdvside}{}')
      expect(text).to include('\\newcommand{\\reportmdtablehead}[1]{#1}')
    end

    it 'すべての罫線と見出しの太字を指定しても、PDF を生成できる' do
      text = preamble('{ "table": { "header": { "bold": true }, "rules": { "top": "1.5pt", "rows": "0.2pt", ' \
                      '"vertical": "0.4pt", "sides": "1mm" } } }')
      expect(text).to include('\\newcommand{\\reportmdruletop}{\\noalign{\\hrule height 1.5pt}}')
      expect(text).to include('\\newcommand{\\reportmdrulerows}{\\noalign{\\hrule height 0.2pt}}')
      expect(text).to include('\\newcommand{\\reportmdvrule}{\\vrule width 0.4pt}')
      expect(text).to include('\\newcommand{\\reportmdvside}{\\vrule width 1mm}')
      expect(text).to include('AutoFakeBold')
    end
  end

  # 結合テスト（スモークテスト）：同梱のサンプルから PDF が作れることを確認する。
  # 見た目そのものは比較しない。
  describe 'サンプル（examples/report.rmd）' do
    before { skip 'PDF 生成に必要なツールやフォントがありません' unless pdf_build_ready? }

    it '警告なしで PDF を生成できる' do
      input = File.expand_path('../examples/report.rmd', __dir__)
      output = File.join(@dir, 'report.pdf')
      code, _out, err = run_cli('build', input, '-o', output)
      expect(err).to eq('')
      expect(code).to eq(0)
      expect(File.binread(output, 4)).to eq('%PDF')
      if system('pdftotext', '-v', out: File::NULL, err: File::NULL)
        text = `pdftotext #{output} -`
        expect(text).to include('実験レポート')
        expect(text).to match(/表\s*1\s*ツールの構成/).and match(/表\s*2\s*変換の段階/)
      end
    end
  end
end
