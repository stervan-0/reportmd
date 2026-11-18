-- reportmd 用 Pandoc Lua フィルタ
--
-- 前処理（internal/preprocess）が出力した「クラス付きのブロック」を、
-- 出力形式ごとの組版に変換する。
--
-- 現在の対応:
--   .reportmd-pagebreak       ->  \newpage
--   .reportmd-right           ->  右揃え（flushright）
--   .reportmd-center          ->  中央揃え（center）
--   .reportmd-figure          ->  図（番号とキャプションを付ける）
--   .reportmd-table-caption   ->  直後の表に、番号とキャプションを付ける
--   表（LaTeX）               ->  tabular に組む（書式はプリアンブルの命令で決める）
--   独立した数式（$$）        ->  右端に通し番号 (1) を付ける（.reportmd-equation の目印で
--                                 参照用の名前・番号なしを指定）
--   @名前（引用）             ->  名前を付けた図表・数式の「図1」「表2」「式(1)」
--   コードブロック            ->  PDF は reportmdcode 環境、HTML は .reportmd-code の div で囲む。
--                                 Word は、続けて書いたコードブロックの間に空きの段落を入れる
--   文中のコード              ->  PDF は背景の箱（\reportmdinlinecodestart〜end）で囲む。
--                                 HTML は背景の CSS を出す。Word は文中のコード用のスタイルの文字にする
--   2 スペース始まりの段落   ->  字下げ 1 文字分（paragraph_indent の置き換え）
--   見出し                    ->  #1〜#3（.reportmd-num）は番号付き、
--                                 標準の #（クラスなし）は番号なしにする
--   title / author            ->  PDF のメタデータに使う。本文には、表紙（cover）でだけ出す
--   cover                     ->  文書の先頭に表紙を置く（レイアウトは設定の cover_json）
--   PowerPoint（pptx）        ->  見出しごとに1枚のスライド（見出しの番号は文字で付ける）。
--                                 改ページは新しいスライド、脚注は最後の「注」のスライド
--   Word（docx）              ->  右揃え・字下げ・キャプションなどに、雛形（internal/build/docx.go）の
--                                 スタイルをあてる。見出しの番号は文字で付け、番号の付く数式は
--                                 罫線のない3列の表（空き・数式・番号）にする
--   そのほかのメタデータ      ->  取り除く（フロントマターの対応外のキーを無視する）
--
-- 設定（internal/build が metadata の reportmd に入れて渡す）:
--   figure_label / table_label       図・表のラベル文字列（既定：図・表）
--   figure_position / table_position キャプションの位置 top / bottom
--   source                           警告に表示する入力ファイル名
--   table_width / table_header_align 表の幅（auto / full）と見出し行の揃え
--   equation_numbering / equation_label 数式の番号の有無と、参照のラベル（既定：式）
--   code_*                           HTML のコードブロックの書式と、文中のコードの背景（code_inline_background）
--
--   cover_json                       表紙のレイアウト（設定の cover.layout）
--   docx_json                        Word の寸法（本文の高さ、表紙のあとのセクションの区切り）
-- cover_json と docx_json は、JSON を16進数の文字列にしたもの（文字列のままだと Markdown として
-- 読まれ、別のファイルにすると、io.open が日本語を含むパスを開けないことがあるため）。

local function has_class(el, name)
  for _, class in ipairs(el.classes) do
    if class == name then
      return true
    end
  end
  return false
end

-- 警告に表示する入力ファイル名（internal/build が metadata の reportmd.source に入れて渡す）
local source_name = nil

-- 仕様 9.3 の形式「ファイル名:行番号: warning: メッセージ」で表示する。
-- line は前処理が Div の属性に入れた、元の入力ファイルの行番号。
local function warn(message, line)
  local location = source_name or 'reportmd'
  if line ~= nil and line ~= '' then
    location = location .. ':' .. line
  end
  io.stderr:write(location .. ': warning: ' .. message .. '\n')
end

-- internal/build がメタデータに入れた JSON（16進数の文字列。what は警告に表示する名前）を読む。
-- 空なら nil。読めなければ、警告して nil を返す（黙って表紙などを落とさない）。
local function decode_json(hex, what)
  if hex == nil or hex == '' or pandoc.json == nil then
    return nil
  end
  local text = hex:gsub('%x%x', function(byte)
    return string.char(tonumber(byte, 16))
  end)
  local ok, value = pcall(pandoc.json.decode, text, false)
  if not ok or type(value) ~= 'table' then
    warn(what .. 'の設定を読めませんでした（' .. what .. 'を付けずに出力します）')
    return nil
  end
  return value
end

-- ---------------------------------------------------------------------
-- Word の部品
-- ---------------------------------------------------------------------

-- 雛形のスタイル（名前）をあてたブロック
local function styled(name, blocks)
  return pandoc.Div(blocks, { ['custom-style'] = name })
end

-- 高さ pt の空き（中身のない段落）
local function docx_space(pt)
  return pandoc.RawBlock('openxml', string.format('<w:p><w:pPr><w:pStyle w:val="reportmdSpace"/>'
    .. '<w:spacing w:before="0" w:after="0" w:line="%d" w:lineRule="exact"/></w:pPr></w:p>', math.floor(pt * 20 + 0.5)))
end

-- 図表・中央揃えなどの前後の空き（PDF の trivlist の \topsep と同じ 8pt）
local DOCX_SKIP = 8

-- 改ページ（改ページの前後に残る段落は、高さ 1pt にする）
local DOCX_PAGEBREAK = '<w:p><w:pPr><w:pStyle w:val="reportmdSpace"/>'
  .. '<w:spacing w:before="0" w:after="0" w:line="20" w:lineRule="exact"/></w:pPr><w:r><w:br w:type="page"/></w:r></w:p>'

-- 罫線のない表（internal/build が、最初のセルの段落のスタイルを見て、表のスタイルを差し替える）。
-- rows はセル（Blocks）の並びの並び、widths は列の幅（本文幅に対する割合。0 なら内容に合わせる）、
-- aligns は列の揃え。表のセルの段落は Para にする（Plain だと、Pandoc がスタイルを Compact にする）。
local function plain_table(rows, widths, aligns)
  local tbl = pandoc.utils.from_simple_table(pandoc.SimpleTable({}, aligns, widths, {}, rows))
  tbl.attr = pandoc.Attr('', { 'reportmd-plain' })
  return tbl
end

-- ---------------------------------------------------------------------
-- 設定の読み込み（最初の走査）
-- ---------------------------------------------------------------------

local settings = {
  figure_label = '図',
  table_label = '表',
  figure_position = 'bottom',
  table_position = 'top',
  table_width = 'auto',          -- auto（内容に合わせる）/ full（本文幅いっぱい）
  table_header_align = 'center', -- center / left / right / column（列の揃えに従う）
  equation_numbering = 'true',   -- false なら数式に番号を付けない
  equation_label = '式',         -- 参照のラベル（@名前 -> 式(1)）
  code_font_size = '10.5',       -- HTML のコードブロックの書式（pt。PDF はプリアンブル、Word は雛形で決める）
  code_line_height = '15.12',
  code_background = 'F5F5F5',    -- 背景の色（16進数6桁。空なら付けない）
  code_border = '0.4pt',         -- 枠の線の太さ（空なら付けない）
  code_border_color = 'BFBFBF',
  code_padding = '5.25',
  code_inline_background = 'E6E6E6', -- 文中のコードの背景の色（code_background を少し濃くした色。空なら付けない）
  cover_json = '',               -- 表紙のレイアウト（JSON を16進数にしたもの。decode_json で読む）
  docx_json = '',                -- Word の寸法（同上。Word のときだけ）
}

local function read_settings(meta)
  local given = meta.reportmd
  if given == nil then
    return
  end
  if given.source ~= nil then
    source_name = pandoc.utils.stringify(given.source)
  end
  for key, _ in pairs(settings) do
    if given[key] ~= nil then
      settings[key] = pandoc.utils.stringify(given[key])
    end
  end
end

-- ---------------------------------------------------------------------
-- タイトルと著者
-- ---------------------------------------------------------------------

