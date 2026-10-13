-- reportmd 用 Pandoc Lua フィルタ
--
-- 前処理(preprocessor.rb)が出力した「クラス付きのブロック」を、
-- 出力形式ごとの組版に変換する。
--
-- 現在の対応:
--   .reportmd-pagebreak       ->  \newpage
--   .reportmd-right           ->  右揃え（flushright）
--   .reportmd-center          ->  中央揃え（center）
--   .reportmd-figure          ->  図（番号とキャプションを付ける）
--   .reportmd-table-caption   ->  直後の表に、番号とキャプションを付ける
--   表（LaTeX）               ->  tabular に組む（書式はプリアンブルの命令で決める）
--   2 スペース始まりの段落   ->  字下げ 1 文字分（paragraph_indent の置き換え）
--   見出し                    ->  #1〜#3（.reportmd-num）は番号付き、
--                                 標準の #（クラスなし）は番号なしにする
--   title / author            ->  PDF のメタデータにだけ使い、本文には出さない
--   そのほかのメタデータ      ->  取り除く（フロントマターの対応外のキーを無視する）
--
-- 設定（builder.rb が metadata の reportmd に入れて渡す）:
--   figure_label / table_label       図・表のラベル文字列（既定：図・表）
--   figure_position / table_position キャプションの位置 top / bottom
--   source                           警告に表示する入力ファイル名
--   table_width / table_header_align 表の幅（auto / full）と見出し行の揃え

local function has_class(el, name)
  for _, class in ipairs(el.classes) do
    if class == name then
      return true
    end
  end
  return false
end

-- 警告に表示する入力ファイル名（builder.rb が metadata の reportmd.source に入れて渡す）
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

-- フロントマターで使えるのは title と author だけ。ほかのキー（geometry、
-- header-includes など）は、Pandoc のテンプレートに反映されないように取り除く。
-- （警告は前処理が行番号つきで出している）
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
-- 改ページ・右揃え・中央揃え
-- ---------------------------------------------------------------------

local ALIGNMENTS = {
  ['reportmd-right']  = { latex = 'flushright', css = 'right' },
  ['reportmd-center'] = { latex = 'center',     css = 'center' },
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
    end
    return {} -- LaTeX 以外の出力では、改ページブロックを取り除く
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
local function convert_header(el)
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

-- 「図1 タイトル」。タイトルがなければ番号だけ（「図1」）。
local function make_caption(label, number, title)
  local inlines = pandoc.List({ pandoc.Str(label .. number) })
  if #title > 0 then
    inlines:insert(pandoc.Space())
    inlines:extend(title)
  end
  return inlines
end

-- 図のブロック（Div）から、画像とタイトルを取り出す。画像だけの行でなければ nil。
local function figure_parts(div)
  if #div.content ~= 1 then
    return nil
  end
  local block = div.content[1]
  if block.t == 'Figure' then
    local inner = block.content
    if #inner == 1 and (inner[1].t == 'Plain' or inner[1].t == 'Para')
        and #inner[1].content == 1 and inner[1].content[1].t == 'Image' then
      return inner[1].content[1], pandoc.utils.blocks_to_inlines(block.caption.long)
    end
  elseif block.t == 'Para' or block.t == 'Plain' then
    if #block.content == 1 and block.content[1].t == 'Image' then
      return block.content[1], pandoc.List()
    end
  end
  return nil
end

-- LaTeX：浮動体（figure 環境）にせず、書いた位置に固定する。
-- 画像とキャプションが別のページに分かれないように、samepage で囲む。
local function latex_figure(image, caption, position)
  local picture = pandoc.Plain({ pandoc.Image({}, image.src, image.title, image.attr) })
  local text = pandoc.Plain(caption)
  local gap = pandoc.RawBlock('latex', '\\vspace{0.5\\baselineskip}')
  local blocks = pandoc.List({ pandoc.RawBlock('latex', '\\begin{samepage}\\begin{center}') })
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
  if FORMAT:match('latex') then
    return latex_figure(image, caption, settings.figure_position)
  end
  local plain_image = pandoc.Image({}, image.src, image.title, image.attr)
  local figure = pandoc.Figure({ pandoc.Plain({ plain_image }) }, { long = { pandoc.Plain(caption) } })
  return pandoc.List({ figure })
end

-- ---------------------------------------------------------------------
-- 表の組版（LaTeX）
-- ---------------------------------------------------------------------
--
-- Pandoc 標準の longtable は使わず、tabular に組む。書式（罫線の有無と太さ、
-- 文字サイズ、行の高さ、セルの余白、見出しの太字）は、preamble.tex.erb が
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

-- 番号を付けない表（![t:...] のない表）も、同じ書式で組む。
-- Pandoc 標準のキャプション（: タイトル）があれば、番号なしでそのまま使う。
local function latex_plain_table(tbl)
  local caption = nil
  if #tbl.caption.long > 0 then
    caption = pandoc.utils.blocks_to_inlines(tbl.caption.long)
  end
  return latex_table(tbl, caption, settings.table_position)
end

local function convert_table(caption_div, tbl)
  local title = pandoc.List()
  if #caption_div.content > 0 then
    title = pandoc.utils.blocks_to_inlines(caption_div.content)
  end
  counters.table = counters.table + 1
  local caption = make_caption(settings.table_label, counters.table, title)

  if FORMAT:match('latex') then
    -- 表に付いていたキャプション（: タイトル）は使わない
    return latex_table(tbl, caption, settings.table_position)
  end
  tbl.caption.long = pandoc.Blocks({ pandoc.Plain(caption) })
  return tbl
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
    elseif block.t == 'Table' and FORMAT:match('latex') then
      result:extend(latex_plain_table(block))
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

-- 先頭の 2 スペース（前処理が []{.reportmd-indent} にしたもの）を、
-- 字下げ 1 文字分の段落に変換する。paragraph_indent は使わない（置き換え）。
local function convert_para(para)
  local first = para.content[1]
  if first == nil or first.t ~= 'Span' or not has_class(first, 'reportmd-indent') then
    return nil
  end
  local content = pandoc.List(para.content)
  content:remove(1)
  if FORMAT:match('latex') then
    content:insert(1, pandoc.RawInline('latex', '\\noindent\\hspace*{\\reportmdchar}'))
  end
  return pandoc.Para(content)
end

-- 設定を読む走査を先に行い、そのあとで変換の走査を行う。
return {
  { Meta = function(meta) read_settings(meta) end },
  {
    Meta = move_title_and_author,
    Div = convert_div,
    Header = convert_header,
    Para = convert_para,
    Blocks = convert_blocks,
  },
}
