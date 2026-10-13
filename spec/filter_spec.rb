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
        expect(latex.index('表1 実験結果')).to be < latex.index('\\begin{longtable}')
        expect(latex).to include('\\nopagebreak')
      end

      it 'table_position が bottom なら、表のキャプションを表の下に置く' do
        latex = convert_with_settings("![t:実験結果]\n#{table}", 'latex', 'table_position' => 'bottom')
        expect(latex.index('\\end{longtable}')).to be < latex.index('表1 実験結果')
      end

      it '画像の属性（width）が \\includegraphics に渡る' do
        latex = convert_with_pandoc("![f:図](a.png){width=50%}\n", 'latex')
        expect(latex).to match(/\\includegraphics\[[^\]]*width=0\.5\\textwidth/)
      end
    end

    describe '想定外の入力' do
      it '図の行に画像以外の文字があれば、警告して番号を付けず、内容は残す' do
        markdown = Reportmd::Preprocessor.new("![f:図](a.png) 説明\n").call.text
        out, err, status = Open3.capture3('pandoc', '-f', 'markdown-raw_html-raw_tex',
                                          "--lua-filter=#{filter_path}", '-t', 'html', stdin_data: markdown)
        expect(status.success?).to be(true)
        expect(err).to include('warning')
        expect(out).to include('説明')
        expect(out).not_to include('図1')
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
