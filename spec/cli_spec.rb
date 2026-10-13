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
    fonts.include?('ipaexmincho') && fonts.include?('noto sans mono cjk jp')
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
      write_file('setting.json', '{ "heading": { "bold": false } }')
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
end