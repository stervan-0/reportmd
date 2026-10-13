# frozen_string_literal: true

require_relative '../lib/reportmd/preprocessor'

RSpec.describe Reportmd::Preprocessor do
  def run(source)
    described_class.new(source).call
  end

  def convert(source)
    run(source).text
  end

  # 図のブロックの開始行。line は元の行番号（filter.lua の警告に使う）
  def figure(line = 1)
    "::: {.reportmd-figure line=\"#{line}\"}"
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
      source = "x^2 と 2^n\n\na ^ b\n\n^上付き^\n\n    ^\n"
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

  describe '数式の名前と番号なし（$$ {#名前} / $$ {-}）' do
    it '閉じの $$ の後ろの {#名前} を、行番号つきの目印のスパンにする' do
      expect(convert("$$\nE = mc^2\n$$ {#energy}\n"))
        .to eq("$$\nE = mc^2\n$$[]{.reportmd-equation #energy line=\"3\"}\n")
    end

    it '{-} は、番号なしの目印にする' do
      expect(convert("$$\nx\n$${-}\n"))
        .to eq("$$\nx\n$$[]{.reportmd-equation .unnumbered line=\"3\"}\n")
    end

    it '1行の数式や、閉じの行に式がある数式にも付けられる' do
      expect(convert("$$ x = 1 $$ {#one}\n"))
        .to eq("$$ x = 1 $$[]{.reportmd-equation #one line=\"1\"}\n")
      expect(convert("$$\nx = 1\ny = 2 $$ {#two}\n"))
        .to eq("$$\nx = 1\ny = 2 $$[]{.reportmd-equation #two line=\"3\"}\n")
    end

    it '数式の中身は変更しない' do
      source = "$$\n{#a} ^\n--> x\n$$\n"
      expect(convert(source)).to eq(source)
    end

    it '{#名前} と {-} 以外の属性は、行番号つきでエラーにする' do
      expect { run("$$\nx\n$$ {width=50%}\n") }.to raise_error(Reportmd::PreprocessError) { |e|
        expect(e.line).to eq(3)
        expect(e.message).to include('{#名前}', '{-}')
      }
    end

    it '図表と同じ名前を使ったら警告する' do
      result = run("![f:図](a.png){#same}\n\n$$\nx\n$$ {#same}\n")
      expect(result.warnings.map(&:line)).to eq([5])
      expect(result.warnings.first.message).to include('#same', '1 行目')
    end

    it 'コードブロックの中の $$ {#名前} は変換しない' do
      source = "```\n$$ x $$ {#a}\n```\n"
      expect(convert(source)).to eq(source)
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

    describe '対応外のキー' do
      it 'title・author 以外の最上位のキーは、行番号つきで警告する（本文はそのまま）' do
        source = "---\ntitle: a\nlang: en\n\"geometry\": x\nauthor: b\n---\n\n本文\n"
        result = run(source)
        expect(result.text).to eq(source)
        expect(result.warnings.map(&:line)).to eq([3, 4])
        expect(result.warnings.map(&:message)).to all(include('対応外のフロントマターのキー'))
        expect(result.warnings[0].message).to include('lang')
        expect(result.warnings[1].message).to include('geometry')
      end

      it '値の中の行（字下げ・リスト項目）やコメントは、キーとして扱わない' do
        source = "---\nauthor:\n  - 山田\n  - name: 佐藤\n# メモ\ntitle: >\n  長い: タイトル\n---\n"
        expect(run(source).warnings).to eq([])
      end

      it 'フロントマターの外の「キー:」の行は警告しない' do
        expect(run("本文\n\nlang: en\n").warnings).to eq([])
      end
    end
  end

  describe '右揃え（-->）と中央揃え（<->）' do
    RIGHT  = '::: {.reportmd-right}'
    CENTER = '::: {.reportmd-center}'

    it '--> の行を右揃えのブロックに変換する' do
      expect(convert("前\n\n--> 2026年10月12日\n\n後\n"))
        .to eq("前\n\n#{RIGHT}\n2026年10月12日\n:::\n\n後\n")
    end

    it '<-> の行を中央揃えのブロックに変換する' do
      expect(convert("<-> 実験レポート\n")).to eq("#{CENTER}\n実験レポート\n:::\n")
    end

    it '連続する行をひとつのブロックにまとめ、行ごとに改行する' do
      expect(convert("--> 2026年10月12日\n--> 大阪工業大学\n--> 山田 太郎\n"))
        .to eq("#{RIGHT}\n2026年10月12日\\\n大阪工業大学\\\n山田 太郎\n:::\n")
    end

    it '空行で別のブロックに分かれる' do
      expect(convert("--> a\n\n--> b\n"))
        .to eq("#{RIGHT}\na\n:::\n\n#{RIGHT}\nb\n:::\n")
    end

    it '右揃えと中央揃えが隣り合う場合は、別のブロックにする' do
      expect(convert("--> a\n<-> b\n"))
        .to eq("#{RIGHT}\na\n:::\n\n#{CENTER}\nb\n:::\n")
    end

    it '前の段落に空行なしで続いても、新しいブロックを始める' do
      expect(convert("本文\n--> 右\n")).to eq("本文\n\n#{RIGHT}\n右\n:::\n")
    end

    it '内容が空の行は読み飛ばし、前後の行は同じブロックとして続ける' do
      expect(convert("--> a\n-->\n-->   \n--> b\n"))
        .to eq("#{RIGHT}\na\\\nb\n:::\n")
    end

    it '内容が空の行だけなら、その行を何も出力しない（前後の空行はそのまま残る）' do
      expect(convert("前\n\n-->\n\n後\n")).to eq("前\n\n\n後\n")
    end

    it '内容は Markdown のまま渡す（インライン書式）' do
      expect(convert("--> **太字**と$x^2$\n")).to eq("#{RIGHT}\n**太字**と$x^2$\n:::\n")
    end

    it '内容の末尾の空白は取り除く' do
      expect(convert("--> a  \n")).to eq("#{RIGHT}\na\n:::\n")
    end

    it '日付が番号付きリストと解釈されないように、ピリオドをエスケープする' do
      expect(convert("--> 2026. 10. 12\n")).to eq("#{RIGHT}\n2026\\. 10. 12\n:::\n")
    end

    it '文章中の --> や、記号の直後に文字が続く行は変換しない' do
      source = "a --> b\n\n-->text\n\n---> x\n\n    --> コード\n"
      expect(convert(source)).to eq(source)
    end

    it 'コードブロック・数式ブロック・フロントマター内の --> は変換しない' do
      source = "```\n--> a\n```\n\n$$\n<-> b\n$$\n"
      expect(convert(source)).to eq(source)
      fm = "---\ntitle: a\n--> b\n---\n"
      expect(convert(fm)).to eq(fm)
    end

    it 'コードブロックの直前の揃え行も、ブロックとして出力する' do
      expect(convert("--> a\n```\ncode\n```\n"))
        .to eq("#{RIGHT}\na\n:::\n\n```\ncode\n```\n")
    end

    it 'ファイル末尾の揃え行も出力する（余分な空行は残さない）' do
      expect(convert("本文\n\n<-> 末尾")).to eq("本文\n\n#{CENTER}\n末尾\n:::\n")
    end

    describe '引用の内側' do
      it '接頭辞を保ち、空行は > にする' do
        expect(convert("> 引用\n> --> 右\n> --> 2行目\n"))
          .to eq("> 引用\n>\n> #{RIGHT}\n> 右\\\n> 2行目\n> :::\n")
      end

      it '引用の接頭辞が違う行とは、別のブロックにする' do
        expect(convert("> --> a\n--> b\n"))
          .to eq("> #{RIGHT}\n> a\n> :::\n>\n\n#{RIGHT}\nb\n:::\n")
      end
    end

    describe 'リストの内側' do
      it 'リスト記号の行に Div を置き、続く行を記号の幅だけ字下げする' do
        expect(convert("- 項目A\n- --> 右の項目\n- 項目C\n"))
          .to eq("- 項目A\n- #{RIGHT}\n  右の項目\n  :::\n- 項目C\n")
      end

      it '番号付きリストにも対応する' do
        expect(convert("1. <-> 中央\n")).to eq("1. #{CENTER}\n   中央\n   :::\n")
      end

      it 'リスト記号ごとに別の項目として出力する' do
        expect(convert("- --> a\n- --> b\n"))
          .to eq("- #{RIGHT}\n  a\n  :::\n- #{RIGHT}\n  b\n  :::\n")
      end

      it '内容が空のリスト項目は読み飛ばす' do
        expect(convert("- a\n- -->\n- b\n")).to eq("- a\n- b\n")
      end
    end
  end

  describe '番号付き見出し（#1〜#3）' do
    NUM = '{.reportmd-num}'

    it '#1〜#3 を、クラスつきの Pandoc の見出しに変換する' do
      expect(convert("#1 はじめに\n\n#2 背景\n\n#3 詳細\n"))
        .to eq("# はじめに #{NUM}\n\n## 背景 #{NUM}\n\n### 詳細 #{NUM}\n")
    end

    it '前後に空行がなくても、空行を補って見出しにする' do
      expect(convert("本文\n#1 はじめに\n本文2\n"))
        .to eq("本文\n\n# はじめに #{NUM}\n\n本文2\n")
    end

    it 'ファイルの先頭・末尾の見出しも変換する（末尾に余分な空行を残さない）' do
      expect(convert("#1 先頭\n本文\n#1 末尾")).to eq("# 先頭 #{NUM}\n\n本文\n\n# 末尾 #{NUM}\n")
    end

    it 'スペースが複数あっても、見出し文字列の前を詰める' do
      expect(convert("#1   はじめに\n")).to eq("# はじめに #{NUM}\n")
    end

    it '見出し文字列の末尾の空白は取り除く' do
      expect(convert("#1 はじめに  \n")).to eq("# はじめに #{NUM}\n")
    end

    it '見出し文字列の中のインライン書式や数式は、そのまま渡す' do
      expect(convert("#2 **太字**と$x^2$\n")).to eq("## **太字**と$x^2$ #{NUM}\n")
    end

    it '標準の # 見出しは、そのまま通す（番号なしの見出し）' do
      source = "# 番号なし\n\n## これも番号なし\n\n### これも\n"
      expect(convert(source)).to eq(source)
    end

    it '#1 の行に連続する見出しは、それぞれ見出しになる' do
      expect(convert("#1 a\n#2 b\n"))
        .to eq("# a #{NUM}\n\n## b #{NUM}\n")
    end

    describe '見出しにならない行' do
      it '#4 以降（と #0）は、警告して通常の段落として通す' do
        result = run("#4 未対応\n\n#0 x\n\n#9 y\n")
        expect(result.text).to eq("#4 未対応\n\n#0 x\n\n#9 y\n")
        expect(result.warnings.map(&:line)).to eq([1, 3, 5])
        expect(result.warnings.first.message).to include('#4')
      end

      it '見出し文字列が空なら、警告して通常の段落として通す' do
        result = run("#1\n\n#2   \n")
        expect(result.text).to eq("#1\n\n#2   \n")
        expect(result.warnings.map(&:line)).to eq([1, 3])
        expect(result.warnings.first.message).to include('見出しの文字列がありません')
      end

      it '#12 のように数字が2桁以上の行や、#タグ のような行は、警告せず通す' do
        source = "#12 foo\n\n#タグ\n\n#1つ目\n"
        result = run(source)
        expect(result.text).to eq(source)
        expect(result.warnings).to eq([])
      end

      it '行頭以外（字下げ・リスト・引用の内側）の #1 は変換しない' do
        source = " #1 字下げ\n\n- #1 リスト\n\n> #1 引用\n"
        result = run(source)
        expect(result.text).to eq(source)
        expect(result.warnings).to eq([])
      end

      it 'コードブロック・数式ブロック・フロントマター内の #1 は変換しない' do
        source = "```\n#1 コード\n```\n\n$$\n#1 数式\n$$\n"
        expect(convert(source)).to eq(source)
        front = "---\ntitle: a\n#1 b\n---\n"
        expect(convert(front)).to eq(front)
      end
    end

    describe 'レベルの飛び' do
      it '#1 の次に #3 が来たら警告するが、見出しにはする' do
        result = run("#1 a\n\n#3 b\n")
        expect(result.text).to eq("# a #{NUM}\n\n### b #{NUM}\n")
        expect(result.warnings.map(&:line)).to eq([3])
        expect(result.warnings.first.message).to include('#1 の次に #3')
      end

      it '最初の見出しが #1 でなければ警告する' do
        result = run("#2 a\n")
        expect(result.warnings.map(&:line)).to eq([1])
        expect(result.warnings.first.message).to include('見出しがない状態')
      end

      it '上のレベルに戻るのは、飛びではない' do
        expect(run("#1 a\n#2 b\n#3 c\n#1 d\n#2 e\n").warnings).to eq([])
      end

      it '同じレベルが続くのも、飛びではない' do
        expect(run("#1 a\n#1 b\n#2 c\n#2 d\n").warnings).to eq([])
      end
    end

    it '右揃えのブロックの直後の見出しも、正しく出力する' do
      expect(convert("--> 右\n#1 はじめに\n"))
        .to eq("::: {.reportmd-right}\n右\n:::\n\n# はじめに #{NUM}\n")
    end

    it '見出しの後の改ページも、正しく出力する' do
      expect(convert("#1 はじめに\n^\n本文\n"))
        .to eq("# はじめに #{NUM}\n\n::: {.reportmd-pagebreak}\n:::\n\n本文\n")
    end
  end

  describe '図（![f:...]）' do

    it '![f:タイトル](画像) を、図のブロックに変換し、画像の代替テキストをタイトルにする' do
      expect(convert("![f:システム構成図](images/a.png)\n"))
        .to eq("#{figure}\n![システム構成図](images/a.png)\n:::\n")
    end

    it '画像の属性（{width=50%} など）はそのまま残す' do
      expect(convert("![f:図](a.png){width=50%}\n"))
        .to eq("#{figure}\n![図](a.png){width=50%}\n:::\n")
    end

    it 'タイトルが空（![f] / ![f:]）なら、代替テキストを空にする' do
      expect(convert("![f](a.png)\n\n![f:](b.png)\n"))
        .to eq("#{figure}\n![](a.png)\n:::\n\n#{figure(3)}\n![](b.png)\n:::\n")
    end

    it 'タイトルの中のインライン書式やコロンは、そのまま渡す' do
      expect(convert("![f:**太字**と$x^2$、比率 1:2](a.png)\n"))
        .to eq("#{figure}\n![**太字**と$x^2$、比率 1:2](a.png)\n:::\n")
    end

    it '前後に空行がなくても、空行を補って変換する' do
      expect(convert("本文\n![f:図](a.png)\n続き\n"))
        .to eq("本文\n\n#{figure(2)}\n![図](a.png)\n:::\n\n続き\n")
    end

    it '行末の空白は取り除く' do
      expect(convert("![f:図](a.png)  \n")).to eq("#{figure}\n![図](a.png)\n:::\n")
    end

    it '画像のパスがなければ、行番号つきでエラーにする' do
      expect { run("本文\n\n![f:パスなし]\n") }.to raise_error(Reportmd::PreprocessError) { |e|
        expect(e.line).to eq(3)
        expect(e.message).to include('画像のパス')
      }
    end

    it '全角コロンは図表として扱わず、警告してそのまま通す' do
      result = run("![f：全角](a.png)\n")
      expect(result.text).to eq("![f：全角](a.png)\n")
      expect(result.warnings.map(&:line)).to eq([1])
      expect(result.warnings.first.message).to include('半角コロン')
    end

    it '通常の画像（f: で始まらない）や、行の途中・リスト・引用の中の ![f: は変換しない' do
      source = "![図](a.png)\n\n本文 ![f:行中](a.png)\n\n- ![f:リスト](a.png)\n\n> ![f:引用](a.png)\n\n![fig:x](a.png)\n"
      result = run(source)
      expect(result.text).to eq(source)
      expect(result.warnings).to eq([])
    end

    it 'コードブロック・数式ブロック・フロントマター内の記法は変換しない' do
      source = "```\n![f:図](a.png)\n![t:表]\n```\n\n$$\n![f:図](a.png)\n$$\n"
      expect(convert(source)).to eq(source)
      front = "---\ntitle: a\n![f:図](a.png)\n---\n"
      expect(convert(front)).to eq(front)
    end

    it '右揃えのブロックの直後の図も、正しく出力する' do
      expect(convert("--> 右\n![f:図](a.png)\n"))
        .to eq("::: {.reportmd-right}\n右\n:::\n\n#{figure(2)}\n![図](a.png)\n:::\n")
    end
  end

  describe '表の見出し（![t:...]）' do
    CAPTION = '::: {.reportmd-table-caption}'
    TABLE = "| 条件 | 結果 |\n|---|---|\n| A | 10 |\n"

    it '![t:タイトル] を、表の見出しのブロックに変換し、表はそのまま通す' do
      expect(convert("![t:実験結果]\n#{TABLE}"))
        .to eq("#{CAPTION}\n実験結果\n:::\n\n#{TABLE}")
    end

    it '見出し行と表の間に、空行が1つあってもよい' do
      expect(convert("![t:実験結果]\n\n#{TABLE}"))
        .to eq("#{CAPTION}\n実験結果\n:::\n\n#{TABLE}")
    end

    it 'タイトルが空（![t] / ![t:]）なら、中身のない見出しブロックにする' do
      expect(convert("![t]\n#{TABLE}\n![t:]\n#{TABLE}"))
        .to eq("#{CAPTION}\n:::\n\n#{TABLE}\n#{CAPTION}\n:::\n\n#{TABLE}")
    end

    it 'タイトルの中のインライン書式は、そのまま渡す' do
      expect(convert("![t:**太字**と$x^2$]\n#{TABLE}"))
        .to eq("#{CAPTION}\n**太字**と$x^2$\n:::\n\n#{TABLE}")
    end

    it '行末の空白があっても、見出しとして扱う' do
      expect(convert("![t:実験結果]  \n#{TABLE}"))
        .to eq("#{CAPTION}\n実験結果\n:::\n\n#{TABLE}")
    end

    it '先頭の | がないパイプ表の前でも使える' do
      table = "条件 | 結果\n-----|-----\nA | 10\n"
      expect(convert("![t:表]\n#{table}")).to eq("#{CAPTION}\n表\n:::\n\n#{table}")
    end

    it 'グリッド表の前でも使える' do
      table = "+---+---+\n| a | b |\n+---+---+\n"
      expect(convert("![t:表]\n#{table}")).to eq("#{CAPTION}\n表\n:::\n\n#{table}")
    end

    it '単純な表（ハイフンの区切り行）の前でも使える' do
      table = "条件  結果\n----  ----\nA     10\n"
      expect(convert("![t:表]\n#{table}")).to eq("#{CAPTION}\n表\n:::\n\n#{table}")
    end

    it '直後に表がなければ、見出し行の行番号つきでエラーにする' do
      expect { run("本文\n\n![t:なし]\n\n本文\n") }.to raise_error(Reportmd::PreprocessError) { |e|
        expect(e.line).to eq(3)
        expect(e.message).to include('直後に表がありません')
      }
    end

    it '空行が2つ以上あれば、エラーにする' do
      expect { run("![t:x]\n\n\n#{TABLE}") }
        .to raise_error(Reportmd::PreprocessError, /直後に表がありません/)
    end

    it 'ファイルの末尾にある見出し行は、エラーにする' do
      expect { run("![t:x]") }.to raise_error(Reportmd::PreprocessError, /直後に表がありません/)
    end

    it '後ろに (...) がある行は、表の見出しではないのでエラーにして、図の記法を案内する' do
      expect { run("![t:x](a.png)\n") }.to raise_error(Reportmd::PreprocessError) { |e|
        expect(e.line).to eq(1)
        expect(e.message).to include('![f:')
      }
    end

    it '後ろに {#名前} 以外の属性がある行もエラーにする' do
      expect { run("![t:x]{width=50%}\n#{TABLE}") }.to raise_error(Reportmd::PreprocessError) { |e|
        expect(e.message).to include('{#名前}')
      }
    end

    it '全角コロンは表の見出しとして扱わず、警告してそのまま通す' do
      result = run("![t：全角]\n#{TABLE}")
      expect(result.text).to eq("![t：全角]\n#{TABLE}")
      expect(result.warnings.map(&:line)).to eq([1])
    end

    it '図と表が混ざっていても、それぞれ変換する' do
      expect(convert("![f:図](a.png)\n\n![t:表]\n#{TABLE}"))
        .to eq("#{figure}\n![図](a.png)\n:::\n\n#{CAPTION}\n表\n:::\n\n#{TABLE}")
    end
  end

  describe '図表の参照用の名前（{#名前}）' do
    it '![t:タイトル]{#名前} の名前を、表の見出しのブロックの ID にする' do
      expect(convert("![t:実験結果]{#result}\n#{TABLE}"))
        .to eq("::: {.reportmd-table-caption #result}\n実験結果\n:::\n\n#{TABLE}")
    end

    it 'タイトルが空の表にも名前を付けられる' do
      expect(convert("![t]{#result}\n#{TABLE}"))
        .to eq("::: {.reportmd-table-caption #result}\n:::\n\n#{TABLE}")
    end

    it '図の {#名前} は、画像の属性としてそのまま残す' do
      expect(convert("![f:図](a.png){#sys width=50%}\n"))
        .to eq("#{figure}\n![図](a.png){#sys width=50%}\n:::\n")
    end

    it '同じ名前を2回使ったら、2回目の行番号つきで警告する（図と表の間でも）' do
      result = run("![f:図](a.png){width=50% #same}\n\n![t:表]{#same}\n#{TABLE}")
      expect(result.warnings.map(&:line)).to eq([3])
      expect(result.warnings.first.message).to include('#same', '1 行目')
    end

    it '名前の違う図表や、名前のない図表は警告しない' do
      result = run("![f:a](a.png){#a}\n\n![f:b](b.png)\n\n![t:表]{#c}\n#{TABLE}")
      expect(result.warnings).to eq([])
    end

    it '本文の @名前 は、前処理では変更しない（filter.lua が置き換える）' do
      source = "@sys に示す。[@a; @b]\n"
      expect(convert(source)).to eq(source)
    end
  end

  describe '2スペースの字下げ' do
    M = '[]{.reportmd-indent}'

    it '空行のあと・ファイル先頭の、2スペースで始まる段落に印を付ける' do
      expect(convert("  先頭\n\n  次の段落\n")).to eq("#{M}先頭\n\n#{M}次の段落\n")
    end

    it '段落の途中の行（継続行）は変換しない' do
      expect(convert("  a\n  b\n")).to eq("#{M}a\n  b\n")
    end

    it '見出し・改ページ・右揃えの直後の段落も字下げする' do
      source = "# 見出し\n  本文\n\n^\n  次\n\n--> 右\n\n  後\n"
      expect(convert(source)).to include("# 見出し\n#{M}本文")
      expect(convert(source)).to include("#{M}次").and include("#{M}後")
    end

    it '4スペース以上（コード）・1スペース・3スペースは変換しない' do
      source = "    コード\n\n 一つ\n\n   三つ\n"
      expect(convert(source)).to eq(source)
    end

    it 'リストの続き・引用の続きは変換しない' do
      source = "- 項目\n  続き\n\n  項目の2段落目\n\n> 引用\n  続き\n"
      expect(convert(source)).to eq(source)
    end

    it '2スペースのあとが、リスト・見出し・引用・表・水平線などの記法なら変換しない' do
      source = "  - 項目\n\n  # 見出し\n\n  > 引用\n\n  | a | b |\n\n  ---\n"
      expect(convert(source)).to eq(source)
    end

    it 'コードブロック・数式ブロックの中は変換しない' do
      source = "```\n  コード\n```\n\n$$\n  x\n$$\n"
      expect(convert(source)).to eq(source)
    end

    it '2スペースのあとが強調などの記号でも字下げする' do
      expect(convert("  *強調* 開始\n")).to eq("#{M}*強調* 開始\n")
    end
  end
end
