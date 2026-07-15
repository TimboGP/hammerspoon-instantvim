--- slack.lua — bespoke rich-text adapter for Slack (com.tinyspeck.slackmacgap).
---
--- PROTOTYPE. Slack does not fit the profile model's assumption that an app
--- publishes a standard rich UTI: its composer publishes only
--- public.utf8-plain-text (formatting stripped) plus Chromium internals. The
--- actual formatting lives in a Quill Delta under a `slack/texty` custom MIME
--- type wrapped inside `org.chromium.web-custom-data`. So capture is bespoke:
--- unwrap the Chromium pickle, pull out slack/texty, and convert the Delta to
--- Markdown.
---
--- Write-back is asymmetric and deliberately simple: Slack's composer (Quill)
--- converts *pasted HTML* back into its own format, so we reuse the generic
--- HTML write path (pandoc gfm->html) rather than reconstructing a Delta +
--- pickle. The one wrinkle is strikethrough: Quill recognizes <s>, but pandoc
--- emits <del>, so the write rep rewrites the tag. See wishlist.md.

local M = {}

-- ---------------------------------------------------------------------------
-- Chromium web-custom-data (base::Pickle) parsing
-- ---------------------------------------------------------------------------
-- Layout: [uint32 payloadSize][uint32 entryCount] then entryCount pairs of
-- WriteString16(key), WriteString16(value). WriteString16 = uint32 length (in
-- UTF-16 code units) + 2*length bytes UTF-16LE, padded to 4-byte alignment
-- (relative to the payload start, i.e. after the 4-byte header).

