# frozen_string_literal: true

require 'optparse'
require_relative 'version'
require_relative 'config'
require_relative 'preprocessor'
require_relative 'builder'

module Reportmd
  # コマンドライン引数を処理し、PDF 生成を実行する。
  # 終了コード: 0 = 成功（警告があっても 0）、1 = 失敗
  class CLI
    USAGE = <<~TEXT
      使い方:
        reportmd build INPUT.rmd [-o OUTPUT.pdf] [-c setting.json] [--keep-temp]
        reportmd --version
        reportmd --help

      オプション:
        -o, --output FILE   出力する PDF のパス（省略時は入力ファイルと同じ場所）
        -c, --config FILE   設定ファイルのパス
            --keep-temp     一時ファイルを残す（デバッグ用）
        -v, --version       バージョンを表示
        -h, --help          このヘルプを表示
    TEXT

    def self.run(argv, stdout: $stdout, stderr: $stderr)
      new(stdout, stderr).run(argv)
    end

    def initialize(stdout, stderr)
      @stdout = stdout
      @stderr = stderr
    end

    def run(argv)
      case argv.first
      when nil
        @stderr.puts USAGE
        1
      when '-v', '--version'
        @stdout.puts "reportmd #{VERSION}"
        0
      when '-h', '--help', 'help'
        @stdout.puts USAGE
        0
      when 'build'
        build(argv.drop(1))
      else
        @stderr.puts "error: 不明なコマンドです: #{argv.first}"
        @stderr.puts USAGE
        1
      end
    end

    private

    def build(args)
      options = parse_build_options(args)
      return options if options.is_a?(Integer)

      input = options[:input]
      return fail_with("#{input}: error: 入力ファイルが見つかりません") unless File.file?(input)

      output = options[:output] || default_output_path(input)
      config = Config.load(explicit_path: options[:config], input_path: input)
      config.warnings.each { |message| @stderr.puts "#{config.source || '設定'}: warning: #{message}" }

      result = Builder.new(input_path: input, output_path: output, config: config,
                           keep_temp: options[:keep_temp]).call
      report_success(input, result)
    rescue PreprocessError => e
      fail_with("#{input}:#{e.line ? "#{e.line}:" : ''} error: #{e.message}")
    rescue ConfigError, BuildError => e
      fail_with("error: #{e.message}")
    end

    def report_success(input, result)
      result.warnings.each { |w| @stderr.puts "#{input}:#{w.line}: warning: #{w.message}" }
      @stderr.puts result.tool_output unless result.tool_output.to_s.empty?
      @stderr.puts "一時ファイルを残しました: #{result.temp_dir}" if result.temp_dir
      @stdout.puts "#{result.output_path} を出力しました"
      0
    end

    def parse_build_options(args)
      options = { keep_temp: false }
      parser = OptionParser.new do |opts|
        opts.on('-o', '--output FILE') { |v| options[:output] = v }
        opts.on('-c', '--config FILE') { |v| options[:config] = v }
        opts.on('--keep-temp') { options[:keep_temp] = true }
        opts.on('-h', '--help') { options[:help] = true }
      end
      rest = parser.parse(args)

      if options[:help]
        @stdout.puts USAGE
        return 0
      end
      return fail_with('error: 入力ファイルを1つ指定してください（例: reportmd build report.rmd）') unless rest.length == 1

      options.merge(input: rest.first)
    rescue OptionParser::ParseError => e
      fail_with("error: #{e.message}")
    end

    def default_output_path(input)
      File.join(File.dirname(input), "#{File.basename(input, '.*')}.pdf")
    end

    def fail_with(message)
      @stderr.puts message
      1
    end
  end
end