--- pandoc-html-filter.lua — Lua filter for the HTML capture rep (richtext.lua).
---
--- WebKit contentEditable surfaces (Apple Mail's compose body chief among
--- them) represent every visual line as its own sibling <div>, with a lone
--- <br> inside otherwise-empty divs so blank lines still render with height.
--- Pandoc has no Markdown equivalent for a bare, unattributed <div>: its
--- writer falls back to preserving the literal <div>/</div> tags around
--- each one-line paragraph, and a div containing only <br> becomes a
--- standalone hard line break with nothing before or after it -- which
--- renders as a lone "\" in the output. Both artifacts are purely a
--- serialization quirk of the div-per-line DOM shape, not anything the
--- user actually wrote.
---
--- This filter runs before the Markdown writer and merges each run of
--- "one Plain block per Div" siblings into a single Para joined by real
--- LineBreak inlines, so pandoc emits one clean line of text per source
--- line instead of one raw-HTML-wrapped paragraph per line. A div whose
--- only content is a bare LineBreak (the empty-line placeholder) is
--- treated as a blank line rather than an extra break, so blank line
--- counts match the source exactly instead of being inflated by one for
--- every blank div.
---
--- Blocks that aren't this shape (real paragraphs, lists, blockquotes --
--- e.g. quoted reply chains) pass through untouched, at every nesting
--- level, since Blocks() filters run over every block list in the doc.

local function isBareBreak(inlines)
  return #inlines == 1 and inlines[1].t == "LineBreak"
end

function Blocks(blocks)
  local out = pandoc.List()
  local para = pandoc.List()

  local function flush()
    if #para > 0 then
      out:insert(pandoc.Para(para))
      para = pandoc.List()
    end
  end

  for _, blk in ipairs(blocks) do
    if blk.t == "Div" and #blk.content == 1 and blk.content[1].t == "Plain" then
      local inlines = blk.content[1].content
      if #para > 0 then para:insert(pandoc.LineBreak()) end
      if not isBareBreak(inlines) then para:extend(inlines) end
    else
      flush()
      out:insert(blk)
    end
  end
  flush()

  return out
end
