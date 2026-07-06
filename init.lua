--- === instantvim ===
---
--- Edit any focused text field in any app using a real, fully-configured
--- Neovim running in Ghostty, then flow the result back into the original
--- field. See the repo README and handover doc for the full design
--- (three-tier AX capability model, host launch modes).

local obj = {}
obj.__index = obj

obj.name = "instantvim"
obj.version = "0.1.5"
obj.author = "tboehm"
obj.license = "MIT"
obj.homepage = "https://github.com/TimboGP/hammerspoon-instantvim"

obj.spoonPath = hs.spoons.scriptPath()

local capture = dofile(obj.spoonPath .. "capture.lua")
local menubar = dofile(obj.spoonPath .. "menubar.lua")

obj.logger = hs.logger.new("instantvim")

--- All user-facing configuration lives here. Override individual keys with
--- `spoon.instantvim.config.someKey = ...` (or replace whole sub-tables)
--- before calling `spoon.instantvim:start()`.
obj.config = {
  -- Hotkey that starts an edit session: { modifiers, key }.
  hotkey = { { "cmd", "alt", "ctrl", "shift" }, "e" }, -- hyper+e

  -- Where temp buffers are written. Each is deleted when its session ends.
  tempDir = "/tmp",
  defaultExtension = "md",

  -- Extension overrides, checked before defaultExtension. Bundle ID match
  -- wins outright; URL/path patterns are checked against AXDocument when
  -- the bundle ID isn't listed.
  filetypeByBundleID = {},
  filetypeByURLPattern = {
    { pattern = "github%.com", ext = "md" },
    { pattern = "gitlab%.com", ext = "md" },
  },

  -- Force a tier regardless of the AX probe, for apps that misreport
  -- isAttributeSettable. Values: "A", "B", or "C".
  tierOverrideByBundleID = {},

  -- How the nvim host is launched:
  --   "window"    - `open -na Ghostty --args -e nvim <path>`, a fresh
  --                 throwaway instance per invocation. The only supported
  --                 mode: a prior "qt" mode ran nvim inside a dedicated
  --                 background Ghostty instance's quick terminal, but
  --                 macOS treats Ghostty.app as a single-instance bundle
  --                 for Dock/Spotlight/`open` activation, so opening
  --                 Ghostty normally kept hijacking that hidden instance
  --                 instead of launching an independent one (confirmed
  --                 the hard way: it left orphaned nvim/dispatcher
  --                 processes piling up and ate the user's everyday
  --                 terminal). "window" instances do accumulate over
  --                 invocations, but each one is fully independent.
  --   "keystroke" - type `nvim <path>` into whatever shell is currently
  --                 focused. Racy (depends on a shell already being
  --                 focused and idle); last resort.
  hostMode = "window",

  -- "window"/"keystroke" mode.
  ghosttyAppPath = "/Applications/Ghostty.app",
  nvimPath = "nvim",
}

-- Active edit session, or nil. Only one at a time (handover §9: enforce a
-- lock; ignore a second hotkey press while a session is open).
obj.session = nil

-- Mirrors self.session at a glance for the menu bar title.
obj.status = "idle"

local function ensureAccessibility()
  if not hs.accessibilityState(false) then
    hs.alert.show("instantvim: Accessibility permission required")
    hs.accessibilityState(true) -- triggers the system prompt
    return false
  end
  return true
end

-- Whether a working `hs` binary is reachable the same way Neovim's jobstart
-- would find it: via PATH. hs.ipc.cliStatus() only checks for the CLI at
-- cliInstall()'s default location (/usr/local/bin/hs) -- on Apple Silicon
-- with Homebrew, `hs` commonly lives on PATH via /opt/homebrew/bin/hs
-- instead, which cliStatus() reports as "not installed" even though it
-- works fine. Checking PATH directly avoids that false negative.
local function hsOnPath()
  local out = hs.execute("command -v hs")
  return out ~= nil and out:match("%S") ~= nil
end

local function ensureHsCli()
  require("hs.ipc")
  if hsOnPath() then return true end
  hs.ipc.cliInstall()
  return hsOnPath()
end

function obj:setStatus(text)
  self.status = text
  menubar.setStatus(text)
end

function obj:notify(msg, persistent)
  self.logger.i(msg)
  if persistent then
    hs.notify.new({ title = "instantvim", informativeText = msg }):send()
  else
    hs.alert.show("instantvim: " .. msg)
  end
end

local function writeFile(path, contents)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(contents or "")
  f:close()
  return true
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local txt = f:read("*a")
  f:close()
  return txt
end

-- Fire-and-forget subprocesses (`open`, etc). hs.task objects with no live
-- Lua reference can be garbage-collected before their process finishes,
-- silently dropping the call (confirmed empirically: a bare
-- `hs.task.new(...):start()` with no retained reference reliably lost a
-- launch). Keeping a reference here until the completion callback fires
-- avoids that -- same fix editWithEmacs.spoon uses for emacsclient calls.
obj._pendingTasks = {}

function obj:runTask(launchPath, args)
  local task
  task = hs.task.new(launchPath, function()
    self._pendingTasks[task] = nil
  end, args)
  self._pendingTasks[task] = true
  task:start()
end

function obj:launchHost(path)
  local mode = self.config.hostMode
  if mode == "window" then
    self:runTask("/usr/bin/open",
      { "-na", self.config.ghosttyAppPath, "--args", "-e", self.config.nvimPath, path })
  elseif mode == "keystroke" then
    hs.timer.doAfter(0.3, function()
      hs.eventtap.keyStrokes(self.config.nvimPath .. " " .. path .. "\n")
    end)
  else
    self:notify("unknown hostMode '" .. tostring(mode) .. "'", true)
  end
