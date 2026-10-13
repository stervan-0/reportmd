-- reportmd 用 Pandoc Lua フィルタ
--
-- 前処理(preprocessor.rb)が出力した「クラス付きのブロック」を、
-- LaTeX の命令に変換する。
--
-- 現在の対応:
--   .reportmd-pagebreak  ->  \newpage
--   .reportmd-right      ->  右揃え（flushright）
--   .reportmd-center     ->  中央揃え（center）
--   title / author       ->  PDF のメタデータにだけ使い、本文には出さない

local function has_class(el, name)
  for _, class in ipairs(el.classes) do
    if class == name then
      return true
    end
  end
  return false
end

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

function Meta(meta)
  move_to_pdf_metadata(meta, 'title')
  move_to_pdf_metadata(meta, 'author')
  return meta
end

-- 右揃え・中央揃えの対応表
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

function Div(el)
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
