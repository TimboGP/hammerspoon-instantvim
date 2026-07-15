--- capture.lua — AX read/probe helpers for instantvim.
---
--- Implements the three-tier capability model (handover §4.1):
---   A: AXValue readable and settable  -> live write-back
---   B: AXValue readable, not settable, OR readable only via select-all+copy
---   C: not readable at all (secure fields, or apps that refuse both AX and copy)
---
--- Secure-field detection is intentionally its own check, run before any
--- clipboard fallback is attempted: constraint #3 forbids ever keystroke-
--- scraping a secure field, so we must be certain a field is *not* secure
--- before touching Cmd+A/Cmd+C on it. AXValue simply being nil is not enough
--- on its own to prove a field is secure (an Electron surface can be non-secure
--- and still expose no AXValue), so the two checks are kept separate.

local M = {}

-- Roles/subroles macOS uses to mark secure (password) fields. These are
-- readable via AX without exposing the field's contents, so checking them
-- first never risks touching the actual (secret) value.
local SECURE_MARKERS = {
  AXSecureTextField = true,
}

local function isSecure(elem)
  local ok, subrole = pcall(function() return elem:attributeValue("AXSubrole") end)
  if ok and subrole and SECURE_MARKERS[subrole] then return true end
  local ok2, role = pcall(function() return elem:attributeValue("AXRole") end)
  if ok2 and role and SECURE_MARKERS[role] then return true end
  return false
end

-- Planted on the pasteboard before the copy fallback. If the app doesn't
-- respond to Cmd+A/Cmd+C the sentinel survives unchanged, so we can tell
-- "field is empty" apart from "field ignored our keystrokes" and refuse to
-- treat the latter as a successful capture.
local SENTINEL = "\30instantvim-capture-failed\30"

--- Returns the system-wide focused UI element, or nil if there isn't one.
function M.getFocusedElement()
  local ok, elem = pcall(function()
    return hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
  end)
  if not ok then return nil end
  return elem
end

--- Returns true if `elem` still resolves to a live accessibility object.
--- Used to guard write-back against elements destroyed mid-edit (e.g. the
--- source tab was closed) so we degrade to paste instead of erroring.
function M.isElementAlive(elem)
  if not elem then return false end
  local ok, role = pcall(function() return elem:attributeValue("AXRole") end)
  return ok and role ~= nil
end

local function readAttribute(elem, name)
  local ok, value = pcall(function() return elem:attributeValue(name) end)
  if ok then return value end
  return nil
end

local function isSettable(elem, name)
  local ok, settable = pcall(function() return elem:isAttributeSettable(name) end)
  return ok and settable or false
end

--- UTF-16 code unit length of `s` -- what AXSelectedTextRange's `length`
--- means, not `s`'s UTF-8 byte length. Only matters for characters outside
--- the BMP (emoji, some CJK extensions), which are 2 UTF-16 units but more
--- than 2 UTF-8 bytes; getting this wrong just makes the post-write
--- reselect highlight a slightly wrong range, never the write itself, so a
--- byte-length fallback on invalid UTF-8 is an acceptable degradation.
function M.utf16Length(s)
  local ok, n = pcall(function()
    local count = 0
    for _, cp in utf8.codes(s) do
      count = count + (cp > 0xFFFF and 2 or 1)
    end
    return count
  end)
  return ok and n or #s
end