local function u32le(s, o)
  local b1, b2, b3, b4 = s:byte(o, o + 3)
  if not b4 then return nil end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function utf16leToUtf8(s, o, nchars)
  local t = {}
  local i = 0
  while i < nchars do
    local lo, hi = s:byte(o + i * 2, o + i * 2 + 1)
    if not hi then break end
    local cp = lo + hi * 256
    i = i + 1
    if cp >= 0xD800 and cp <= 0xDBFF and i < nchars then -- surrogate pair
      local lo2, hi2 = s:byte(o + i * 2, o + i * 2 + 1)
      local cp2 = (lo2 or 0) + (hi2 or 0) * 256
      i = i + 1
      cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
    end
    if cp < 0x80 then
      t[#t + 1] = string.char(cp)
    elseif cp < 0x800 then
      t[#t + 1] = string.char(0xC0 + cp // 0x40, 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
      t[#t + 1] = string.char(0xE0 + cp // 0x1000, 0x80 + (cp // 0x40) % 0x40, 0x80 + cp % 0x40)
    else
      t[#t + 1] = string.char(0xF0 + cp // 0x40000, 0x80 + (cp // 0x1000) % 0x40,
        0x80 + (cp // 0x40) % 0x40, 0x80 + cp % 0x40)
    end
  end
  return table.concat(t)
end

--- Extract the value stored under `wantKey` in a Chromium web-custom-data
--- pickle, or nil if absent/malformed.
function M.extractCustomData(data, wantKey)
  if not data or #data < 8 then return nil end
  local base = 5 -- payload starts after the 4-byte pickle header
  local o = base
  local count = u32le(data, o); o = o + 4
  if not count or count > 64 then return nil end -- sanity guard
  local function readString16()
    local len = u32le(data, o); o = o + 4
    if not len or len * 2 > #data then return nil end
    local str = utf16leToUtf8(data, o, len)
    o = o + len * 2
    local rel = o - base
    o = o + ((4 - (rel % 4)) % 4) -- pad to 4-byte alignment
    return str
  end
  for _ = 1, count do
    local key = readString16(); if key == nil then return nil end
    local val = readString16(); if val == nil then return nil end
    if key == wantKey then return val end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Quill Delta -> Markdown
-- ---------------------------------------------------------------------------

-- Wrap `text` with Markdown for its inline attributes. code is innermost so
-- its backticks aren't themselves interpreted; link is outermost.
local function renderInline(text, attrs)
  if text == "" then return "" end
  attrs = attrs or {}
  local s = text
  if attrs.code then s = "`" .. s .. "`" end
  if attrs.strike then s = "~~" .. s .. "~~" end
  if attrs.italic then s = "*" .. s .. "*" end
  if attrs.bold then s = "**" .. s .. "**" end
  if attrs.underline then s = "<u>" .. s .. "</u>" end
  if attrs.link then s = "[" .. s .. "](" .. tostring(attrs.link) .. ")" end
  return s
end

-- Split a string on "\n", keeping empty trailing/leading segments so newline
-- count is preserved: "a\nb\n" -> {"a","b",""}.
local function splitLines(str)
  local parts, start = {}, 1
  while true do
    local nl = str:find("\n", start, true)
    if not nl then parts[#parts + 1] = str:sub(start); break end
    parts[#parts + 1] = str:sub(start, nl - 1)
    start = nl + 1
  end
  return parts
end

--- Convert a decoded Quill Delta table ({ ops = {...} }) to Markdown.
function M.deltaToMarkdown(delta)
  local ops = delta and delta.ops
  if type(ops) ~= "table" then return nil end

  -- Build a flat list of lines: { rendered = <inline md>, raw = <plain>,
  -- block = <block attrs table> }. Quill puts inline attrs on text ops and
  -- line/block attrs on the newline op that terminates the line.
  local lines = {}
  local curRendered, curRaw = {}, {}
  local function closeLine(block)
    lines[#lines + 1] = {
      rendered = table.concat(curRendered),
      raw = table.concat(curRaw),
      block = block or {},
    }
    curRendered, curRaw = {}, {}
  end

  for _, op in ipairs(ops) do
    local insert = op.insert
    if type(insert) == "string" then
      local attrs = op.attributes or {}
      local segs = splitLines(insert)
      for idx, seg in ipairs(segs) do
        if idx > 1 then closeLine(attrs) end -- a "\n" preceded this segment
        if seg ~= "" then
          curRendered[#curRendered + 1] = renderInline(seg, attrs)
          curRaw[#curRaw + 1] = seg
        end
      end
    end
    -- non-string inserts (emoji/image embeds) are skipped
  end
  if #curRendered > 0 or #curRaw > 0 then closeLine({}) end

  -- Render lines to Markdown, grouping consecutive list / code-block /
  -- blockquote lines into single blocks; everything else is a paragraph.
  local out, i = {}, 1
  while i <= #lines do
    local b = lines[i].block or {}
    if b["code-block"] then
      local buf = {}
      while i <= #lines and (lines[i].block or {})["code-block"] do
        buf[#buf + 1] = lines[i].raw; i = i + 1
      end
      out[#out + 1] = "```\n" .. table.concat(buf, "\n") .. "\n```"
    elseif b.list then
      -- group only same-type list lines, so an adjacent bullet then ordered
      -- list become two separate lists rather than one merged block
      local listType, buf, n = b.list, {}, 0
      while i <= #lines and (lines[i].block or {}).list == listType do
        if listType == "ordered" then
          n = n + 1; buf[#buf + 1] = n .. ". " .. lines[i].rendered
        else
          buf[#buf + 1] = "- " .. lines[i].rendered
        end
        i = i + 1
      end
      out[#out + 1] = table.concat(buf, "\n")
    elseif b.blockquote then
      local buf = {}
      while i <= #lines and (lines[i].block or {}).blockquote do
        buf[#buf + 1] = "> " .. lines[i].rendered; i = i + 1
      end
      out[#out + 1] = table.concat(buf, "\n")
    else
      out[#out + 1] = lines[i].rendered
      i = i + 1
    end
  end

  -- drop trailing empty paragraphs (Delta usually ends with a bare "\n")
  while #out > 0 and out[#out]:match("^%s*$") do out[#out] = nil end
  return table.concat(out, "\n\n")
end

--- captureFn for the profile: raw web-custom-data bytes -> Markdown, or nil.
function M.capture(data, _opts)
  local texty = M.extractCustomData(data, "slack/texty")
  if not texty then return nil end
  local ok, delta = pcall(function() return hs.json.decode(texty) end)
  if not ok or not delta then return nil end
  local md = M.deltaToMarkdown(delta)
  if md and md:match("%S") then return md end
  return nil
end

-- Quill recognizes <s> for strikethrough on paste; pandoc emits <del>.
local function slackHtmlFixup(html)
  return (html:gsub("<del>", "<s>"):gsub("</del>", "</s>"))
end

--- The profile injected into richtext.profiles.slack by init.lua. Capture is
--- the bespoke Delta path; write-back reuses the generic HTML rep (Slack's
--- Quill converts pasted HTML), with the strikethrough tag fixup.
M.profile = {
  captureReps = { { uti = "org.chromium.web-custom-data", captureFn = M.capture } },
  writeReps = { { uti = "public.html", to = "html", standalone = false, post = slackHtmlFixup } },
}

return M
