--- richtext.lua — rich-text (formatted) round-trip for instantvim.
---
--- PROTOTYPE. See wishlist.md ("Formatted (rich text) content") for the full
--- rationale and known limits. Bridges instantvim's plain-text-in-nvim model
--- to apps that carry formatting on the pasteboard under a typed UTI (RTF
--- today; HTML is a natural next profile). The user still edits *Markdown* in
--- nvim -- conversion to/from the rich UTI happens only at the pasteboard
--- edge, via pandoc.
---
--- This path is inherently Tier B (paste-on-quit): the AX write attributes
--- (AXValue / AXSelectedText) are plain strings, so rich content can only be
--- delivered through the pasteboard + Cmd+V -- even for fields that are
--- otherwise Tier A. Live (Tier A) rich write-back is therefore impossible,
--- as noted in wishlist.md.

local M = {}

-- Converter profiles. config.contentTypeByBundleID maps a bundle ID to one of
-- these names; nil (the default for every app) means plain text, the
-- universal fallback. Each profile names the pasteboard UTI that carries the
-- formatting and the pandoc format tokens used to convert it to/from the
-- Markdown edited in nvim.
-- A profile is an ordered list of representations (`reps`). Each rep:
--   `uti`        pasteboard type it reads/writes
--   `from`/`to`  pandoc format tokens for that UTI
--   `standalone` pass pandoc `-s` on write-back? RTF needs its document
--                header; HTML wants a bare fragment (a full <!DOCTYPE>/<head>
--                document pastes badly into contentEditable).
--
-- Rep order is priority order. On CAPTURE the first rep whose UTI is actually
-- on the pasteboard wins (prefer richest, fall back) -- so an app mapped to
-- one profile still works if it only publishes the other's UTI. On WRITE-BACK
-- every rep is produced and written together (see buildPasteboard), so the
-- target app picks whichever it understands: a native field takes the RTF, a
-- web field takes the HTML, from a single write. The two profiles below
-- therefore differ only in which representation they prefer on capture.
local REP_RTF = { uti = "public.rtf", from = "rtf", to = "rtf", standalone = true }
local REP_HTML = { uti = "public.html", from = "html", to = "html", standalone = false }
M.profiles = {
  rtf = { reps = { REP_RTF, REP_HTML } },
  html = { reps = { REP_HTML, REP_RTF } },
}

-- Built on markdown_strict (rather than gfm) plus gfm's own extensions
-- spelled out individually, MINUS escaped_line_breaks. gfm hardcodes that
-- extension on with no way to turn it off, which makes its writer render
-- every hard line break (<br>) as a trailing backslash -- glaringly visible
-- clutter for content that has one on every line (e.g. Apple Mail's
-- div-per-line compose body, see pandoc-html-filter.lua). markdown_strict
-- leaves escaped_line_breaks off by default, so the writer falls back to
-- CommonMark's other valid hard-break syntax -- two trailing spaces --
-- which is invisible in the buffer and round-trips identically.
-- --wrap=none keeps paragraphs on one line so soft-wrapped prose doesn't
-- pick up hard line breaks on the round-trip.
M.flavor = "markdown_strict+alerts+autolink_bare_uris+emoji+footnotes"
  .. "+gfm_auto_identifiers+pipe_tables+strikeout+task_lists"
  .. "+tex_math_dollars+yaml_metadata_block+raw_html"

local function shQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function writeBytes(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data or "")
  f:close()
  return true
end

local function tmpPath(opts, ext)
  return string.format("%s/instantvim-rt-%s.%s", opts.tempDir or "/tmp", hs.host.uuid(), ext)
end

-- Resolve pandoc to an absolute path ONCE (via the login shell, so it picks
-- up PATH from your shell profile -- Hammerspoon.app itself runs with the
-- bare system PATH, no /opt/homebrew/bin), then cache it. Every conversion
-- afterwards runs pandoc by absolute path through a plain (non-login)
-- hs.execute, which is milliseconds rather than the ~2.5s it costs to source
-- a shell profile on every call -- and these run synchronously on
-- Hammerspoon's main thread. Same trick as init.lua's resolveNvimPath.
-- Keyed by the requested path so a bogus pandocPath isn't masked by a
-- previously-cached good one (the availability check must actually detect a
-- missing pandoc). Only successful resolutions are cached: a negative result
-- isn't, so installing pandoc mid-session is picked up without a reload.
--
-- `command -v` validates existence/executability either way and echoes the
-- resolved path. A bare name needs the login shell to pick up PATH from your
-- profile (Hammerspoon.app runs with the bare system PATH); an absolute path
-- doesn't, so it skips the ~2.5s profile-sourcing cost -- but is still
-- checked, so a nonexistent absolute pandocPath correctly reports missing.
local resolvedCache = {}
local function resolvePandoc(opts)
  local p = (opts and opts.pandocPath) or "pandoc"
  if resolvedCache[p] then return resolvedCache[p] end
  local viaLoginShell = p:sub(1, 1) ~= "/"
  local out = hs.execute("command -v " .. shQuote(p), viaLoginShell)
  if out and out:match("%S") then
    resolvedCache[p] = (out:gsub("%s+$", ""))
    return resolvedCache[p]
  end
  return nil
