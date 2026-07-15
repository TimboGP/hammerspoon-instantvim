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
M.profiles = {
  rtf = { uti = "public.rtf", from = "rtf", to = "rtf" },
  -- html = { uti = "public.html", from = "html", to = "html" },  -- future
}

-- gfm is the most human-editable Markdown flavor pandoc emits (plain links,
-- `<u>` for underline rather than pandoc's `[...]{.underline}` span noise),
-- and --wrap=none keeps paragraphs on one line so soft-wrapped prose doesn't
-- pick up hard line breaks on the round-trip.
M.flavor = "gfm"

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

--- Rich UTI bytes -> Markdown (capture direction). Returns nil on any failure
--- (empty doc, pandoc missing, malformed input) so the caller can fall back
--- to the plain-text capture it already has.
function M.toMarkdown(profile, data, opts)
  local p = tmpPath(opts, "rich")
  if not writeBytes(p, data) then return nil end
  local md = pandoc(opts, string.format("-f %s -t %s --wrap=none", profile.from, M.flavor), p)
  os.remove(p)
  if md and md:match("%S") then return md end
  return nil
end

--- Markdown -> rich UTI bytes (write-back direction). `-s` makes pandoc emit
--- a standalone document (with the RTF header apps need). Returns nil on
--- failure so the caller can fall back to pasting plain text.
function M.toRich(profile, markdown, opts)
  local p = tmpPath(opts, "md")
  if not writeBytes(p, markdown) then return nil end
  local out = pandoc(opts, string.format("-f %s -t %s -s", M.flavor, profile.to), p)
  os.remove(p)
  if out and out:match("%S") then return out end
  return nil
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

return M
