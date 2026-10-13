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
--   2 スペース始まりの段落   ->  字下げ 1 文字分（paragraph_indent の置き換え）
--   見出し                    ->  #1〜#3（.reportmd-num）は番号付き、
--                                 標準の #（クラスなし）は番号なしにする
--   title / author            ->  PDF のメタデータにだけ使い、本文には出さない
--
-- 設定（builder.rb が metadata の reportmd に入れて渡す）:
--   figure_label / table_label       図・表のラベル文字列（既定：図・表）
--   figure_position / table_position キャプションの位置 top / bottom

local function has_class(el, name)
  for _, class in ipairs(el.classes) do
    if class == name then
      return true
    end
  end
  return false
end

local function warn(message)
  io.stderr:write('reportmd(filter): warning: ' .. message .. '\n')
end

-- ---------------------------------------------------------------------
-- 設定の読み込み（最初の走査）
-- ---------------------------------------------------------------------

local settings = {
  figure_label = '図',
  table_label = '表',
  figure_position = 'bottom',
  table_position = 'top',
}

local function read_settings(meta)
  local given = meta.reportmd
  if given == nil then
    return
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

local function move_title_and_author(meta)
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
    warn('図の行には、画像だけを書いてください（番号は付けません）')
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

-- LaTeX：表のキャプションは、中央に置く。表との間で、ページが分かれないようにする。
local function latex_table(tbl, caption, position)
  local text = pandoc.Plain(caption)
  local caption_blocks = pandoc.List({
    pandoc.RawBlock('latex', '\\begin{center}'),
    text,
    pandoc.RawBlock('latex', '\\end{center}'),
  })
  local blocks = pandoc.List({})
  if position == 'bottom' then
    blocks:insert(tbl)
    blocks:extend(caption_blocks)
  else
    blocks:extend(caption_blocks)
    blocks:insert(pandoc.RawBlock('latex', '\\nopagebreak[4]'))
    blocks:insert(tbl)
  end
  return blocks
end

local function convert_table(caption_div, tbl)
  local title = pandoc.List()
  if #caption_div.content > 0 then
    title = pandoc.utils.blocks_to_inlines(caption_div.content)
  end
  counters.table = counters.table + 1
  local caption = make_caption(settings.table_label, counters.table, title)

  if FORMAT:match('latex') then
    tbl.caption.long = pandoc.Blocks({}) -- 表に付いていたキャプションは使わない
    tbl.caption.short = nil
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
