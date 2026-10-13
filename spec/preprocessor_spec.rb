# frozen_string_literal: true

require_relative '../lib/reportmd/preprocessor'

RSpec.describe Reportmd::Preprocessor do
  def run(source)
    described_class.new(source).call
  end

  def convert(source)
    run(source).text
  end

  PAGEBREAK = "::: {.reportmd-pagebreak}\n:::"

  describe '前準備' do
    it '変換対象のない文書は、そのまま出力する' do
      source = "# 見出し\n\n本文です。\n\n- 項目\n"
      expect(convert(source)).to eq(source)
    end

    it 'CRLF を LF に統一する' do
      expect(convert("a\r\nb\r\n")).to eq("a\nb\n")
    end

    it 'BOM を取り除く' do
      expect(convert("\uFEFFa\n")).to eq("a\n")
    end

    it '空の入力は空文字を返す' do
      expect(convert('')).to eq('')
    end

    it 'UTF-8 として不正な入力はエラーにする' do
      expect { run("\xFF\xFE".b) }.to raise_error(Reportmd::PreprocessError, /UTF-8/)
    end
  end

  describe '改ページ（^）' do
    it '行だけの ^ を改ページに変換する' do
      expect(convert("前\n\n^\n\n後\n")).to eq("前\n\n#{PAGEBREAK}\n\n後\n")
    end

    it '前後に空行がなくても、空行を補って変換する' do
      expect(convert("前\n^\n後\n")).to eq("前\n\n#{PAGEBREAK}\n\n後\n")
    end

    it 'ファイルの先頭・末尾の ^ も変換する' do
      expect(convert("^\n本文\n^\n")).to eq("#{PAGEBREAK}\n\n本文\n\n#{PAGEBREAK}\n")
    end

    it '行末の空白は許容する' do
      expect(convert("a\n\n^  \n\nb\n")).to eq("a\n\n#{PAGEBREAK}\n\nb\n")
    end

    it '連続した ^ はそれぞれ改ページにする' do
      expect(convert("a\n\n^\n^\n\nb\n")).to eq("a\n\n#{PAGEBREAK}\n\n#{PAGEBREAK}\n\nb\n")
    end

    it '文章中の ^ は変換しない' do
      source = "x^2 と 2^n\n\na ^ b\n\n^上付き^\n\n  ^\n\n    ^\n"
      expect(convert(source)).to eq(source)
    end
  end

  describe '保護領域：コードブロック' do
    it 'バッククォートのコードブロック内の ^ は変換しない' do
      source = "```\n^\n```\n"
      expect(convert(source)).to eq(source)
    end

    it 'チルダのコードブロック内の ^ は変換しない' do
      source = "~~~\n^\n~~~\n"
      expect(convert(source)).to eq(source)
    end

    it '情報文字列（言語名）つきのフェンスも保護する' do
      source = "```ruby\n^\n```\n"
      expect(convert(source)).to eq(source)
    end

    it 'コードブロックを閉じたあとの ^ は変換する' do
      expect(convert("```\nコード\n```\n\n^\n")).to eq("```\nコード\n```\n\n#{PAGEBREAK}\n")
    end

    it '長いフェンスの内側にある短いフェンスでは閉じない' do
      source = "````\n```\n^\n```\n````\n"
      expect(convert(source)).to eq(source)
    end

    it '種類の違うフェンスでは閉じない' do
      source = "```\n~~~\n^\n```\n"
      expect(convert(source)).to eq(source)
    end

    it '開きフェンスより短いフェンスでは閉じない' do
      source = "````\n^\n```\n^\n````\n"
      expect(convert(source)).to eq(source)
    end

    it '情報文字列に ` を含む行はフェンスとみなさない' do
      expect(convert("``` a`b\n^\n")).to eq("``` a`b\n\n#{PAGEBREAK}\n")
    end

    it 'リスト内のようにインデントされたフェンスも保護する' do
      source = "- 項目\n\n    ```\n    ^\n    ```\n"
      expect(convert(source)).to eq(source)
    end

    it '閉じフェンスがなければ、末尾までコードとして扱い警告する' do
      result = run("```\n^\nまだコード\n")
      expect(result.text).to eq("```\n^\nまだコード\n")
      expect(result.warnings.map(&:line)).to eq([1])
      expect(result.warnings.first.message).to include('コードブロック')
    end
  end

  describe '保護領域：数式ブロック' do
    it '数式ブロック内の ^ 単独行は変換しない' do
      source = "$$\n^\n$$\n"
      expect(convert(source)).to eq(source)
    end

    it '開始行に式がある数式ブロックも保護する' do
      source = "$$ x = 1\n^\ny = 2 $$\n"
      expect(convert(source)).to eq(source)
    end

    it '1行で完結する $$ ... $$ は、後続の行に影響しない' do
      expect(convert("$$x^2$$\n\n^\n")).to eq("$$x^2$$\n\n#{PAGEBREAK}\n")
    end

    it '数式ブロックを閉じたあとの ^ は変換する' do
      expect(convert("$$\nx\n$$\n\n^\n")).to eq("$$\nx\n$$\n\n#{PAGEBREAK}\n")
    end

    it '閉じられていない数式ブロックは、開始行つきでエラーにする' do
      expect { run("本文\n\n$$\nx\n") }.to raise_error(Reportmd::PreprocessError) { |e|
        expect(e.line).to eq(3)
        expect(e.message).to include('数式ブロック')
      }
    end
  end

  describe '保護領域：YAMLフロントマター' do
    it 'フロントマター内の ^ は変換しない' do
      source = "---\ntitle: a\n^\n---\n\n本文\n"
      expect(convert(source)).to eq(source)
    end

    it '... で閉じるフロントマターも保護する' do
      source = "---\ntitle: a\n^\n...\n"
      expect(convert(source)).to eq(source)
    end

    it 'フロントマターのあとの ^ は変換する' do
      expect(convert("---\ntitle: a\n---\n\n^\n")).to eq("---\ntitle: a\n---\n\n#{PAGEBREAK}\n")
    end

    it '閉じられていないフロントマターはエラーにする' do
      expect { run("---\ntitle: a\n\n本文\n") }.to raise_error(Reportmd::PreprocessError) { |e|
        expect(e.line).to eq(1)
        expect(e.message).to include('フロントマター')
      }
    end

    it '先頭の --- の次が空行なら、水平線として扱いエラーにしない' do
      expect(convert("---\n\n^\n")).to eq("---\n\n#{PAGEBREAK}\n")
    end

    it 'ファイル先頭以外の --- はフロントマターとして扱わない' do
      source = "本文\n\n---\ntitle: a\n---\n"
      expect(convert(source)).to eq(source)
    end
  end
end