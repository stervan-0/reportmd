# frozen_string_literal: true

require 'open3'
require_relative '../lib/reportmd/preprocessor'

# 前処理 → Pandoc（filter.lua）を通した結果を確認するテスト。
# Pandoc が入っていない環境では、このファイルのテストを飛ばす。
RSpec.describe 'filter.lua' do
  filter_path = File.expand_path('../lib/reportmd/filter.lua', __dir__)

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
end