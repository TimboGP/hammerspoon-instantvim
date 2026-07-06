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

--- Probe `elem` and classify it into a tier. Always async (callback-style)
--- because the clipboard fallback needs a short delay to let the target app
--- react to synthesized keystrokes; callers should not assume a same-tick
--- response.
---
--- callback receives a single table:
---   { tier = "A"|"B"|"C", value = string|nil, reason = string|nil }
function M.probe(elem, callback)
  if isSecure(elem) then
    callback({ tier = "C", reason = "field is secure" })
    return
  end

  local ok, value = pcall(function() return elem:attributeValue("AXValue") end)
  if ok and type(value) == "string" then
    local settableOk, settable = pcall(function() return elem:isAttributeSettable("AXValue") end)
    local tier = (settableOk and settable) and "A" or "B"
    callback({ tier = tier, value = value })
    return
  end

  -- AXValue unreadable but confirmed non-secure: try the select-all+copy
  -- fallback (handover §4.1's "AX, or select-all+copy fallback" Tier B read
  -- path). Save/restore the clipboard around the probe itself; write-back's
  -- own clipboard save/restore (init.lua:onClose) is separate and later.
  local saved = hs.pasteboard.getContents()
  hs.pasteboard.setContents(SENTINEL)
  local before = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "a")
  hs.eventtap.keyStroke({ "cmd" }, "c")
  hs.timer.doAfter(0.2, function()
    local changed = hs.pasteboard.changeCount() ~= before
    local text = changed and hs.pasteboard.getContents() or nil
    hs.pasteboard.setContents(saved or "")
    if text and text ~= SENTINEL then
      callback({ tier = "B", value = text })
    else
      callback({ tier = "C", reason = "field did not respond to AX or copy" })
    end
  end)
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