--- Plain-text probe: classify `elem` into a tier and read its contents as
--- plain text. Always async (callback-style) because the clipboard fallback
--- needs a short delay to let the target app react to synthesized keystrokes;
--- callers should not assume a same-tick response.
---
--- callback receives a single table:
---   { tier = "A"|"B"|"C", scope = "document"|"selection", value = string|nil,
---     selRange = {location=,length=}|nil, reason = string|nil }
---
--- scope is "selection" whenever the user had already highlighted text at
--- capture time -- write-back then replaces just that range instead of the
--- whole field (handover §9's "selection vs whole-field" open question).
--- selRange, when present, is the AX range (in AXSelectedTextRange's native
--- units) the selection occupied, kept only so write-back can re-highlight
--- the replaced text afterwards -- it is never used to splice document text.
---
--- This is the universal path. M.probe below wraps it to optionally upgrade
--- the result to a rich-text (formatted) capture for opted-in apps.
function M.probePlain(elem, callback)
  if isSecure(elem) then
    callback({ tier = "C", reason = "field is secure" })
    return
  end

  -- WebKit editable regions (e.g. Mail's HTML compose body) report
  -- AXRole == AXWebArea and lie on both ends of AXValue: it reads back an
  -- empty string instead of the actual rendered content (confirmed the
  -- hard way: a prefilled signature never showed up in the captured text),
  -- and isAttributeSettable(AXValue) reports true even though setting it
  -- is a silent no-op that never touches the rendered content. Skip the
  -- AXValue shortcut entirely for this role and always use the
  -- select-all+copy fallback below, which reads real text and correctly
  -- downgrades write-back to paste-on-quit instead of a setAttributeValue
  -- that wouldn't do anything. Selection detection for this role goes
  -- through the same clipboard-based path below rather than trusting its
  -- AXSelectedText, for the same reason.
  local roleOk, role = pcall(function() return elem:attributeValue("AXRole") end)
  local isWebArea = roleOk and role == "AXWebArea"

  if not isWebArea then
    local ok, value = pcall(function() return elem:attributeValue("AXValue") end)
    if ok and type(value) == "string" then
      local tier = isSettable(elem, "AXValue") and "A" or "B"

      -- A highlighted selection scopes the edit to just that range.
      -- AXSelectedText is a real replace-in-place attribute (the same
      -- mechanism VoiceOver/dictation use to replace a selection), so it
      -- gets its own independent settable check rather than assuming it
      -- follows AXValue's.
      local selText = readAttribute(elem, "AXSelectedText")
      if type(selText) == "string" and selText ~= "" then
        local selTier = isSettable(elem, "AXSelectedText") and "A" or "B"
        local range = readAttribute(elem, "AXSelectedTextRange")
        callback({ tier = selTier, scope = "selection", value = selText, selRange = range })
        return
      end

      callback({ tier = tier, scope = "document", value = value })
      return
    end
  end

  -- AXValue unreadable (or a WebKit editable region): fall back to the
  -- clipboard. Save/restore the clipboard around the probe itself;
  -- write-back's own clipboard save/restore (init.lua:onClose) is separate
  -- and later.
  local saved = hs.pasteboard.getContents()

  -- select-all+copy fallback (handover §4.1's "AX, or select-all+copy
  -- fallback" Tier B read path) -- whole-field capture, used when there's
  -- no selection to scope to.
  local function wholeFieldFallback()
    hs.pasteboard.setContents(SENTINEL)
    local before = hs.pasteboard.changeCount()
    hs.eventtap.keyStroke({ "cmd" }, "a")
    hs.eventtap.keyStroke({ "cmd" }, "c")
    hs.timer.doAfter(0.2, function()
      local changed = hs.pasteboard.changeCount() ~= before
      local text = changed and hs.pasteboard.getContents() or nil
      hs.pasteboard.setContents(saved or "")
      if text and text ~= SENTINEL then
        callback({ tier = "B", scope = "document", value = text })
      else
        callback({ tier = "C", reason = "field did not respond to AX or copy" })
      end
    end)
  end

  -- Try a bare copy first (no Cmd+A): if the user had already highlighted
  -- something, this captures just that selection, same scoping the AX path
  -- above gets for free via AXSelectedText. An unchanged/empty result just
  -- means there's no selection (or the field ignores keystrokes entirely,
  -- which wholeFieldFallback will also discover) -- either way, fall
  -- through rather than treating it as a final answer.
  hs.pasteboard.setContents(SENTINEL)
  local before = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "c")
  hs.timer.doAfter(0.2, function()
    local changed = hs.pasteboard.changeCount() ~= before
    local text = changed and hs.pasteboard.getContents() or nil
    if text and text ~= SENTINEL and text ~= "" then
      hs.pasteboard.setContents(saved or "")
      callback({ tier = "B", scope = "selection", value = text })
    else
      wholeFieldFallback()
    end
  end)
end

--- Second pass over a successful plain capture: copy the field's rich
--- content to the pasteboard, read it under the profile's UTI, and convert it
--- to Markdown. On success, rewrites `result` in place (value -> Markdown,
--- tier -> "B", rich -> profile name) and hands it back. On any failure --
--- the app didn't publish that UTI, or pandoc isn't available/choked -- the
--- untouched plain `result` is handed back unchanged, so a rich-enabled app
--- degrades cleanly to plain text.
---
--- Scope detection is deliberately left to probePlain (which ran first, off
--- the AX attributes, before any Cmd+A here could disturb the selection): a
--- "selection" capture uses a bare Cmd+C so the highlight survives for the
--- paste-on-quit write-back, while a "document" capture selects all first.
local function upgradeToRich(elem, result, opts, callback)
  local profile = opts.richProfile
  local saved = hs.pasteboard.getContents()

  hs.pasteboard.clearContents()
  local before = hs.pasteboard.changeCount()
  if result.scope == "selection" then
    hs.eventtap.keyStroke({ "cmd" }, "c")
  else
    hs.eventtap.keyStroke({ "cmd" }, "a")
    hs.eventtap.keyStroke({ "cmd" }, "c")
  end

  hs.timer.doAfter(0.2, function()
    local data
    if hs.pasteboard.changeCount() ~= before then
      data = hs.pasteboard.readDataForUTI(profile.uti)
    end
    hs.pasteboard.setContents(saved or "")

    if data and #data > 0 then
      local md = opts.richtext.toMarkdown(profile, data, opts)
      if md then
        result.value = md
        result.tier = "B" -- rich is always paste-on-quit; see richtext.lua
        result.rich = opts.richProfileName
      end
    end
    callback(result)
  end)
end

--- Probe `elem`, optionally upgrading the result to a rich-text capture.
---
--- Runs the plain probe first, then -- when opts.richProfile is set and the
--- field turned out readable (tier A/B) -- upgrades it via upgradeToRich.
--- opts (all optional): { richProfile, richProfileName, richtext, pandocPath,
--- tempDir }. With no opts, this is exactly probePlain.
function M.probe(elem, opts, callback)
  M.probePlain(elem, function(result)
    if result.tier == "C" or not (opts and opts.richProfile) then
      callback(result)
      return
    end
    upgradeToRich(elem, result, opts, callback)
  end)
end

--- Best-effort human-readable label for the field itself (as opposed to the
--- app/window), e.g. a placeholder or a linked label element ("Subject:",
--- "Search", "Comment"). Wildly app-dependent -- most fields expose at
--- least one of these, but none is universal, so this returns nil rather
--- than a generic role name when nothing usable is found; callers should
--- just leave it out of their message in that case.
function M.describeElement(elem)
  local function attr(target, name)
    local ok, v = pcall(function() return target:attributeValue(name) end)
    if ok and type(v) == "string" and v:match("%S") then return v end
    return nil
  end

  local label = attr(elem, "AXPlaceholderValue") or attr(elem, "AXTitle") or attr(elem, "AXDescription")
  if label then return label end

  local ok, titleElem = pcall(function() return elem:attributeValue("AXTitleUIElement") end)
  if ok and titleElem then
    return attr(titleElem, "AXValue") or attr(titleElem, "AXTitle")
  end

  return nil
end

--- Infer a file extension for the temp buffer so nvim gets useful
--- syntax/LSP. Checked in order: per-app override, AXDocument URL/path
--- pattern match, then config.defaultExtension.
function M.inferExtension(app, elem, config)
  local bundleID = app and app:bundleID()
  if bundleID and config.filetypeByBundleID[bundleID] then
    return config.filetypeByBundleID[bundleID]
  end

  local doc
  do
    local ok, result = pcall(function() return elem:attributeValue("AXDocument") end)
    if ok and type(result) == "string" then doc = result end
  end
  if not doc and app then
    local win = app:focusedWindow()
    local ok, result = pcall(function() return win and win:attributeValue("AXDocument") end)
    if ok and type(result) == "string" then doc = result end
  end

  if doc then
    for _, rule in ipairs(config.filetypeByURLPattern) do
      if doc:match(rule.pattern) then return rule.ext end
    end
  end

  return config.defaultExtension
end

return M
