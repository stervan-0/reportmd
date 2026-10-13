# frozen_string_literal: true

require 'json'
require 'open3'
require 'tempfile'
require_relative '../lib/reportmd/preprocessor'

# 前処理 → Pandoc（filter.lua）を通した結果を確認するテスト。
# Pandoc が入っていない環境では、このファイルのテストを飛ばす。
RSpec.describe 'filter.lua' do
  filter_path = File.expand_path('../lib/reportmd/filter.lua', __dir__)
  define_method(:filter_path) { filter_path }

  define_method(:pandoc_available?) do
    system('pandoc', '--version', out: File::NULL, err: File::NULL)
  end

  define_method(:convert_with_pandoc) do |rmd, format, extra_args = []|
    markdown = Reportmd::Preprocessor.new(rmd).call.text
    out, err, status = Open3.capture3(
      'pandoc', '-f', 'markdown-raw_html-raw_tex',
      "--lua-filter=#{filter_path}", '-t', format, *extra_args,
      stdin_data: markdown
    )
    raise "pandoc が失敗しました: #{err}" unless status.success?

    out
  end

  before { skip 'pandoc が見つかりません' unless pandoc_available? }

  describe '改ページ' do
    it 'LaTeX では \newpage になる' do
      latex = convert_with_pandoc("前のページ\n\n^\n\n次のページ\n", 'latex')
      expect(latex).to match(/前のページ\s+\\newpage\s+次のページ/)
    end

    it 'コードブロックや数式ブロック内の ^ は \newpage にならない' do
      latex = convert_with_pandoc("```\n^\n```\n\n$$\n^\n$$\n", 'latex')
      expect(latex).not_to include('\newpage')
    end

    it 'LaTeX 以外の出力では、改ページのブロックが残らない' do
      html = convert_with_pandoc("前\n\n^\n\n後\n", 'html')
      expect(html).not_to include('reportmd-pagebreak')
    end
  end

  describe 'タイトルと著者' do
    let(:source) { "---\ntitle: 実験レポート\nauthor: 山田 太郎\n---\n\n本文\n" }

    it 'PDF のメタデータにだけ使い、本文にタイトルを出力しない' do
      latex = convert_with_pandoc(source, 'latex', ['-s'])
      expect(latex).not_to include('\\maketitle')
      expect(latex).to include('pdftitle={実験レポート}')
      expect(latex).to include('pdfauthor={山田 太郎}')
    end

    it '著者が複数なら、メタデータでは「, 」でつなぐ' do
      multi = "---\nauthor:\n  - 山田 太郎\n  - 佐藤 花子\n---\n\n本文\n"
      latex = convert_with_pandoc(multi, 'latex', ['-s'])
      expect(latex).to include('pdfauthor={山田 太郎, 佐藤 花子}')
    end

    it '対応外のキー（geometry・header-includes など）は、出力に反映しない' do
      source = "---\ntitle: 実験\ngeometry: margin=1mm\nheader-includes: '\\usepackage{xyzpkg}'\n" \
               "documentclass: book\n---\n\n本文\n"
      latex = convert_with_pandoc(source, 'latex', ['-s'])
      expect(latex).to include('pdftitle={実験}')
      expect(latex).not_to include('margin=1mm')
      expect(latex).not_to include('xyzpkg')
      expect(latex).not_to include('{book}')
    end
  end

  describe '右揃え・中央揃え' do
    it 'LaTeX では flushright 環境になる' do
      latex = convert_with_pandoc("--> 2026年10月12日\n", 'latex')
      expect(latex).to match(/\\begin\{flushright\}\s+2026年10月12日\s+\\end\{flushright\}/)
    end

    it 'LaTeX では中央揃えが center 環境になる' do
      latex = convert_with_pandoc("<-> 実験レポート\n", 'latex')
      expect(latex).to match(/\\begin\{center\}\s+実験レポート\s+\\end\{center\}/)
    end

    it '複数行は、行ごとに改行される' do
      latex = convert_with_pandoc("--> a\n--> b\n", 'latex')
      expect(latex).to match(/a\\\\\s+b/)
    end

    it '内容のインライン書式が使える' do
      latex = convert_with_pandoc("--> **太字**と$x^2$\n", 'latex')
      expect(latex).to include('\\textbf{太字}')
      expect(latex).to include('\\(x^2\\)')
    end

    it '引用・リストの内側でも、環境が正しく入れ子になる' do
      latex = convert_with_pandoc("> 引用\n> --> 右\n\n- 項目\n- --> 右の項目\n", 'latex')
      expect(latex).to include('\\begin{quote}')
      expect(latex.scan('\\begin{flushright}').length).to eq(2)
      expect(latex.scan('\\end{flushright}').length).to eq(2)
    end

    it 'HTML では text-align のスタイルになる' do
      html = convert_with_pandoc("--> a\n", 'html')
      expect(html).to include('text-align: right;')
    end
  end

  describe '見出しの番号' do
    let(:numbered_args) { ['--number-sections'] }

    it '#1〜#3 の見出しは、番号つきの \\section 系になる' do
      latex = convert_with_pandoc("#1 a\n\n#2 b\n\n#3 c\n", 'latex', numbered_args)
      expect(latex).to match(/\\section\{a\}/)
      expect(latex).to match(/\\subsection\{b\}/)
      expect(latex).to match(/\\subsubsection\{c\}/)
      expect(latex).not_to include('section*')
    end

    it '標準の # 見出しは、番号なし（\\section*）になる' do
      latex = convert_with_pandoc("# a\n\n## b\n\n### c\n", 'latex', numbered_args)
      expect(latex).to include('\\section*{a}')
      expect(latex).to include('\\subsection*{b}')
      expect(latex).to include('\\subsubsection*{c}')
    end

    it '番号つきと番号なしを混ぜても、それぞれ正しく分かれる' do
      latex = convert_with_pandoc("#1 はじめに\n\n# 参考文献\n", 'latex', numbered_args)
      expect(latex).to match(/\\section\{はじめに\}/)
      expect(latex).to include('\\section*{参考文献}')
    end

    it '番号つきの見出しにも、reportmd-num のクラスは出力に残らない' do
      latex = convert_with_pandoc("#1 a\n", 'latex', numbered_args)
      expect(latex).not_to include('reportmd-num')
    end

    it '見出しの中のインライン書式が使える' do
      latex = convert_with_pandoc("#1 **太字**と$x^2$\n", 'latex', numbered_args)
      expect(latex).to include('\\textbf{太字}')
      expect(latex).to include('\\(x^2\\)')
    end
  end

  describe '図表の番号とキャプション' do
    let(:table) { "| 条件 | 結果 |\n|---|---|\n| A | 10 |\n" }

    # 設定（metadata の reportmd）を渡して変換する
    def convert_with_settings(rmd, format, settings)
      Tempfile.create(['settings', '.json']) do |file|
        file.write(JSON.generate('reportmd' => settings))
        file.flush
        convert_with_pandoc(rmd, format, ["--metadata-file=#{file.path}"])
      end
    end

    describe 'HTML での確認（番号とタイトル）' do
      it '図は、出現順に 図1、図2 と採番する' do
        html = convert_with_pandoc("![f:一つ目](a.png)\n\n![f:二つ目](b.png)\n", 'html')
        expect(html).to match(%r{<figcaption[^>]*>図1 一つ目</figcaption>})
        expect(html).to match(%r{<figcaption[^>]*>図2 二つ目</figcaption>})
      end

      it '表は、図とは別の連番（表1、表2）で採番する' do
        rmd = "![f:図](a.png)\n\n![t:一つ目]\n#{table}\n![f:図](b.png)\n\n![t:二つ目]\n#{table}"
        html = convert_with_pandoc(rmd, 'html')
        expect(html).to include('<caption>表1 一つ目</caption>')
        expect(html).to include('<caption>表2 二つ目</caption>')
        expect(html).to match(%r{<figcaption[^>]*>図2 図</figcaption>})
      end

      it 'タイトルが空なら、番号だけを表示する' do
        html = convert_with_pandoc("![f](a.png)\n\n![t]\n#{table}", 'html')
        expect(html).to match(%r{<figcaption[^>]*>図1</figcaption>})
        expect(html).to include('<caption>表1</caption>')
      end

      it 'タイトルのインライン書式が使える' do
        html = convert_with_pandoc("![f:**太字**の図](a.png)\n\n![t:$x^2$ の表]\n#{table}", 'html')
        expect(html).to include('<strong>太字</strong>の図')
        expect(html).to match(/<caption>表1 .*<sup>2<\/sup>.*の表<\/caption>/m)
      end

      it '画像の属性（width）が残る' do
        html = convert_with_pandoc("![f:図](a.png){width=50%}\n", 'html')
        expect(html).to include('width:50')
      end

      it '番号を付けない通常の画像は、図として扱わない' do
        html = convert_with_pandoc("![図](a.png)\n", 'html')
        expect(html).not_to include('図1')
      end

      it '設定でラベルを変えられる' do
        html = convert_with_settings("![f:A](a.png)\n\n![t:B]\n#{table}", 'html',
                                     'figure_label' => 'Fig.', 'table_label' => 'Table')
        expect(html).to match(%r{<figcaption[^>]*>Fig\.1 A</figcaption>})
        expect(html).to include('<caption>Table1 B</caption>')
      end

      it '見出し用の Div は、出力に残らない' do
        html = convert_with_pandoc("![f:図](a.png)\n\n![t:表]\n#{table}", 'html')
        expect(html).not_to include('reportmd-')
      end
    end

    describe 'LaTeX での確認（固定配置・位置）' do
      it '図は浮動体（figure 環境）にせず、samepage と center で、書いた位置に置く' do
        latex = convert_with_pandoc("![f:システム構成図](a.png)\n", 'latex')
        expect(latex).not_to include('\\begin{figure}')
        expect(latex).not_to include('\\caption')
        expect(latex).to include('\\begin{samepage}\\begin{center}')
        expect(latex).to include('\\end{center}\\end{samepage}')
        expect(latex).to include('図1 システム構成図')
      end

      it '図のキャプションは、既定では画像の下（bottom）に置く' do
        latex = convert_with_pandoc("![f:図](a.png)\n", 'latex')
        expect(latex.index('\\includegraphics')).to be < latex.index('図1 図')
      end

      it 'figure_position が top なら、図のキャプションを画像の上に置く' do
        latex = convert_with_settings("![f:図](a.png)\n", 'latex', 'figure_position' => 'top')
        expect(latex.index('図1 図')).to be < latex.index('\\includegraphics')
      end

      it '表のキャプションは、既定では表の上（top）に置く' do
        latex = convert_with_pandoc("![t:実験結果]\n#{table}", 'latex')
        expect(latex).not_to include('\\caption')
        expect(latex.index('表1 実験結果')).to be < latex.index('\\begin{tabular}')
        expect(latex).to include('\\nopagebreak')
      end

      it 'table_position が bottom なら、表のキャプションを表の下に置く' do
        latex = convert_with_settings("![t:実験結果]\n#{table}", 'latex', 'table_position' => 'bottom')
        expect(latex.index('\\end{tabular}')).to be < latex.index('表1 実験結果')
      end

      it '画像の属性（width）が \\includegraphics に渡る' do
        latex = convert_with_pandoc("![f:図](a.png){width=50%}\n", 'latex')
        expect(latex).to match(/\\includegraphics\[[^\]]*width=0\.5\\textwidth/)
      end
    end

    describe '想定外の入力' do
      it '図の行に画像以外の文字があれば、警告して番号を付けず、内容は残す' do
        markdown = Reportmd::Preprocessor.new("本文\n\n![f:図](a.png) 説明\n").call.text
        out, err, status = Tempfile.create(['settings', '.json']) do |file|
          file.write(JSON.generate('reportmd' => { 'source' => 'a.rmd' }))
          file.flush
          Open3.capture3('pandoc', '-f', 'markdown-raw_html-raw_tex', "--lua-filter=#{filter_path}",
                         "--metadata-file=#{file.path}", '-t', 'html', stdin_data: markdown)
        end
        expect(status.success?).to be(true)
        # 仕様 9.3 の形式（ファイル名:行番号: 種類: メッセージ）。行番号は元の入力ファイルのもの
        expect(err).to include('a.rmd:3: warning: 図の行には、画像だけを書いてください')
        expect(out).to include('説明')
        expect(out).not_to include('図1')
      end
    end

    # 表の書式（罫線の太さ・文字サイズなど）は、プリアンブルの命令で決まる。
    # ここでは、filter.lua が組む tabular の形を確認する。
    describe '表の組版（LaTeX）' do
      let(:three_rows) { "| 条件 | 結果 |\n|:---|---:|\n| A | 10 |\n| B | 20 |\n| C | 30 |\n" }

      it 'longtable ではなく tabular に組み、列の揃えと縦の罫線の命令を入れる' do
        latex = convert_with_pandoc("![t:結果]\n#{three_rows}", 'latex')
        expect(latex).not_to include('longtable')
        expect(latex).to include('\\begin{reportmdtablebox}')
        expect(latex).to include('{\\reportmdtablestyle')
        expect(latex).to include('\\begin{tabular}{!{\\reportmdvside}l!{\\reportmdvrule}r!{\\reportmdvside}}')
      end

      it '罫線の命令を、上・見出しの下・本文の行の間・下の順に置く' do
        latex = convert_with_pandoc("![t:結果]\n#{three_rows}", 'latex')
        rows = latex[/\\begin\{tabular\}.*?\n(.*)\n\\end\{tabular\}/m, 1].lines.map(&:strip)
        # 罫線は、本文の行の間だけ（3行なら2本）。見出しの行の後ろには見出しの下の線を置く
        expect(rows.map { |row| row[/\A\\reportmdrule\w+|\A\S+/] }).to eq(
          ['\\reportmdruletop', '\\multicolumn{1}{!{\\reportmdvside}c!{\\reportmdvrule}}{\\reportmdtablehead{条件}}',
           '\\reportmdruleheader', 'A', '\\reportmdrulerows', 'B', '\\reportmdrulerows', 'C', '\\reportmdrulebottom']
        )
      end

      it '見出しのセルは、既定では中央揃え（列の揃えを上書き）で、見出しの書式の命令で囲む' do
        latex = convert_with_pandoc("![t:結果]\n#{three_rows}", 'latex')
        expect(latex).to include('\\multicolumn{1}{!{\\reportmdvside}c!{\\reportmdvrule}}{\\reportmdtablehead{条件}}')
        expect(latex).to include('\\multicolumn{1}{c!{\\reportmdvside}}{\\reportmdtablehead{結果}}')
      end

      it 'header.align が column なら、見出しのセルも列の揃えに従う' do
        latex = convert_with_settings("![t:結果]\n#{three_rows}", 'latex', 'table_header_align' => 'column')
        expect(latex).to include('\\reportmdtablehead{条件} & \\reportmdtablehead{結果} \\\\')
      end

      it 'header.align が right なら、見出しのセルを右揃えにする' do
        latex = convert_with_settings("![t:結果]\n#{three_rows}", 'latex', 'table_header_align' => 'right')
        expect(latex).to include('\\multicolumn{1}{!{\\reportmdvside}r!{\\reportmdvrule}}{\\reportmdtablehead{条件}}')
      end

      it 'セルの中のインライン書式や数式が使える' do
        latex = convert_with_pandoc("![t]\n| a | b |\n|---|---|\n| **太字** | $x^2$ |\n", 'latex')
        expect(latex).to include('\\textbf{太字} & \\(x^2\\) \\\\')
      end

      it '横に結合したセルは \\multicolumn にし、結合した列の幅の合計で折り返す' do
        grid = "+-----+-----+\n| a   | b   |\n+=====+=====+\n| 結合      |\n+-----+-----+\n"
        latex = convert_with_pandoc("![t]\n#{grid}", 'latex')
        column = latex[/\\real\{([\d.]+)\}/, 1].to_f
        pattern = /#{Regexp.escape('\\multicolumn{2}{!{\\reportmdvside}>{\\raggedright\\arraybackslash}p{(\\linewidth - 4\\tabcolsep) * \\real{')}([\d.]+)#{Regexp.escape('}}!{\\reportmdvside}}{結合} \\\\')}/
        expect(latex).to match(pattern)
        expect(latex[pattern, 1].to_f).to be_within(0.001).of(column * 2)
      end

      it '列の幅が決まっている表（長い区切り行）は、折り返す p 列にする' do
        wide = "| 項目 | 説明 |\n|---|#{'-' * 80}|\n| 入力 | 長い説明 |\n"
        latex = convert_with_pandoc("![t]\n#{wide}", 'latex')
        expect(latex).to include('>{\\raggedright\\arraybackslash}p{(\\linewidth - 4\\tabcolsep) * \\real{')
      end

      it 'width が full なら、幅の決まっていない列を X 列にして tabularx で本文幅に広げる' do
        latex = convert_with_settings("![t:結果]\n#{three_rows}", 'latex', 'table_width' => 'full')
        expect(latex).to include('\\begin{tabularx}{\\linewidth}{!{\\reportmdvside}>{\\raggedright\\arraybackslash}X' \
                                 '!{\\reportmdvrule}>{\\raggedleft\\arraybackslash}X!{\\reportmdvside}}')
        expect(latex).to include('\\end{tabularx}')
      end

      it 'width が full で、すべての列の幅が決まっている表は、幅の合計を本文幅にそろえる' do
        grid = "+---+---+\n| a | b |\n+===+===+\n| 1 | 2 |\n+---+---+\n"
        latex = convert_with_settings("![t]\n#{grid}", 'latex', 'table_width' => 'full')
        widths = latex.scan(/\\real\{([\d.]+)\}/).flatten.map(&:to_f)
        expect(widths.length).to be >= 2
        expect(widths.first(2).sum).to be_within(0.001).of(1.0)
        expect(latex).not_to include('tabularx')
      end

      it '![t:...] のない表も同じ形で組み、番号は付けない' do
        latex = convert_with_pandoc(three_rows, 'latex')
        expect(latex).to include('\\begin{tabular}')
        expect(latex).not_to include('表1')
      end

      it '![t:...] のない表に Pandoc 標準のキャプションがあれば、番号なしでそのまま使う' do
        latex = convert_with_pandoc("#{three_rows}\n: 標準のキャプション\n", 'latex')
        expect(latex).to include('標準のキャプション')
        expect(latex).not_to include('表1')
        expect(latex.index('標準のキャプション')).to be < latex.index('\\begin{tabular}')
      end

      it 'HTML では、表をそのまま残す（キャプションだけ付ける）' do
        html = convert_with_pandoc("![t:結果]\n#{three_rows}", 'html')
        expect(html).to include('<table')
        expect(html).not_to include('reportmdrule')
      end
    end

    describe '図表の参照（@名前）' do
      let(:doc) do
        "![f:構成](a.png){#sys}\n\n![f:二つ目](b.png)\n\n![t:結果]{#result}\n#{table}\n" \
          "![f:三つ目](c.png){#third width=50%}\n\n"
      end

      def text_of(rmd, settings = {})
        convert_with_settings(rmd, 'plain', settings)
      end

      it '@名前 を、図は「図{番号}」、表は「表{番号}」に置き換える' do
        out = text_of("#{doc}@sys と @result と @third を参照。\n")
        expect(out).to include('図1 と 表1 と 図3 を参照。')
      end

      it '後ろにある図表も参照できる' do
        out = text_of("@third を見よ。\n\n#{doc}")
        expect(out).to include('図3 を見よ。')
      end

      it '名前の直後に日本語が続いても、名前の部分だけを置き換える' do
        out = text_of("#{doc}@sysに示すように、@resultの値は\n")
        expect(out).to include('図1に示すように、表1の値は')
      end

      it '@{名前} の形でも参照できる' do
        out = text_of("#{doc}@{result}に示す。\n")
        expect(out).to include('表1に示す。')
      end

      it '[@a; @b] のように並べると、「、」でつなぐ' do
        out = text_of("#{doc}[@sys; @result] を参照。\n")
        expect(out).to include('図1、表1 を参照。')
      end

      it 'ラベルの設定（figure_label / table_label）に従う' do
        out = text_of("#{doc}@sys と @result\n", 'figure_label' => 'Fig.', 'table_label' => 'Table')
        expect(out).to include('Fig.1 と Table1')
      end

      it '番号の付かない図（画像以外の文字がある図の行）は、図の番号を数えない' do
        out = text_of("![f:a](a.png){#a} 説明\n\n![f:b](b.png){#b}\n\n@b\n")
        expect(out).to include('図1')
        expect(out).not_to include('図2')
      end

      it '見つからない名前は、ファイル名つきで警告して、@名前 のまま残す' do
        markdown = Reportmd::Preprocessor.new("#{doc}@nothing を参照。\n").call.text
        out, err, status = Tempfile.create(['settings', '.json']) do |file|
          file.write(JSON.generate('reportmd' => { 'source' => 'a.rmd' }))
          file.flush
          Open3.capture3('pandoc', '-f', 'markdown-raw_html-raw_tex', "--lua-filter=#{filter_path}",
                         "--metadata-file=#{file.path}", '-t', 'plain', stdin_data: markdown)
        end
        expect(status.success?).to be(true)
        expect(err).to include('a.rmd: warning: 参照先の図表・数式が見つかりません: @nothing')
        expect(out).to include('@nothing を参照。')
      end

      it 'コードの中の @名前 や、メールアドレスは置き換えない' do
        out = text_of("#{doc}`@sys` と a@sys.com\n")
        expect(out).to include('@sys')
        expect(out).to include('a@sys.com')
        expect(out).not_to match(/図1 と/)
      end

      it 'LaTeX でも置き換える' do
        latex = convert_with_pandoc("#{doc}@sys に示す。\n", 'latex')
        expect(latex).to include('図1 に示す。')
      end
    end

    describe '数式の番号' do
      let(:doc) do
        "次の式\n$$\nK = \\frac{1}{2} m v^2 % 運動エネルギー\n$$ {#kinetic}\nとなる。\n\n" \
          "$$ a + b $$ {-}\n\n$$ E = mc^2 $$ {#energy}\n\n"
      end

      it '独立した数式に、通し番号を \tag で付ける（番号なしの {-} は数えない）' do
        latex = convert_with_pandoc(doc, 'latex')
        expect(latex).to include("\\[\nK = \\frac{1}{2} m v^2 % 運動エネルギー\n\\tag{1}\\]")
        expect(latex).to include('\[ a + b \]')
        expect(latex).to include("\\[ E = mc^2\n\\tag{2}\\]")
        expect(latex).not_to include('reportmd-equation')
      end

      it '数式の前後の文は、同じ段落のまま' do
        latex = convert_with_pandoc(doc, 'latex')
        expect(latex).to match(/次の式 \\\[.*\\tag\{1\}\\\] となる。/m)
      end

      it '@名前 を「式(番号)」に置き換え、ラベルは equation_label に従う' do
        out = convert_with_settings("#{doc}@kineticと @energy\n", 'plain', {})
        expect(out).to include('式(1)と 式(2)')
        out = convert_with_settings("#{doc}@energy\n", 'plain', 'equation_label' => 'Eq.')
        expect(out).to include('Eq.(2)')
      end

      it '番号は文書の順に付ける（強調の中や脚注の数式も数える）' do
        rmd = "*強調 $$a$$* と $$b$$ 注[^1]\n$$c$$ {#c}\n\n[^1]: $$n$$\n\n@c\n"
        latex = convert_with_pandoc(rmd, 'latex')
        expect(latex.scan(/\\\[(\w)\n\s*\\tag\{(\d)\}/)).to eq([%w[a 1], %w[b 2], %w[n 3], %w[c 4]])
      end

      it '図表の番号とは別に数える' do
        out = convert_with_settings("![f:図](a.png){#fig}\n\n#{doc}@fig @energy\n", 'plain', {})
        expect(out).to include('図1 式(2)')
      end

      it 'equation_numbering が false なら番号を付けず、名前を付けた数式は警告する' do
        latex = convert_with_settings(doc, 'latex', 'equation_numbering' => false)
        expect(latex).not_to include('\tag')
        markdown = Reportmd::Preprocessor.new(doc).call.text
        _out, err, = Tempfile.create(['settings', '.json']) do |file|
          file.write(JSON.generate('reportmd' => { 'source' => 'a.rmd', 'equation_numbering' => false }))
          file.flush
          Open3.capture3('pandoc', '-f', 'markdown-raw_html-raw_tex', "--lua-filter=#{filter_path}",
                         "--metadata-file=#{file.path}", '-t', 'latex', stdin_data: markdown)
        end
        expect(err).to include('a.rmd:4: warning: 数式に番号を付けない設定')
      end

      it 'インラインの数式（$...$）には番号を付けない' do
        latex = convert_with_pandoc("本文 $x^2$ の式\n", 'latex')
        expect(latex).to include('\(x^2\)')
        expect(latex).not_to include('\tag')
      end
    end
  end

  describe '2スペースの字下げ' do
    it 'LaTeX では、1文字分の字下げに変換する（印は残らない）' do
      out = convert_with_pandoc("  段落です\n", 'latex')
      expect(out).to include('\\noindent\\hspace*{\\reportmdchar}段落です')
      expect(out).not_to include('reportmd-indent')
    end

    it 'LaTeX 以外では、印を取り除くだけにする' do
      out = convert_with_pandoc("  段落です\n", 'plain')
      expect(out.strip).to eq('段落です')
    end

    it '印のない段落は、そのまま' do
      expect(convert_with_pandoc("段落です\n", 'latex').strip).to eq('段落です')
    end
  end
end