-- メタデータの値を、書式を除いた文字列にする（著者が複数なら「, 」でつなぐ）
local function meta_to_string(value)
  if pandoc.utils.type(value) == 'List' then
    local parts = {}
    for _, item in ipairs(value) do
      parts[#parts + 1] = pandoc.utils.stringify(item)
    end
    return table.concat(parts, ', ')
  end
  return pandoc.utils.stringify(value)
end

-- title / author をそのまま残すと、Pandoc が本文の先頭にタイトルを出力してしまう。
-- そこで、PDF のメタデータ用の title-meta / author-meta に移し替える。
local function move_to_pdf_metadata(meta, key)
  if meta[key] ~= nil then
    local meta_key = key .. '-meta'
    if meta[meta_key] == nil then
      meta[meta_key] = meta_to_string(meta[key])
    end
    meta[key] = nil
  end
end

-- フロントマターで使えるのは title・author・cover だけ。ほかのキー（geometry、
-- header-includes など）は、Pandoc のテンプレートに反映されないように取り除く。
-- （警告は前処理が行番号つきで出している。cover は、最初の走査で表紙の値を読んでから取り除く）
local META_KEYS = { title = true, author = true }

local function drop_unsupported_meta(meta)
  local keys = {}
  for key, _ in pairs(meta) do
    if not META_KEYS[key] then
      keys[#keys + 1] = key
    end
  end
  for _, key in ipairs(keys) do
    meta[key] = nil
  end
end

local function move_title_and_author(meta)
  drop_unsupported_meta(meta)
  move_to_pdf_metadata(meta, 'title')
  move_to_pdf_metadata(meta, 'author')
  return meta
end

-- ---------------------------------------------------------------------
-- 表紙
-- ---------------------------------------------------------------------
--
-- フロントマターに cover があれば、文書の先頭に表紙を置く。
--   cover:
--     科目: 情報工学実験 II
--     学籍番号: 1234567
-- レイアウト（設定の cover_json）の文字列の {名前} に、cover の値（title と author は
-- フロントマターの値）を差し込む。差し込む値がどれも空の行は、表紙に出さない。

local cover_values = nil -- 名前 -> Inlines。cover がなければ nil

-- メタデータの値を Inlines にする（リストは「、」でつなぐ）
local function meta_to_inlines(value)
  local kind = pandoc.utils.type(value)
  if kind == 'Inlines' then
    return value
  elseif kind == 'Blocks' then
    return pandoc.utils.blocks_to_inlines(value)
  elseif kind == 'List' then
    local result = pandoc.Inlines({})
    for i, item in ipairs(value) do
      if i > 1 then
        result:insert(pandoc.Str('、'))
      end
      result:extend(meta_to_inlines(item))
    end
    return result
  end
  return pandoc.Inlines({ pandoc.Str(pandoc.utils.stringify(value)) })
end

local function read_cover(meta)
  local cover = meta.cover
  if cover == nil or cover == false then
    return
  end
  cover_values = {}
  if pandoc.utils.type(cover) == 'table' then
    for key, value in pairs(cover) do
      cover_values[key] = meta_to_inlines(value)
    end
  end
  for _, key in ipairs({ 'title', 'author' }) do
    if meta[key] ~= nil and cover_values[key] == nil then
      cover_values[key] = meta_to_inlines(meta[key])
    end
  end
end

local function read_cover_layout()
  if pandoc.json == nil then
    warn('表紙を作るには、Pandoc 3.1.1 以上が必要です（表紙は付けません）')
    return nil
  end
  local cover = decode_json(settings.cover_json, '表紙')
  return cover and cover.layout
end

-- 文字列（文字と {名前} の並び）を Inlines にする。
-- {名前} があり、その値がどれも空なら、空（nil）を返す。
local function fill_template(parts, used)
  local result = pandoc.Inlines({})
  local has_var, has_value = false, false
  for _, part in ipairs(parts) do
    if part.var ~= nil then
      has_var = true
      used[part.var] = true
      local value = cover_values[part.var]
      if value ~= nil and pandoc.utils.stringify(value):match('%S') then
        has_value = true
        result:extend(value)
      end
    else
      result:insert(pandoc.Str(part.text))
    end
  end
  if has_var and not has_value then
    return nil
  end
  return result
end

local LATEX_ALIGN = { center = '\\centering', left = '\\raggedright', right = '\\raggedleft' }

-- 項目の書式（揃え・文字サイズ・太字）を始める LaTeX
local function latex_style(line)
  local tex = '{\\noindent' .. LATEX_ALIGN[line.align]
  if line.size ~= nil then
    tex = tex .. '\\fontsize{' .. line.size .. 'pt}{' .. line.leading .. 'pt}\\selectfont'
  end
  -- 太字は \bfseries にせず、疑似太字の強さ（文字サイズに比例させた値）を直接指定する。
  -- \bfseries はプリアンブルの強さ（本文用）になり、大きな文字ではほとんど太く見えないため
  if line.bold ~= nil then
    tex = tex .. '\\addfontfeatures{FakeBold=' .. line.bold .. '}\\addCJKfontfeatures{FakeBold=' .. line.bold .. '}'
  end
  return tex .. ' '
end

local function html_style(line)
  local style = 'text-align: ' .. line.align .. ';'
  if line.size ~= nil then
    style = style .. ' font-size: ' .. line.size .. 'pt;'
  end
  if line.bold ~= nil then
    style = style .. ' font-weight: bold;'
  end
  return style
end

-- fields の行のうち、値が空でない行の { 項目名, 値 } を返す
local function field_rows(line, used)
  local rows = {}
  for _, row in ipairs(line.rows) do
    local label = fill_template(row[1], used) or pandoc.Inlines({})
    local value = fill_template(row[2], used)
    if value ~= nil and #value > 0 then
      rows[#rows + 1] = { label, value }
    end
  end
  return rows
end

local function latex_cover(layout, used)
  local blocks = pandoc.List({
    -- 表紙と本文の 1 ページ目が、PDF 内のリンクで同じ名前（page.1）にならないようにする
    pandoc.RawBlock('latex', '\\ifdefined\\hypersetup\\hypersetup{pageanchor=false}\\fi\n\\begin{titlepage}'),
  })
  for _, line in ipairs(layout) do
    if line.kind == 'space' then
      local space = line.space == 'fill' and '\\fill' or line.space
      blocks:insert(pandoc.RawBlock('latex', '\\vspace*{' .. space .. '}'))
    elseif line.kind == 'text' then
      local inlines = fill_template(line.parts, used)
      if inlines ~= nil then
        local content = pandoc.Inlines({ pandoc.RawInline('latex', latex_style(line)) })
        content:extend(inlines)
        content:insert(pandoc.RawInline('latex', '\\par}'))
        blocks:insert(pandoc.Plain(content))
      end
    else
      local rows = field_rows(line, used)
      if #rows > 0 then
        local content = pandoc.Inlines({ pandoc.RawInline('latex',
          latex_style(line) .. '\\begin{tabular}{@{}l@{\\hspace{2em}}l@{}}\n') })
        for _, row in ipairs(rows) do
          content:extend(row[1])
          content:insert(pandoc.RawInline('latex', ' & '))
          content:extend(row[2])
          content:insert(pandoc.RawInline('latex', ' \\\\\n'))
        end
        content:insert(pandoc.RawInline('latex', '\\end{tabular}\\par}'))
        blocks:insert(pandoc.Plain(content))
      end
    end
  end
  -- titlepage を閉じると改ページし、本文のページ番号は 1 から始まる（表紙には番号を付けない）
  blocks:insert(pandoc.RawBlock('latex', '\\end{titlepage}\n\\ifdefined\\hypersetup\\hypersetup{pageanchor=true}\\fi'))
  return blocks
end

-- LaTeX 以外：各行を段落にする。HTML では揃え・文字サイズ・太字と固定の空きを反映し、
-- Word では表紙のあとで改ページする
local function other_cover(layout, used)
  local blocks = pandoc.List({})
  for _, line in ipairs(layout) do
    if line.kind == 'space' then
      if FORMAT:match('^html') and line.space ~= 'fill' then
        blocks:insert(pandoc.Div({}, { style = 'height: ' .. line.space .. ';' }))
      end
    else
      local paras = pandoc.List({})
      if line.kind == 'text' then
        local inlines = fill_template(line.parts, used)
        if inlines ~= nil then
          paras:insert(pandoc.Para(inlines))
        end
      else
        for _, row in ipairs(field_rows(line, used)) do
          local inlines = pandoc.Inlines(row[1])
          inlines:insert(pandoc.Str('　'))
          inlines:extend(row[2])
          paras:insert(pandoc.Para(inlines))
        end
      end
      if #paras > 0 then
        blocks:insert(pandoc.Div(paras, FORMAT:match('^html') and { style = html_style(line) } or {}))
      end
    end
  end
  if FORMAT:match('^html') then
    return pandoc.List({ pandoc.Div(blocks, { class = 'reportmd-cover', style = 'break-after: page;' }) })
  end
  if FORMAT == 'docx' then
    blocks:insert(pandoc.RawBlock('openxml', DOCX_PAGEBREAK))
  elseif FORMAT == 'pptx' then
    blocks:insert(pandoc.HorizontalRule()) -- 表紙だけで1枚のスライドにする
  end
  return blocks
end

-- Word：各項目に、雛形の表紙のスタイル（項目ごとの揃え・文字サイズ・太字・行送り）をあてる。
-- fields は罫線のない表にする。fill の空きは、本文の高さから、ほかの項目の高さを引いて等分する
-- （1行に収まる前提。少し余らせて、表紙が2ページにならないようにする）。
-- 項目の高さ（空きは長さ、文字と fields は1行の行送り）は、internal/build が設定の docx_json で渡す。
-- 表紙のあとはセクションを区切る（表紙にはページ番号を付けず、本文を1ページ目にする）。
local DOCX_COVER_MARGIN = 2

local function docx_cover(layout, used, docx)
  local items = {}
  local height, fills = 0, 0
  for i, line in ipairs(layout) do
    local style = 'reportmd Cover ' .. i
    local line_height = docx.cover_heights[i]
    if line.kind == 'space' then
      if line.space == 'fill' then
        items[#items + 1] = 'fill'
        fills = fills + 1
      else
        height = height + line_height
        items[#items + 1] = docx_space(line_height)
      end
    elseif line.kind == 'text' then
      local inlines = fill_template(line.parts, used)
      if inlines ~= nil then
        items[#items + 1] = styled(style, { pandoc.Para(inlines) })
        height = height + line_height
      end
    else
      local rows = {}
      for _, row in ipairs(field_rows(line, used)) do
        rows[#rows + 1] = { { styled(style .. ' Label', { pandoc.Para(row[1]) }) }, { styled(style, { pandoc.Para(row[2]) }) } }
      end
      if #rows > 0 then
        items[#items + 1] = plain_table(rows, { 0, 0 }, { pandoc.AlignLeft, pandoc.AlignLeft })
        height = height + #rows * line_height
      end
    end
  end
  local fill = 0
  if fills > 0 then
    fill = math.max(docx.text_height - height - DOCX_COVER_MARGIN, 0) / fills
  end
  local blocks = pandoc.List({})
  for _, item in ipairs(items) do
    if item ~= 'fill' then
      blocks:insert(item)
    elseif fill > 0 then
      blocks:insert(docx_space(fill))
    end
  end
  blocks:insert(pandoc.RawBlock('openxml', docx.cover_section))
  return blocks
end

local function add_cover(doc)
  if cover_values == nil then
    return nil
  end
  local layout = read_cover_layout()
  if layout == nil then
    return nil
  end
  local used = {}
  local blocks
  local docx = FORMAT == 'docx' and decode_json(settings.docx_json, 'Word の表紙') or nil
  if FORMAT:match('latex') then
    blocks = latex_cover(layout, used)
  elseif docx ~= nil then
    blocks = docx_cover(layout, used, docx)
  else
    blocks = other_cover(layout, used)
  end
  -- 書き間違い（レイアウトの名前と違う）に気付けるよう、使わなかった cover の値を知らせる
  local unused = {}
  for key, _ in pairs(cover_values) do
    if not used[key] and key ~= 'title' and key ~= 'author' then
      unused[#unused + 1] = key
    end
  end
  table.sort(unused)
  for _, key in ipairs(unused) do
    warn('フロントマターの cover の「' .. key .. '」は、表紙のレイアウト（設定の cover.layout）で使われていません')
  end
  blocks:extend(doc.blocks)
  doc.blocks = blocks
  return doc
end

-- ---------------------------------------------------------------------
-- 改ページ・右揃え・中央揃え
-- ---------------------------------------------------------------------

local ALIGNMENTS = {
  ['reportmd-right']  = { latex = 'flushright', css = 'right',  docx = 'reportmd Right' },
  ['reportmd-center'] = { latex = 'center',     css = 'center', docx = 'reportmd Center' },
}

local function alignment_of(el)
  for _, class in ipairs(el.classes) do
    if ALIGNMENTS[class] then
      return ALIGNMENTS[class]
    end
  end
  return nil
end

local function convert_div(el)
  if has_class(el, 'reportmd-pagebreak') then
    if FORMAT:match('latex') then
      return pandoc.RawBlock('latex', '\\newpage')
    elseif FORMAT == 'pptx' then
      return pandoc.HorizontalRule() -- 新しいスライドにする
    elseif FORMAT == 'docx' then
      return pandoc.RawBlock('openxml', DOCX_PAGEBREAK)
    end
    return {} -- そのほかの出力では、改ページブロックを取り除く
  end

  local align = alignment_of(el)
  if align then
    if FORMAT:match('latex') then
      local blocks = pandoc.List({ pandoc.RawBlock('latex', '\\begin{' .. align.latex .. '}') })
      blocks:extend(el.content)
      blocks:insert(pandoc.RawBlock('latex', '\\end{' .. align.latex .. '}'))
      return blocks
    elseif FORMAT:match('^html') then
      el.attributes['style'] = 'text-align: ' .. align.css .. ';'
      return el
    elseif FORMAT == 'docx' then
      return styled(align.docx, el.content)
    end
    return el.content -- そのほかの出力では、揃えずに内容だけを残す
  end
end

-- ---------------------------------------------------------------------
-- 見出しの番号
-- ---------------------------------------------------------------------

-- 前処理が #1〜#3 を「.reportmd-num」つきの見出しに変換している。
-- Pandoc を --number-sections で実行すると全ての見出しに番号が付くので、
-- 標準の見出し（.reportmd-num がないもの）に .unnumbered を付けて、番号なしにする。
--
-- PowerPoint は --number-sections の番号を出力しないので、番号を文字で付ける。
-- また、見出しごとに1枚のスライドにするため、見出しをすべて最上位にする
-- （Pandoc は --slide-level=1 で実行する）。
-- Word も、番号を文字で付ける（Pandoc は番号のあとにタブを入れるが、PDF と同じ全角1字にする）。
local section_numbers = {} -- 階層ごとの番号（PowerPoint・Word 用）

-- 番号付き見出しの番号（「2.1」）。飛ばしたレベルは 0 にする
local function section_number(el)
  section_numbers[el.level] = (section_numbers[el.level] or 0) + 1
  for level = el.level + 1, #section_numbers do
    section_numbers[level] = nil
  end
  local parts = {}
  for level = 1, el.level do
    parts[level] = tostring(section_numbers[level] or 0)
  end
  return table.concat(parts, '.')
end

local function pptx_header(el)
  if has_class(el, 'reportmd-num') then
    el.content:insert(1, pandoc.Space())
    el.content:insert(1, pandoc.Str(section_number(el)))
  end
  el.level = 1
  return el
end

local function convert_header(el)
  if FORMAT == 'pptx' then
    return pptx_header(el)
  end
  if FORMAT == 'docx' and has_class(el, 'reportmd-num') then
    el.content:insert(1, pandoc.Str(section_number(el) .. '　'))
    el.classes:insert('unnumbered')
    return el
  end
  if has_class(el, 'reportmd-num') then
    return nil
  end
  if not has_class(el, 'unnumbered') then
    el.classes:insert('unnumbered')
    return el
  end
end

-- ---------------------------------------------------------------------
-- 図表の番号とキャプション
-- ---------------------------------------------------------------------

local counters = { figure = 0, table = 0 }

-- 参照先の位置。'figure1' / 'table2' / 'equation3'（数式は走査の通し番号）-> 名前。
-- 名前を付けた図表・数式の位置に目印を置き、@名前 の参照から PDF 内のリンクで飛べるようにする。
local targets = {}

-- 参照先の目印（空のスパン。LaTeX では \label になる）。名前がなければ nil。
local function anchor(key)
  local id = targets[key]
  if id == nil then
    return nil
  end
  return pandoc.Span({}, { id = id })
end

-- 画像の属性から、名前（{#名前}）を取り除いた画像を作る（目印は anchor で別に置く）
local function plain_image(image)
  return pandoc.Image({}, image.src, image.title, pandoc.Attr('', image.classes, image.attributes))
end

-- インラインの並びの先頭に、目印を置く
local function with_anchor(mark, inlines)
  local result = pandoc.List({})
  if mark ~= nil then
    result:insert(mark)
  end
  result:extend(inlines)
  return result
end

-- 「図1 タイトル」。タイトルがなければ番号だけ（「図1」）。
local function make_caption(label, number, title)
  local inlines = pandoc.List({ pandoc.Str(label .. number) })
  if #title > 0 then
    inlines:insert(pandoc.Space())
    inlines:extend(title)
  end
  return inlines
end

-- 図のブロック（Div）から、画像・タイトル・参照用の名前（{#名前}。なければ ''）を
-- 取り出す。画像だけの行でなければ nil。
local function figure_parts(div)
  if #div.content ~= 1 then
    return nil
  end
  local block = div.content[1]
  if block.t == 'Figure' then
    local inner = block.content
    if #inner == 1 and (inner[1].t == 'Plain' or inner[1].t == 'Para')
        and #inner[1].content == 1 and inner[1].content[1].t == 'Image' then
      local image = inner[1].content[1]
      local id = block.identifier ~= '' and block.identifier or image.identifier
      return image, pandoc.utils.blocks_to_inlines(block.caption.long), id
    end
  elseif block.t == 'Para' or block.t == 'Plain' then
    if #block.content == 1 and block.content[1].t == 'Image' then
      local image = block.content[1]
      return image, pandoc.List(), image.identifier
    end
  end
  return nil
end

-- LaTeX：浮動体（figure 環境）にせず、書いた位置に固定する。
-- 画像とキャプションが別のページに分かれないように、samepage で囲む。
-- 参照先の目印は、画像の行に置くと画像の下端の位置になるので、図の上端（行の外）に置く。
local function latex_figure(image, caption, position, mark)
  local picture = pandoc.Plain({ plain_image(image) })
  local text = pandoc.Plain(caption)
  local gap = pandoc.RawBlock('latex', '\\vspace{0.5\\baselineskip}')
  local opening = '\\begin{samepage}\\begin{center}'
  if mark ~= nil then
    opening = opening .. '\\hypertarget{' .. mark.identifier .. '}{}'
  end
  local blocks = pandoc.List({ pandoc.RawBlock('latex', opening) })
  if position == 'top' then
    blocks:extend({ text, gap, picture })
  else
    blocks:extend({ picture, gap, text })
  end
  blocks:insert(pandoc.RawBlock('latex', '\\end{center}\\end{samepage}'))
  return blocks
end

local function convert_figure(div)
  local image, title = figure_parts(div)
  if image == nil then
    warn('図の行には、画像だけを書いてください（番号は付けません）', div.attributes['line'])
    return div.content
  end

  counters.figure = counters.figure + 1
  local caption = make_caption(settings.figure_label, counters.figure, title)
  local mark = anchor('figure' .. counters.figure)
  if FORMAT:match('latex') then
    return latex_figure(image, caption, settings.figure_position, mark)
  end
  if FORMAT == 'pptx' then
    -- PowerPoint は、画像の前に目印があると画像を出力せず、キャプションには画像の代替テキストを使う
    local picture = plain_image(image)
    picture.caption = caption
    return pandoc.List({ pandoc.Figure({ pandoc.Plain({ picture }) }, { long = { pandoc.Plain(caption) } }) })
  end
  if FORMAT == 'docx' then
    -- Pandoc の図（1マスの表になる）にせず、画像とキャプションの段落を設定の順に並べる
    local picture = styled('reportmd Figure', { pandoc.Para(with_anchor(mark, { plain_image(image) })) })
    local text = styled('reportmd Figure Caption', { pandoc.Para(caption) })
    if settings.figure_position == 'top' then
      return pandoc.List({ text, picture })
    end
    return pandoc.List({ picture, text })
  end
  local figure = pandoc.Figure({ pandoc.Plain(with_anchor(mark, { plain_image(image) })) },
    { long = { pandoc.Plain(caption) } })
  return pandoc.List({ figure })
end

-- ---------------------------------------------------------------------
-- 表の組版（LaTeX）
-- ---------------------------------------------------------------------
--
-- Pandoc 標準の longtable は使わず、tabular に組む。書式（罫線の有無と太さ、
-- 文字サイズ、行の高さ、セルの余白、見出しの太字）は、preamble.tex.tmpl が
-- 設定から定義する命令（\reportmdruletop など）で決める。
-- 使わない罫線は空の命令になるので、ここでは常に同じ形で出力すればよい。

local ALIGN_LETTERS = { AlignLeft = 'l', AlignRight = 'r', AlignCenter = 'c' }
local RAGGED = { l = '\\raggedright', r = '\\raggedleft', c = '\\centering' }
local HEADER_LETTERS = { left = 'l', right = 'r', center = 'c' }

local function align_letter(align)
  return ALIGN_LETTERS[tostring(align)]
end

-- 各列の揃え（l / c / r）と幅（本文幅に対する割合。指定がなければ nil）
local function column_defs(tbl)
  local defs = {}
  for i, colspec in ipairs(tbl.colspecs) do
    local width = colspec[2]
    if type(width) ~= 'number' or width <= 0 then
      width = nil
    end
    defs[i] = { letter = align_letter(colspec[1]) or 'l', width = width }
  end
  return defs
end

-- width が full で、すべての列に幅の指定がある表（グリッド表など）は、
-- 幅の合計が本文幅になるよう、割合をそろえて広げる。
local function fill_widths(defs)
  local total = 0
  for _, def in ipairs(defs) do
    if def.width == nil then
      return
    end
    total = total + def.width
  end
  for _, def in ipairs(defs) do
    def.width = def.width / total
  end
end

-- 列の書式。幅の指定がある列は、折り返す p 列にする（揃えは保つ）
local function core_spec(letter, width, ncols)
  if width == nil then
    return letter
  end
  return string.format('>{%s\\arraybackslash}p{(\\linewidth - %d\\tabcolsep) * \\real{%.4f}}',
    RAGGED[letter], 2 * ncols, width)
end

-- 本文幅いっぱいに広げる表（tabularx）にするか。
-- 幅の指定がない列があれば、その列（X 列）を広げて本文幅に合わせる。
-- すべての列に幅の指定がある表は、fill_widths で広げるので tabular のままにする。
local function use_tabularx(defs)
  if settings.table_width ~= 'full' then
    return false
  end
  for _, def in ipairs(defs) do
    if def.width == nil then
      return true
    end
  end
  return false
end

local function tabular_spec(defs, stretch)
  local parts = {}
  for i, def in ipairs(defs) do
    if stretch and def.width == nil then
      parts[i] = '>{' .. RAGGED[def.letter] .. '\\arraybackslash}X'
    else
      parts[i] = core_spec(def.letter, def.width, #defs)
    end
  end
  return '!{\\reportmdvside}' .. table.concat(parts, '!{\\reportmdvrule}') .. '!{\\reportmdvside}'
end

-- \multicolumn の書式。縦の罫線は、右側（と、最初の列なら左側）を含める
local function multicolumn_spec(col, span, ncols, core)
  local left = col == 1 and '!{\\reportmdvside}' or ''
  local right = (col + span - 1 == ncols) and '!{\\reportmdvside}' or '!{\\reportmdvrule}'
  return left .. core .. right
end

-- セルの内容を LaTeX にする。段落の区切りは、p 列なら \par、それ以外は空白にする
local function cell_latex(cell, paragraphs)
  local tex = pandoc.write(pandoc.Pandoc(cell.contents), 'latex')
  tex = tex:gsub('^%s+', ''):gsub('%s+$', '')
  return (tex:gsub('\n%s*\n', paragraphs and '\\par ' or ' '))
end

-- 結合したセルの幅（結合した列の幅の合計）。幅の決まっていない列を含めば nil
local function spanned_width(defs, col, span)
  local total = 0
  for c = col, col + span - 1 do
    if defs[c].width == nil then
      return nil
    end
    total = total + defs[c].width
  end
  return total
end

-- 1行分を「a & b & c \\」にする。
-- 縦に結合されたセル（row_span）の下の行には、空のセルを補う。
local function render_row(row, defs, pending, is_header)
  local ncols = #defs
  local parts = {}
  local cells = row.cells
  local next_cell = 1
  local col = 1
  while col <= ncols do
    if (pending[col] or 0) > 0 then
      pending[col] = pending[col] - 1
      parts[#parts + 1] = ''
      col = col + 1
    else
      local cell = cells[next_cell]
      next_cell = next_cell + 1
      if cell == nil then
        parts[#parts + 1] = '' -- セルが足りない行は、空のセルで埋める
        col = col + 1
      else
        local span = math.min(cell.col_span, ncols - col + 1)
        if cell.row_span > 1 then
          for c = col, col + span - 1 do
            pending[c] = cell.row_span - 1
          end
        end

        local def = defs[col]
        local letter = align_letter(cell.alignment) or def.letter
        local override = false
        if is_header and settings.table_header_align ~= 'column' then
          letter = HEADER_LETTERS[settings.table_header_align] or 'c'
          override = true
        end
        local width = spanned_width(defs, col, span)
        local text = cell_latex(cell, width ~= nil)
        if is_header then
          text = '\\reportmdtablehead{' .. text .. '}'
        end
        if span > 1 or override or letter ~= def.letter then
          text = string.format('\\multicolumn{%d}{%s}{%s}', span,
            multicolumn_spec(col, span, ncols, core_spec(letter, width, ncols)), text)
        end
        parts[#parts + 1] = text
        col = col + span
      end
    end
  end
  return table.concat(parts, ' & ') .. ' \\\\'
end

-- 表全体を tabular（width が full なら tabularx）の LaTeX にする
local function latex_tabular(tbl)
  local defs = column_defs(tbl)
  if settings.table_width == 'full' then
    fill_widths(defs)
  end
  local pending = {}
  local lines = { '\\reportmdruletop' }

  for _, row in ipairs(tbl.head.rows) do
    lines[#lines + 1] = render_row(row, defs, pending, true)
  end
  if #tbl.head.rows > 0 then
    lines[#lines + 1] = '\\reportmdruleheader'
  end

  local body_rows = {}
  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.head) do
      body_rows[#body_rows + 1] = row
    end
    for _, row in ipairs(body.body) do
      body_rows[#body_rows + 1] = row
    end
  end
  for i, row in ipairs(body_rows) do
    if i > 1 then
      lines[#lines + 1] = '\\reportmdrulerows' -- 本文の行の間の線
    end
    lines[#lines + 1] = render_row(row, defs, pending, false)
  end

  if #tbl.foot.rows > 0 then
    lines[#lines + 1] = '\\reportmdruleheader'
    for _, row in ipairs(tbl.foot.rows) do
      lines[#lines + 1] = render_row(row, defs, pending, false)
    end
  end
  lines[#lines + 1] = '\\reportmdrulebottom'

  local stretch = use_tabularx(defs)
  local spec = tabular_spec(defs, stretch)
  local open, close = '\\begin{tabular}{' .. spec .. '}', '\\end{tabular}'
  if stretch then
    open = '\\begin{tabularx}{\\linewidth}{' .. spec .. '}'
    close = '\\end{tabularx}'
  end
  return '{\\reportmdtablestyle\n' .. open .. '\n' .. table.concat(lines, '\n') .. '\n' .. close .. '\\par}'
end

-- LaTeX：表とキャプションを、設定の位置（中央・左）にまとめて置く。
-- キャプションと表の間には本文の半行ぶんの空きを入れ、ページが分かれないようにする。
-- caption が nil なら、表だけを置く。
local function latex_table(tbl, caption, position)
  local body = pandoc.RawBlock('latex', latex_tabular(tbl))
  local gap = pandoc.RawBlock('latex', '\\par\\nopagebreak[4]\\vspace{0.5\\baselineskip}')
  local blocks = pandoc.List({ pandoc.RawBlock('latex', '\\begin{reportmdtablebox}') })
  if caption == nil then
    blocks:insert(body)
  elseif position == 'bottom' then
    blocks:extend({ body, gap, pandoc.Plain(caption) })
  else
    blocks:extend({ pandoc.Plain(caption), gap, body })
  end
  blocks:insert(pandoc.RawBlock('latex', '\\end{reportmdtablebox}'))
  return blocks
end

-- Pandoc 標準のキャプション（: タイトル）。なければ nil
local function own_caption(tbl)
  if #tbl.caption.long > 0 then
    return pandoc.utils.blocks_to_inlines(tbl.caption.long)
  end
  return nil
end

-- ---------------------------------------------------------------------
-- 表の組版（Word）
-- ---------------------------------------------------------------------
--
-- 罫線・配置・セルの余白は、雛形の表のスタイル（Table）で決まる。ここでは、セルの段落に
-- 文字サイズと行の高さのスタイルをあて、見出し行の揃えと表の幅を設定に合わせる。

local DOCX_HEADER_ALIGN = { left = 'AlignLeft', right = 'AlignRight', center = 'AlignCenter' }

-- セルの段落にスタイルをあてる（Plain のままだと、Pandoc がスタイルを Compact にするので Para にする）
local function docx_cells(rows, style, align)
  for _, row in ipairs(rows) do
    for _, cell in ipairs(row.cells) do
      local contents = pandoc.Blocks({})
      for _, block in ipairs(cell.contents) do
        contents:insert(block.t == 'Plain' and pandoc.Para(block.content) or block)
      end
      cell.contents = pandoc.Blocks({ styled(style, contents) })
      if align ~= nil then
        cell.alignment = align
      end
    end
  end
end

-- width が full なら、列の幅（本文幅に対する割合）の合計を 1 にする。
-- 幅の指定がない列は、残りを等分する（PDF の tabularx の X 列）。
local function docx_full_width(tbl)
  local defs = column_defs(tbl)
  local total, missing = 0, 0
  for _, def in ipairs(defs) do
    if def.width == nil then
      missing = missing + 1
    else
      total = total + def.width
    end
  end
  if missing > 0 and total >= 1 then
    return
  end
  for i, colspec in ipairs(tbl.colspecs) do
    local width = defs[i].width
    if missing == 0 then
      width = width / total
    elseif width == nil then
      width = (1 - total) / missing
    end
    tbl.colspecs[i] = { colspec[1], width }
  end
end

-- 表とキャプションを、設定の位置に並べる。キャプションのない側には、PDF と同じ空きを置く。
local function docx_table(tbl, caption, position)
  docx_cells(tbl.head.rows, 'reportmd Table Header', DOCX_HEADER_ALIGN[settings.table_header_align])
  for _, body in ipairs(tbl.bodies) do
    docx_cells(body.head, 'reportmd Table Text')
    docx_cells(body.body, 'reportmd Table Text')
  end
  docx_cells(tbl.foot.rows, 'reportmd Table Text')
  if settings.table_width == 'full' then
    docx_full_width(tbl)
  end
  tbl.caption.long = pandoc.Blocks({})

  if caption == nil then
    return pandoc.List({ docx_space(DOCX_SKIP), tbl, docx_space(DOCX_SKIP) })
  end
  local text = styled('reportmd Table Caption', { pandoc.Para(caption) })
  if position == 'bottom' then
    return pandoc.List({ docx_space(DOCX_SKIP), tbl, text })
  end
  return pandoc.List({ text, tbl, docx_space(DOCX_SKIP) })
end

-- 番号を付けない表（![t:...] のない表）も、同じ書式で組む。
-- Pandoc 標準のキャプション（: タイトル）があれば、番号なしでそのまま使う。
local function numberless_table(tbl)
  if FORMAT == 'docx' then
    return docx_table(tbl, own_caption(tbl), settings.table_position)
  end
  return latex_table(tbl, own_caption(tbl), settings.table_position)
end

local function convert_table(caption_div, tbl)
  local title = pandoc.List()
  if #caption_div.content > 0 then
    title = pandoc.utils.blocks_to_inlines(caption_div.content)
  end
  counters.table = counters.table + 1
  local caption = with_anchor(anchor('table' .. counters.table),
    make_caption(settings.table_label, counters.table, title))

  -- 表に付いていたキャプション（: タイトル）は使わない
  if FORMAT:match('latex') then
    return latex_table(tbl, caption, settings.table_position)
  elseif FORMAT == 'docx' then
    return docx_table(tbl, caption, settings.table_position)
  end
  tbl.caption.long = pandoc.Blocks({ pandoc.Plain(caption) })
  return tbl
end

-- ブロックの、最初（last が false）または最後のブロックを、引用・Div の中までたどって返す
-- （引用の中のコードも、Word では本文のコードと同じ字下げの段落になるため）。
local function edge_block(block, last)
  while block ~= nil and (block.t == 'BlockQuote' or block.t == 'Div') and #block.content > 0 do
    block = block.content[last and #block.content or 1]
  end
  return block
end

-- Word：2つのブロックの境目で、コードブロックが隣り合うか
local function code_blocks_meet(before, after)
  local a, b = edge_block(before, true), edge_block(after, false)
  return a ~= nil and b ~= nil and a.t == 'CodeBlock' and b.t == 'CodeBlock'
end

-- ブロックの並びを先頭から見ていき、図・表の見出しを、番号つきの組版に置き換える。
local function convert_blocks(blocks)
  local result = pandoc.List({})
  local changed = false
  local i = 1
  while i <= #blocks do
    local block = blocks[i]
    if block.t == 'Div' and has_class(block, 'reportmd-figure') then
      result:extend(convert_figure(block))
      changed = true
    elseif block.t == 'Div' and has_class(block, 'reportmd-table-caption') then
      local following = blocks[i + 1]
      if following ~= nil and following.t == 'Table' then
        local converted = convert_table(block, following)
        if converted.t then
          result:insert(converted)
        else
          result:extend(converted)
        end
        i = i + 1
      else
        warn('表の見出し ![t:...] の直後に、表が見つかりませんでした（番号は付けません）')
      end
      changed = true
    elseif block.t == 'Table' and (FORMAT:match('latex') or FORMAT == 'docx')
        and not has_class(block, 'reportmd-plain') then
      result:extend(numberless_table(block))
      changed = true
    elseif FORMAT == 'docx' and i > 1 and code_blocks_meet(blocks[i - 1], block) then
      -- 続けて書いたコードブロックは、間に空きの段落を入れて、別々の枠にする
      -- （Word は、罫線の設定が同じ段落が隣り合うと、1つの枠にまとめる）。
      -- 引用の最後のコードと、そのすぐ後のコードも同じ
      result:insert(docx_space(1))
      result:insert(block)
      changed = true
    else
      result:insert(block)
    end
    i = i + 1
  end
  if changed then
    return result
  end
end

-- ---------------------------------------------------------------------
-- 図表の参照（@名前 -> 図1）
-- ---------------------------------------------------------------------
--
-- 図は画像の {#名前}、表は ![t:...]{#名前} で名前を付け、本文で @名前 と書くと、
-- 「図1」「表2」のように、ラベルと番号に置き換える。
-- Pandoc は @名前 を引用（Cite）として読むので、Cite を置き換える。

local labels = {} -- 名前 -> 「図1」など

-- 番号を付ける前に、文書を先頭から見て、名前と番号の対応を作る。
-- 番号の付け方は convert_blocks と同じ（画像だけの図の行と、直後に表がある表の見出し）。
local function collect_labels(doc)
  local figure, tbl = 0, 0
  local blocks = doc.blocks
  for i, block in ipairs(blocks) do
    if block.t == 'Div' and has_class(block, 'reportmd-figure') then
      local image, _, id = figure_parts(block)
      if image ~= nil then
        figure = figure + 1
        if id ~= '' and labels[id] == nil then
          labels[id] = settings.figure_label .. figure
          targets['figure' .. figure] = id
        end
      end
    elseif block.t == 'Div' and has_class(block, 'reportmd-table-caption')
        and blocks[i + 1] ~= nil and blocks[i + 1].t == 'Table' then
      tbl = tbl + 1
      if block.identifier ~= '' and labels[block.identifier] == nil then
        labels[block.identifier] = settings.table_label .. tbl
        targets['table' .. tbl] = block.identifier
      end
    end
  end
end

-- 名前に対応するラベルと、名前のあとに続いていた文字、使った名前を返す。
-- 「@sysに示す」のように、名前の直後に日本語が続くと、Pandoc は「sysに示す」までを
-- 名前として読む。そこで、名前が見つからなければ、先頭が一致する一番長い名前を使い、
-- 残り（「に示す」）はそのまま本文に戻す。
local function resolve_label(id)
  if labels[id] ~= nil then
    return labels[id], '', id
  end
  local best = nil
  for name, _ in pairs(labels) do
    if #name < #id and id:sub(1, #name) == name and id:sub(#name + 1):match('^[\194-\244]')
        and (best == nil or #name > #best) then
      best = name
    end
  end
  if best ~= nil then
    return labels[best], id:sub(#best + 1), best
  end
  return nil
end

-- @名前（[@名前]、[@a; @b] も）を、「図1」などに置き換える。
-- 見つからない名前は、警告して @名前 のまま残す。
-- 置き換えた「図1」は、参照先へのリンク（PDF 内で、クリックするとその図表・数式へ移動する）にする。
local function convert_cite(cite)
  local result = pandoc.List({})
  for i, citation in ipairs(cite.citations) do
    if i > 1 then
      result:insert(pandoc.Str('、'))
    end
    local label, rest, name = resolve_label(citation.id)
    if label == nil then
      warn('参照先の図表・数式が見つかりません: @' .. citation.id .. '（{#' .. citation.id .. '} で名前を付けてください）')
      result:insert(pandoc.Str('@' .. citation.id))
    else
      if FORMAT == 'pptx' then
        result:insert(pandoc.Str(label)) -- PowerPoint では、図表・数式の位置へのリンクにできない
      else
        result:insert(pandoc.Link({ pandoc.Str(label) }, '#' .. name))
      end
      if rest ~= '' then
        result:insert(pandoc.Str(rest))
      end
    end
  end
  return result
end

-- ---------------------------------------------------------------------
-- 数式の番号（$$ 〜 $$ -> 右端に (1)）
-- ---------------------------------------------------------------------
--
-- 独立した数式（DisplayMath）には、文書全体の通し番号を付ける。
-- 前処理は、閉じの $$ の後ろの {#名前} / {-} を、数式の直後の空のスパン
-- []{.reportmd-equation #名前 line="行番号"}（{-} なら .unnumbered）に変換している。
--
-- Pandoc の Inlines の走査は、入れ子の内側から先に進むので、文書の順になるとは
-- 限らない。そこで、文書の順に呼ばれる Math の走査で、数式を通し番号（index）つきの
-- スパンに包み、そのあとで目印のスパンを読み、番号を決める。

local EQUATION_CLASS = 'reportmd-math'
local equation_numbers = {} -- index -> 番号（番号なしの数式は入らない）

local function is_marker(el)
  return el ~= nil and el.t == 'Span' and has_class(el, 'reportmd-equation')
end

local function number_equations(doc)
  local count = 0
  doc = doc:walk({
    Math = function(math)
      if math.mathtype == 'DisplayMath' then
        count = count + 1
        return pandoc.Span({ math }, { class = EQUATION_CLASS, index = tostring(count) })
      end
    end,
  })

  -- 数式の直後の目印を読み、取り除く（数式のない目印も取り除く）
  local marks = {} -- index -> 目印のスパン
  doc = doc:walk({
    Inlines = function(inlines)
      local result = pandoc.List({})
      for i, el in ipairs(inlines) do
        if is_marker(el) then
          local before = inlines[i - 1]
          if before ~= nil and before.t == 'Span' and has_class(before, EQUATION_CLASS) then
            marks[before.attributes.index] = el
          end
        else
          result:insert(el)
        end
      end
      return result
    end,
  })

  local number = 0
  for index = 1, count do
    local mark = marks[tostring(index)]
    if settings.equation_numbering ~= 'false' and not (mark and has_class(mark, 'unnumbered')) then
      number = number + 1
      equation_numbers[tostring(index)] = number
      if mark and mark.identifier ~= '' and labels[mark.identifier] == nil then
        labels[mark.identifier] = settings.equation_label .. '(' .. number .. ')'
        targets['equation' .. index] = mark.identifier
      end
    elseif mark and mark.identifier ~= '' then
      warn('数式に番号を付けない設定（equation.numbering が false）なので、名前 #' .. mark.identifier
        .. ' では参照できません', mark.attributes.line)
    end
  end
  return doc
end

-- 番号の付いた数式を、右端に (番号) のある数式にする。
-- 数式の最後の行が % のコメントでも番号が消えないように、\tag の前で改行する。
local function convert_span(span)
  -- Word では、数式を含む段落ごと変換する（convert_para）
  if not has_class(span, EQUATION_CLASS) or FORMAT == 'docx' then
    return nil
  end
  local math = span.content[1]
  local number = equation_numbers[span.attributes.index]
  if number == nil then
    return math
  end
  local mark = anchor('equation' .. span.attributes.index)
  if FORMAT:match('latex') then
    -- 末尾の改行は取り除く（空行が入ると、数式の中で段落が切れてエラーになる）
    local text = math.text:gsub('%s+$', '')
    return with_anchor(mark, { pandoc.RawInline('latex', '\\[' .. text .. '\n\\tag{' .. number .. '}\\]') })
  end
  return with_anchor(mark, { math, pandoc.Space(), pandoc.Str('(' .. number .. ')') })
end

-- Word：独立した数式を、中央揃えの段落にする。番号が付く数式は、罫線のない3列の表
-- （空き・数式・番号）にして、番号を右端に置く（Word の数式は、ほかの文字と同じ段落に置くと
-- 文中の数式の小さな組み方になるため）。
local function docx_equation(span)
  local equation = styled('reportmd Equation', { pandoc.Para({ span.content[1] }) })
  local number = equation_numbers[span.attributes.index]
  if number == nil then
    return equation
  end
  local label = with_anchor(anchor('equation' .. span.attributes.index), { pandoc.Str('(' .. number .. ')') })
  return plain_table({ {
    {},
    { equation },
    { styled('reportmd Equation Number', { pandoc.Para(label) }) },
  } }, { 0.15, 0.7, 0.15 }, { pandoc.AlignDefault, pandoc.AlignCenter, pandoc.AlignRight })
end

-- 段落の先頭・末尾の空白と改行を取り除く
local function trim_inlines(inlines)
  local blank = { Space = true, SoftBreak = true, LineBreak = true }
  while #inlines > 0 and blank[inlines[1].t] do
    inlines:remove(1)
  end
  while #inlines > 0 and blank[inlines[#inlines].t] do
    inlines:remove(#inlines)
  end
  return inlines
end

-- 文中の数式だけの段落か（前後の空白は取り除いたもの）。
-- Word は、ほかの文字のない段落の数式を、独立した数式（大きな組み方）にする。
local function inline_math_alone(inlines)
  return #inlines == 1 and inlines[1].t == 'Math' and inlines[1].mathtype == 'InlineMath'
end

-- Word：段落を、独立した数式の前後で分ける（style は最初の部分のスタイル。nil なら標準）。
-- 数式のあとに続く部分は、PDF では同じ段落の続きなので、字下げしない。
-- 文中の数式だけの段落（表のセルなど）は、PDF と同じ文中の数式の組み方にするため、
-- 数式の後ろに幅のない空白（U+200B）を足す。
-- 独立した数式がなく、style も nil で、文中の数式だけの段落でもなければ nil を返す。
local function docx_paragraphs(make, content, style)
  local blocks = pandoc.List({})
  local part = pandoc.List({})
  local found = false
  local function flush()
    trim_inlines(part)
    if inline_math_alone(part) then
      part:insert(pandoc.Str('\u{200B}'))
    end
    if #part > 0 then
      local block = make(part)
      blocks:insert(style and styled(style, { block }) or block)
    end
    part = pandoc.List({})
    style = 'reportmd Continuation'
  end
  for _, el in ipairs(content) do
    if el.t == 'Span' and has_class(el, EQUATION_CLASS) then
      found = true
      flush()
      blocks:insert(docx_equation(el))
    else
      part:insert(el)
    end
  end
  if not found and style == nil and not inline_math_alone(trim_inlines(pandoc.List(part))) then
    return nil
  end
  flush()
  return blocks
end

-- 先頭の 2 スペース（前処理が []{.reportmd-indent} にしたもの）を、
-- 字下げ 1 文字分の段落に変換する。paragraph_indent は使わない（置き換え）。
local function convert_para(para)
  local content = para.content
  local first = content[1]
  local indented = first ~= nil and first.t == 'Span' and has_class(first, 'reportmd-indent')
  if indented then
    content = pandoc.List(content)
    content:remove(1)
  end
  if FORMAT == 'docx' then
    return docx_paragraphs(pandoc.Para, content, indented and 'reportmd Indent' or nil)
  end
  if not indented then
    return nil
  end
  if FORMAT:match('latex') then
    content:insert(1, pandoc.RawInline('latex', '\\noindent\\hspace*{\\reportmdchar}'))
  end
  return pandoc.Para(content)
end

-- リストの項目などの段落（Plain）も、Word では数式の前後で分ける
local function convert_plain(plain)
  if FORMAT == 'docx' then
    return docx_paragraphs(pandoc.Plain, plain.content, nil)
  end
end

-- ---------------------------------------------------------------------
-- コードブロック
-- ---------------------------------------------------------------------
--
-- 構文の色は、言語名（```python など）を書いたコードに、Pandoc が付ける
-- （code.highlight が false なら、internal/build が Pandoc に --no-highlight を渡す）。
-- PDF は reportmdcode 環境（プリアンブルで背景・枠・文字サイズを決める）で囲み、
-- HTML は .reportmd-code の div で囲んで、その書式を header-includes の CSS で決める。
-- Word は雛形のスタイル（Source Code）で決める。続けて書いたコードブロックの間には、
-- 空きの段落を入れる（Word は、罫線の設定が同じ段落が隣り合うと、1つの枠にまとめるため）。

local CODE_CLASS = 'reportmd-code'
local html_code_used = false

-- HTML：囲みの div（.reportmd-code）の書式。Pandoc の標準の CSS（言語名付きのコードの
-- pre > code.sourceCode { white-space: pre; } や、行の高さ line-height: 1.25）より強い指定で、
-- 前後の空きをなくし、長い行を折り返し、文字サイズ・行送りを囲みのものにする。
local function html_code_css()
  local box = 'margin: 1em 0; padding: ' .. settings.code_padding .. 'pt; font-size: '
    .. settings.code_font_size .. 'pt; line-height: ' .. settings.code_line_height .. 'pt;'
  if settings.code_background ~= '' then
    box = box .. ' background: #' .. settings.code_background .. ';'
  end
  if settings.code_border ~= '' then
    box = box .. ' border: ' .. settings.code_border .. ' solid #' .. settings.code_border_color .. ';'
  end
  local c = '.' .. CODE_CLASS
  return table.concat({
    '<style>',
    c .. ' { ' .. box .. ' }',
    c .. ' div.sourceCode, ' .. c .. ' pre { margin: 0; overflow: visible; background: none; }',
    c .. ' pre, ' .. c .. ' pre code, ' .. c .. ' pre > code.sourceCode'
      .. ' { white-space: pre-wrap; overflow-wrap: anywhere; font-size: inherit; }',
    c .. ' pre > code.sourceCode > span { line-height: inherit; }',
    '</style>',
  }, '\n')
end

-- 文中のコード（`...`）。背景は code_inline_background（code.background を少し濃くした色。空なら付けない）。
-- PDF は \reportmdinlinecodestart 〜 \reportmdinlinecodeend（プリアンブルで定義）で囲む。
-- 引数を取る命令にしないのは、言語名付きのコード（Pandoc の \VERB）を中に置けるようにするため。
-- 言語名のないコードは、空白で語に分け、空白の1文字ごとに \reportmdinlinecodespace を置く。
-- 空白は箱に入れず、背景の色を敷いた伸び縮みするアキにするので、そこで行を折り返せ、
-- 行をそろえるときには本文の空白と同じように伸び縮みし、行末では消える。
-- 言語名付きのコードは、分けると構文の色が変わるので、分けない。
-- HTML は header-includes の CSS で決める。
-- Word は、Pandoc が文中のコードにもコードブロックの文字にも同じスタイル（Verbatim Char）を使うので、
-- 言語名のないコードを、文中のコード用の文字スタイル（reportmd Inline Code。雛形で背景を付ける）の
-- Span（custom-style）にする。Pandoc が run を書くので、外側の太字・斜体なども付く。
local html_inline_code_used = false

local function convert_code(code)
  if settings.code_inline_background == '' then
    return nil
  end
  if FORMAT == 'docx' then
    if #code.classes > 0 then
      return nil
    end
    return pandoc.Span({ pandoc.Str(code.text) }, { ['custom-style'] = 'reportmd Inline Code' })
  end
  if FORMAT:match('latex') then
    local result = { pandoc.RawInline('latex', '\\reportmdinlinecodestart{}') }
    if #code.classes > 0 then
      table.insert(result, code)
    else
      for word, spaces in code.text:gmatch('(%S*)(%s*)') do
        if word ~= '' then
          table.insert(result, pandoc.Code(word, code.attr))
        end
        for _ = 1, #spaces do -- %s は ASCII の空白だけなので、バイト数が文字数
          table.insert(result, pandoc.RawInline('latex', '\\reportmdinlinecodespace{}'))
        end
      end
    end
    table.insert(result, pandoc.RawInline('latex', '\\reportmdinlinecodeend{}'))
    return result
  end
  if FORMAT:match('^html') then
    html_inline_code_used = true
  end
end

-- 和文の文字（仮名・漢字。句読点・括弧は除く）か
local function is_cjk_letter(c)
  return (c >= 0x3041 and c <= 0x30FF and c ~= 0x30FB) -- 仮名と長音（中黒は除く）
    or (c >= 0x3005 and c <= 0x3007) or c == 0x303B -- 々 〆 〇 〻
    or (c >= 0x3400 and c <= 0x9FFF) -- 漢字
    or (c >= 0xF900 and c <= 0xFAFF)
    or (c >= 0x20000 and c <= 0x3FFFF) -- 拡張漢字（第2面・第3面）
    or (c >= 0xFF10 and c <= 0xFF19) or (c >= 0xFF21 and c <= 0xFF3A) or (c >= 0xFF41 and c <= 0xFF5A) -- 全角の英数字
    or (c >= 0xFF66 and c <= 0xFF9F) -- 半角カナ
end

local function str_edge_is_cjk(el, last)
  if el == nil or el.t ~= 'Str' or el.text == '' then
    return false
  end
  local ok, c = pcall(utf8.codepoint, el.text, last and utf8.offset(el.text, -1) or 1)
  return ok and is_cjk_letter(c)
end

-- PDF：文中のコードの背景の箱は、xeCJK から見ると文字ではないので、和文の文字と接していても、
-- 和文と欧文の間のアキ（\CJKecglue）が入らない。和文の文字と接する側に、自分で入れる。
local function space_inline_code(inlines)
  if not FORMAT:match('latex') or settings.code_inline_background == '' then
    return nil
  end
  local result = pandoc.Inlines({})
  local changed = false
  for i, el in ipairs(inlines) do
    local glue_after = false
    if el.t == 'RawInline' and el.text == '\\reportmdinlinecodestart{}' and str_edge_is_cjk(inlines[i - 1], true) then
      -- 和文の文字の直後の \CJKecglue は、xeCJK が取り除くので、{} で区切る
      result:insert(pandoc.RawInline('latex', '{}\\CJKecglue{}'))
      changed = true
    elseif el.t == 'RawInline' and el.text == '\\reportmdinlinecodeend{}' and str_edge_is_cjk(inlines[i + 1], false) then
      glue_after = true
    end
    result:insert(el)
    if glue_after then
      result:insert(pandoc.RawInline('latex', '\\CJKecglue{}'))
      changed = true
    end
  end
  if changed then
    return result
  end
end

local function convert_code_block(code)
  if FORMAT:match('latex') then
    return {
      pandoc.RawBlock('latex', '\\begin{reportmdcode}'),
      code,
      pandoc.RawBlock('latex', '\\end{reportmdcode}'),
    }
  end
  if FORMAT:match('^html') then
    html_code_used = true
    return pandoc.Div({ code }, { class = CODE_CLASS })
  end
end

-- HTML：文中のコード（pre の中でない code）の背景
local function html_inline_code_css()
  return ':not(pre) > code { background: #' .. settings.code_inline_background
    .. '; padding: 0.1em 0.25em; border-radius: 0.2em; }'
end

-- HTML：コードブロック・文中のコードがあれば、その書式（CSS）を header-includes で1回だけ出す
local function add_code_css(doc)
  local css = {}
  if html_code_used then
    table.insert(css, html_code_css())
  end
  if html_inline_code_used then
    table.insert(css, '<style>\n' .. html_inline_code_css() .. '\n</style>')
  end
  if #css == 0 then
    return nil
  end
  doc.meta['header-includes'] = pandoc.MetaBlocks({ pandoc.RawBlock('html', table.concat(css, '\n')) })
  return doc
end

-- ---------------------------------------------------------------------
-- 脚注（PowerPoint）
-- ---------------------------------------------------------------------
--
-- Pandoc は、脚注を最後の「Notes」という題名のスライドにまとめる。
-- 題名を「注」にするため、脚注を番号（上付き）に置き換え、最後に自分でスライドを作る。

local notes = pandoc.List({}) -- 脚注の内容（Blocks）を、文書の順に

local function convert_note(note)
  if FORMAT ~= 'pptx' then
    return nil
  end
  notes:insert(note.content)
  return pandoc.Superscript({ pandoc.Str(tostring(#notes)) })
end

local function add_notes(doc)
  if #notes == 0 then
    return nil
  end
  doc.blocks:insert(pandoc.Header(1, { pandoc.Str('注') }))
  doc.blocks:insert(pandoc.OrderedList(notes))
  return doc
end

-- 設定を読み、図表・数式の名前と番号の対応を作る走査を先に行い、そのあとで変換の走査を行う。
return {
  {
    Meta = function(meta)
      read_settings(meta)
      read_cover(meta)
    end,
    Pandoc = function(doc)
      collect_labels(doc)
      return number_equations(doc)
    end,
  },
  {
    Meta = move_title_and_author,
    Div = convert_div,
    Header = convert_header,
    Para = convert_para,
    Plain = convert_plain,
    Span = convert_span,
    Cite = convert_cite,
    Note = convert_note,
    CodeBlock = convert_code_block,
    Code = convert_code,
    Inlines = space_inline_code,
    Blocks = convert_blocks,
  },
  -- 表紙は、本文の変換が終わってから先頭に置く（表紙の値は本文の変換の対象にしない）
  {
    Pandoc = function(doc)
      doc = add_cover(doc) or doc
      doc = add_code_css(doc) or doc
      return add_notes(doc) or doc
    end,
  },
}
