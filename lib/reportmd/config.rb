# frozen_string_literal: true

require 'json'

module Reportmd
  # 設定ファイルの読み込み・検証で見つかったエラー。
  class ConfigError < StandardError; end

  # 設定ファイル（JSON）を読み込み、デフォルト設定と統合して検証する。
  #
  # 探索順:
  #   1. 明示的に指定されたファイル（-c / --config）
  #   2. 入力ファイルと同じディレクトリの setting.json
  #   3. 内蔵のデフォルト設定（config/default.json）だけを使う
  class Config
    DEFAULT_PATH = File.expand_path('../../config/default.json', __dir__)
    SETTING_FILE_NAME = 'setting.json'

    # まだ処理に反映されていない設定。ユーザーが書いた場合は警告する。
    # （実装が完了した項目から、この一覧を減らしていく）
    NOT_YET_SUPPORTED = [].freeze

    PAPERS = %w[a4 a5 b5 letter].freeze
    POSITIONS = %w[top bottom].freeze
    LENGTH = /\A\d+(\.\d+)?(mm|cm|pt|in)\z/
    POINTS = /\A\d+(\.\d+)?pt\z/
    # LaTeX の特殊文字を含むフォント名は受け付けない（組版コードの破損を防ぐ）
    FONT_NAME = /\A[^{}\\%#&$^_~]+\z/

    Rule = Struct.new(:path, :expect, :check)

    string      = ->(v) { v.is_a?(String) }
    boolean     = ->(v) { [true, false].include?(v) }
    length      = ->(v) { v.is_a?(String) && v.match?(LENGTH) }
    font_name   = ->(v) { v.is_a?(String) && !v.strip.empty? && v.match?(FONT_NAME) }
    number_in   = ->(range) { ->(v) { v.is_a?(Numeric) && range.cover?(v) } }
    point_in    = ->(range) { ->(v) { v.is_a?(String) && v.match?(POINTS) && range.cover?(v.to_f) } }
    array_of    = ->(count, item) { ->(v) { v.is_a?(Array) && v.length == count && v.all?(&item) } }
    one_of      = ->(list) { ->(v) { list.include?(v) } }

    FONT_EXPECT = '空でない文字列。{ } \ % # & $ ^ _ ~ は使えません'

    RULES = [
      Rule.new(%w[document paper], PAPERS.map { |p| "\"#{p}\"" }.join(' '), one_of.call(PAPERS)),
      Rule.new(%w[document title], '文字列', string),
      Rule.new(%w[document author], '文字列', string),
      Rule.new(%w[page margin top], '単位つきの長さ（例："25mm"。単位は mm cm pt in）', length),
      Rule.new(%w[page margin bottom], '単位つきの長さ（例："25mm"。単位は mm cm pt in）', length),
      Rule.new(%w[page margin left], '単位つきの長さ（例："25mm"。単位は mm cm pt in）', length),
      Rule.new(%w[page margin right], '単位つきの長さ（例："25mm"。単位は mm cm pt in）', length),
      Rule.new(%w[page numbering], 'true または false', boolean),
      Rule.new(%w[text font_size], '"6pt"〜"24pt"', point_in.call(6.0..24.0)),
      Rule.new(%w[text line_spacing], '1.0〜3.0 の数値', number_in.call(1.0..3.0)),
      Rule.new(%w[text paragraph_indent], '0〜5 の数値（単位は字）', number_in.call(0..5)),
      Rule.new(%w[font main], FONT_EXPECT, font_name),
      Rule.new(%w[font mono], FONT_EXPECT, font_name),
      Rule.new(%w[heading font], FONT_EXPECT, font_name),
      Rule.new(%w[heading bold], 'true または false', boolean),
      Rule.new(%w[heading sizes], '"6pt"〜"24pt" の文字列を3個並べた配列',
               array_of.call(3, point_in.call(6.0..24.0))),
      Rule.new(%w[heading indents], '0〜5 の数値を3個並べた配列（単位は字）',
               array_of.call(3, number_in.call(0..5))),
      Rule.new(%w[caption figure_label], '文字列', string),
      Rule.new(%w[caption table_label], '文字列', string),
      Rule.new(%w[caption figure_position], '"top" または "bottom"', one_of.call(POSITIONS)),
      Rule.new(%w[caption table_position], '"top" または "bottom"', one_of.call(POSITIONS))
    ].freeze

    attr_reader :values, :warnings, :source

    # @param explicit_path [String, nil] -c で指定されたファイル
    # @param input_path [String, nil] 入力ファイル（同じ場所の setting.json を探すために使う）
    def self.load(explicit_path: nil, input_path: nil)
      defaults = read_json(DEFAULT_PATH)
      path = find_user_file(explicit_path, input_path)
      user = path ? read_json(path) : {}
      new(defaults, user, path)
    end

    def self.find_user_file(explicit_path, input_path)
      if explicit_path
        raise ConfigError, "設定ファイルが見つかりません: #{explicit_path}" unless File.file?(explicit_path)

        return explicit_path
      end
      return nil unless input_path

      candidate = File.join(File.dirname(File.expand_path(input_path)), SETTING_FILE_NAME)
      File.file?(candidate) ? candidate : nil
    end

    def self.read_json(path)
      text = File.read(path, encoding: 'UTF-8').sub(/\A\uFEFF/, '')
      JSON.parse(text)
    rescue JSON::ParserError => e
      raise ConfigError, "設定ファイルがJSONとして不正です: #{path}\n  #{e.message.lines.first.to_s.strip}"
    rescue SystemCallError => e
      raise ConfigError, "設定ファイルを読み込めません: #{path}（#{e.message}）"
    end

    def initialize(defaults, user, source = nil)
      raise ConfigError, '設定ファイルの最上位は { ... } のオブジェクトにしてください' unless user.is_a?(Hash)

      @source = source
      @warnings = []
      @values = deep_merge(defaults, user, [])
      collect_warnings(defaults, user)
      validate!
    end

    def dig(*keys)
      @values.dig(*keys)
    end

    def [](key)
      @values[key]
    end

    private

    # デフォルトの項目だけを残しながら、ユーザーの値で上書きする。
    def deep_merge(base, over, prefix)
      base.each_with_object({}) do |(key, default), result|
        path = prefix + [key]
        result[key] =
          if !over.key?(key)
            default
          elsif default.is_a?(Hash)
            unless over[key].is_a?(Hash)
              raise ConfigError, "設定 #{path.join('.')} はオブジェクト（{ ... }）で指定してください"
            end

            deep_merge(default, over[key], path)
          else
            over[key]
          end
      end
    end

    def collect_warnings(defaults, user)
      unknown_keys(defaults, user, []).each do |name|
        @warnings << "未知の設定キーを無視します: #{name}"
      end
      NOT_YET_SUPPORTED.each do |name|
        @warnings << "設定 #{name} は未対応のため、現在は反映されません" if user.key?(name)
      end
    end

    def unknown_keys(defaults, user, prefix)
      user.flat_map do |key, value|
        path = prefix + [key]
        if !defaults.key?(key)
          [path.join('.')]
        elsif defaults[key].is_a?(Hash) && value.is_a?(Hash)
          unknown_keys(defaults[key], value, path)
        else
          []
        end
      end
    end

    def validate!
      RULES.each do |rule|
        value = @values.dig(*rule.path)
        next if rule.check.call(value)

        raise ConfigError, "設定 #{rule.path.join('.')} の値が不正です: #{value.inspect}（#{rule.expect}）"
      end
    end
  end
end