end

--- Hotkey handler: capture the focused field, classify its tier, stash
--- everything needed for write-back, and hand a temp file to the host.
function obj:edit()
  if self.session then
    self:notify("edit already in progress")
    return
  end

  local elem = capture.getFocusedElement()
  if not elem then
    self:notify("no focused element")
    return
  end

  -- Stash the source app now: by write-back time focus is on the
  -- terminal, so frontmostApplication() would return Ghostty (constraint
  -- #5).
  local app = hs.application.frontmostApplication()

  capture.probe(elem, function(result)
    local tier = self.config.tierOverrideByBundleID[app and app:bundleID()] or result.tier

    if tier == "C" then
      self:notify("field is read-only or secure (" .. (result.reason or "unreadable") .. ")", true)
      return
    end

    local ext = capture.inferExtension(app, elem, self.config)
    local path = string.format("%s/instantvim-%s.%s", self.config.tempDir, hs.host.uuid(), ext)

    local ok, err = writeFile(path, result.value)
    if not ok then
      self:notify("could not write temp file: " .. tostring(err), true)
      return
    end

    self.session = {
      elem = elem,
      tier = tier,
      app = app,
      pid = app and app:pid(),
      path = path,
    }

    self:notify(string.format("Tier %s - %s", tier, tier == "A" and "live sync" or "sync on quit"))
    self:setStatus(string.format("editing (%s)", tier))
    self:launchHost(path)
  end)
end

--- Tier A live write-back. Called from nvim's BufWritePost via
--- `hs -c "spoon.instantvim:writeBack()"`. Safe to call repeatedly; no
--- focus change, so it never disturbs the user mid-edit.
function obj:writeBack()
  local s = self.session
  if not s or s.tier ~= "A" then return end

  if not capture.isElementAlive(s.elem) then
    self.logger.w("source element no longer valid; degrading to paste-on-quit")
    s.tier = "B"
    self:notify("source field changed - will paste on quit instead", true)
    return
  end

  local txt = readFile(s.path)
  if txt == nil then return end

  local ok = pcall(function() s.elem:setAttributeValue("AXValue", txt) end)
  if not ok then
    self.logger.w("setAttributeValue failed; degrading to paste-on-quit")
    s.tier = "B"
    self:notify("live write failed - will paste on quit instead", true)
  end
end

--- End of session. Called from nvim's own VimLeave once nvim exits.
--- Idempotent: the session is cleared on first entry, so a racing second
--- call is a no-op.
function obj:onClose()
  local s = self.session
  if not s then return end
  self.session = nil

  if s.tier == "B" then
    local txt = readFile(s.path) or ""
    local appAlive = s.app and s.app:isRunning() and capture.isElementAlive(s.elem)

    if appAlive then
      local saved = hs.pasteboard.getContents()
      s.app:activate()
      hs.timer.doAfter(0.15, function()
        hs.pasteboard.setContents(txt)
        hs.eventtap.keyStroke({ "cmd" }, "a")
        hs.eventtap.keyStroke({ "cmd" }, "v")
        hs.timer.doAfter(0.15, function()
          hs.pasteboard.setContents(saved or "")
        end)
      end)
    else
      hs.pasteboard.setContents(txt)
      self:notify("source field is gone - edited text left on the clipboard", true)
    end
  end

  os.remove(s.path)
  self:setStatus("idle")
end

function obj:bindHotkeys(mapping)
  local def = {
    edit = function() self:edit() end,
  }
  local descriptions = {
    edit = "Edit focused field with Neovim [instantvim]",
  }
  for name, spec in pairs(mapping) do
    if def[name] then
      self.hotkeyObj = hs.hotkey.bind(spec[1], spec[2], descriptions[name], def[name])
    end
  end
end

--- Build the menu bar dropdown. Passed to hs.menubar as a function so it's
--- rebuilt fresh (current status, current hostMode) each time it's opened.
function obj:menuItems()
  local items = {
    { title = "instantvim: " .. self.status, disabled = true },
    { title = "-" },
    { title = "Edit Focused Field", fn = function() self:edit() end },
    { title = "-" },
  }

  local hostModes = { "window", "keystroke" }
  local hostModeLabels = {
    window = "Throwaway Window",
    keystroke = "Keystroke (fallback)",
  }
  local hostModeItems = {}
  for _, mode in ipairs(hostModes) do
    table.insert(hostModeItems, {
      title = hostModeLabels[mode],
      checked = self.config.hostMode == mode,
      fn = function() self.config.hostMode = mode end,
    })
  end
  table.insert(items, { title = "Host Mode", menu = hostModeItems })
  table.insert(items, { title = "-" })
  table.insert(items, { title = "Reload Config", fn = function() hs.reload() end })

  return items
end

function obj:init()
end

function obj:start()
  if not ensureAccessibility() then
    return self
  end
  if not ensureHsCli() then
    self:notify("'hs' CLI not found on PATH - live write-back from nvim will not work. See README.", true)
  end
  self:bindHotkeys({ edit = self.config.hotkey })
  menubar.start()
  menubar.setMenu(function() return self:menuItems() end)
  self.logger.i("instantvim started")
  return self
end

function obj:stop()
  if self.hotkeyObj then
    self.hotkeyObj:delete()
    self.hotkeyObj = nil
  end
  menubar.stop()
  return self
end

return obj