end

-- Run pandoc reading `inputPath`, returning stdout, or nil on failure.
local function pandoc(opts, args, inputPath)
  local abs = resolvePandoc(opts)
  if not abs then return nil end
  local cmd = string.format("%s %s %s", shQuote(abs), args, shQuote(inputPath))
  local out, ok = hs.execute(cmd) -- non-login: abs path already resolved
  if ok then return out end
  return nil
end

--- Whether pandoc is resolvable, so callers can warn once at start() instead
--- of silently degrading every rich field to plain text. Also warms the
--- absolute-path cache, so the first real conversion isn't the one that pays
--- the login-shell resolution cost.
function M.available(opts)
  return resolvePandoc(opts) ~= nil
end

--- The first capture rep of `profile` whose UTI is present in `availableTypes`
--- (the pasteboard's contentTypes), or nil if none is -- i.e. richest-first
--- with fallback. Lets an app mapped to one profile still capture when it only
--- publishes another's UTI. A profile may split capture vs write-back reps
--- (`captureReps`/`writeReps`); otherwise both use `reps`.
function M.captureRep(profile, availableTypes)
  local present = {}
  for _, uti in ipairs(availableTypes or {}) do present[uti] = true end
  for _, rep in ipairs(profile.captureReps or profile.reps) do
    if present[rep.uti] then return rep end
  end
  return nil
end

--- Absolute path to pandoc-html-filter.lua (see that file), or nil if
--- opts.spoonPath wasn't supplied. Only meaningful for the "html" rep --
--- the div-per-line quirk it fixes is specific to WebKit contentEditable
--- HTML, not RTF.
local function htmlFilterPath(opts)
  local dir = opts and opts.spoonPath
  if not dir then return nil end
  return dir .. "pandoc-html-filter.lua"
end

--- Rich UTI bytes -> Markdown (capture direction). A rep may supply a custom
--- `captureFn(data, opts)` (e.g. an app-specific clipboard format); otherwise
--- pandoc converts from `rep.from`. Returns nil on any failure (empty doc,
--- pandoc missing, malformed input) so the caller can fall back to plain text.
function M.toMarkdown(rep, data, opts)
  if rep.captureFn then
    local ok, md = pcall(rep.captureFn, data, opts)
    if ok and md and md:match("%S") then return md end
    return nil
  end
  local p = tmpPath(opts, "rich")
  if not writeBytes(p, data) then return nil end
  local filterArg = ""
  if rep.from == "html" then
    local filter = htmlFilterPath(opts)
    if filter then filterArg = " --lua-filter=" .. shQuote(filter) end
  end
  local md = pandoc(opts, string.format("-f %s -t %s --wrap=none%s", rep.from, M.flavor, filterArg), p)
  os.remove(p)
  if md and md:match("%S") then return md end
  return nil
end

--- Markdown -> rich UTI bytes for `rep` (write-back direction). `standalone`
--- reps get pandoc `-s` (e.g. RTF's document header); others get a bare
--- fragment. Returns nil on failure.
function M.toRich(rep, markdown, opts)
  local p = tmpPath(opts, "md")
  if not writeBytes(p, markdown) then return nil end
  local args = string.format("-f %s -t %s", M.flavor, rep.to)
  if rep.standalone then args = args .. " -s" end
  local out = pandoc(opts, args, p)
  os.remove(p)
  if not (out and out:match("%S")) then return nil end
  -- optional per-rep post-processing (e.g. target-specific tag fixups)
  if rep.post then out = rep.post(out) end
  return out
end

--- Markdown -> plain text. Used only to size the selection re-highlight after
--- a rich write-back (the raw Markdown length would count `**`/`[]()` markup
--- the rendered field doesn't show). Best-effort; nil just skips the reselect.
function M.toPlain(markdown, opts)
  local p = tmpPath(opts, "md")
  if not writeBytes(p, markdown) then return nil end
  local out = pandoc(opts, string.format("-f %s -t plain --wrap=none", M.flavor), p)
  os.remove(p)
  if out then return (out:gsub("%s+$", "")) end
  return nil
end

--- Build the pasteboard representation of `markdown` for `profile` and return
--- { data = { [uti] = bytes, ... }, plain = string } ready for
--- hs.pasteboard.writeAllData, or nil if EVERY rep's conversion failed
--- (caller then pastes plain text). Every rep that converts is included, so
--- the target app can pick whichever rich type it understands. Plain text is
--- always included: unlike RTF, writing some UTIs (e.g. public.html) does NOT
--- auto-synthesize it, so a non-rich paste target would otherwise get
--- nothing. `plain` is also the rendered text used to size the reselect.
function M.buildPasteboard(profile, markdown, opts)
  local plain = M.toPlain(markdown, opts) or markdown
  local data = { ["public.utf8-plain-text"] = plain }
  local any = false
  for _, rep in ipairs(profile.writeReps or profile.reps) do
    local rich = M.toRich(rep, markdown, opts)
    if rich then
      data[rep.uti] = rich
      any = true
    end
  end
  if not any then return nil end
  return { data = data, plain = plain }
end

return M
