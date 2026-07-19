--- === instantvim ===
---
--- Edit any focused text field in any app using a real, fully-configured
--- Neovim running in Ghostty, then flow the result back into the original
--- field. See the repo README and handover doc for the full design
--- (three-tier AX capability model, host launch modes).

local obj = {}
obj.__index = obj

obj.name = "instantvim"
obj.version = "0.4.0"
obj.author = "tboehm"
obj.license = "MIT"
obj.homepage = "https://github.com/TimboGP/hammerspoon-instantvim"

obj.spoonPath = hs.spoons.scriptPath()

local capture = dofile(obj.spoonPath .. "capture.lua")
local menubar = dofile(obj.spoonPath .. "menubar.lua")
local richtext = dofile(obj.spoonPath .. "richtext.lua")
local KeybindRegistry = require("keybind_registry")
-- Slack needs a bespoke adapter (proprietary clipboard); it registers its own
-- profile rather than using a generic UTI+pandoc one. See slack.lua.
local slack = dofile(obj.spoonPath .. "slack.lua")
richtext.profiles.slack = slack.profile

obj.logger = hs.logger.new("instantvim")

--- All user-facing configuration lives here. Override individual keys with
--- `spoon.instantvim.config.someKey = ...` (or replace whole sub-tables)
--- before calling `spoon.instantvim:start()`.
obj.config = {
  -- Hotkey that starts an edit session: { modifiers, key }.
  hotkey = { { "cmd", "alt", "ctrl", "shift" }, "e" }, -- hyper+e

  -- Hotkey that aborts a stuck/unwanted edit session (e.g. the host
  -- failed to launch and the "edit already in progress" lock never
  -- clears). nil by default -- unbound unless you opt in, since there's
  -- no safe universal default that won't collide with something else.
  -- Also reachable from the menu bar regardless of this setting.
  cancelHotkey = nil,

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

  -- PROTOTYPE (wishlist.md "Formatted (rich text) content"). Master gate for
  -- the rich-text round-trip, OFF by default. When true, apps listed in
  -- contentTypeByBundleID round-trip their formatting through nvim as
  -- Markdown (via pandoc) instead of being flattened to plain text; when
  -- false, every app stays plain text regardless of that table. The feature
  -- needs pandoc on your PATH -- enabling it (here or via the menu bar) runs
  -- a check and notifies if pandoc is missing. Flip to true to try it.
  enableRichText = false,

  -- Apps that round-trip formatting when enableRichText is true. Maps a
  -- bundle ID to a richtext profile name (see richtext.lua): "rtf" for
  -- native Cocoa fields, "html" for web/Electron contentEditable surfaces
  -- (browsers, rich mail compose). Any app NOT listed keeps the plain-text
  -- behavior, the universal fallback. A rich round-trip is always
  -- paste-on-quit (Tier B) even for otherwise-Tier-A fields, because the AX
  -- write attributes are plain strings -- see wishlist.md. TextEdit is the
  -- tested target; the html entries cover the common class and can be
  -- extended with any bundle ID whose fields are HTML contentEditable.
  contentTypeByBundleID = {
    ["com.apple.TextEdit"] = "rtf",
    ["com.microsoft.Word"] = "rtf", -- Word's HTML clipboard is cruft-heavy; prefer RTF
    -- Pages (com.apple.Pages) deliberately NOT mapped: capture works, but its
    -- named paragraph styles (Body/Title/Heading) have no Markdown equivalent,
    -- so RTF write-back collapses a mixed-style selection onto the paste
    -- point's style. See wishlist.md.
    ["com.apple.Safari"] = "html",
    ["com.google.Chrome"] = "html",
    ["com.microsoft.Edge"] = "html",
    ["com.brave.Browser"] = "html",
    ["company.thebrowser.Browser"] = "html", -- Arc
    ["org.mozilla.firefox"] = "html",
    ["com.apple.mail"] = "html",
    ["com.tinyspeck.slackmacgap"] = "slack", -- bespoke adapter, see slack.lua
  },

  -- pandoc, used for the rich round-trip above. Resolved via your login
  -- shell (like nvimPath), so a bare "pandoc" works even though
  -- Hammerspoon.app itself runs with the bare system PATH.
  pandocPath = "pandoc",

  -- How the nvim host is launched:
  --   "window"    - runs Ghostty's own executable directly (see
  --                 ghosttyAppPath below), a fresh throwaway instance per
  --                 invocation. The only supported mode: a prior "qt" mode
  --                 ran nvim inside a dedicated background Ghostty
  --                 instance's quick terminal, but macOS treats
  --                 Ghostty.app as a single-instance bundle for
  --                 Dock/Spotlight/`open` activation, so opening Ghostty
  --                 normally kept hijacking that hidden instance instead
  --                 of launching an independent one (confirmed the hard
  --                 way: it left orphaned nvim/dispatcher processes piling
  --                 up and ate the user's everyday terminal). Launching
  --                 the bundle's executable directly, instead of via
  --                 `open`, sidesteps LaunchServices' single-instance
  --                 activation entirely -- as a bonus this also avoids a
  --                 macOS prompt ("Allow Ghostty to execute '<path>'?")
  --                 that otherwise fires on every single invocation, since
  --                 each temp file has a fresh random name LaunchServices
  --                 has never consented to before (confirmed the hard way:
  --                 going through `open -na Ghostty --args -e ...`
  --                 sometimes routed the request to an already-running
  --                 Ghostty instance via Apple Events instead of a truly
  --                 new process, surfacing as a duplicate tab on top of
  --                 the consent prompt). "window" instances do accumulate
  --                 over invocations, but each one is fully independent.
  --   "keystroke" - type `nvim <path>` into whatever shell is currently
  --                 focused. Racy (depends on a shell already being
  --                 focused and idle); last resort.
  hostMode = "window",

  -- "window"/"keystroke" mode. In "window" mode, the actual executable run
  -- is `ghosttyAppPath .. "/Contents/MacOS/ghostty"` (see launchHost).
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
--
-- Must pass hs.execute's second argument (run via the user's login shell)
-- -- Hammerspoon.app itself is launched by macOS with the bare default
-- PATH (/usr/bin:/bin:/usr/sbin:/sbin, no Homebrew dirs), since it's a GUI
-- app rather than something spawned from a shell that sourced .zprofile.
-- Without it this reintroduces the exact false negative this function
-- exists to avoid: `hs` resolves fine for Neovim (Ghostty launches nvim
-- through a real login shell) even though Hammerspoon's own environment
-- can't see it.
local function hsOnPath()
  local out = hs.execute("command -v hs", true)
  return out ~= nil and out:match("%S") ~= nil
end

local function ensureHsCli()
  require("hs.ipc")
  if hsOnPath() then return true end
  hs.ipc.cliInstall()
  return hsOnPath()
end

-- Resolves config.nvimPath to an absolute path via the user's login shell
-- PATH. Ghostty's `-e` launches the host command through
-- `/usr/bin/login -flp <user> <cmd>...`, which execs the command directly
-- rather than through a shell -- so it never sees PATH entries a shell
-- profile would add (e.g. Homebrew's /opt/homebrew/bin). A bare "nvim"
-- resolves fine when typed into an already-running shell (keystroke mode)
-- but fails under `login` with "nvim: No such file or directory". Same
-- root cause as hsOnPath() above; resolving to an absolute path here sides
-- steps login's PATH entirely.
local function resolveNvimPath(nvimPath)
  if nvimPath:sub(1, 1) == "/" then return nvimPath end
  local out = hs.execute("command -v " .. nvimPath, true)
  if out and out:match("%S") then
    return (out:gsub("%s+$", ""))
  end
  return nvimPath
end

--- tag is the compact form shown in the menu bar itself (e.g. "A", "AR"
--- for tier A rich); text is the full sentence shown in the dropdown menu.
--- tag is nil for the idle state, which shows the icon with no text.
function obj:setStatus(text, tag)
  self.status = text
  menubar.setStatus(tag)
end

function obj:notify(msg, persistent)
  self.logger.i(msg)
  if persistent then
    hs.notify.new({ title = "instantvim", informativeText = msg }):send()
  else
    hs.alert.show("instantvim: " .. msg)
  end
end

-- Human-readable "<app> - <window title> - <field label>" for notify()
-- messages. Each part is independently optional -- window title and field
-- label are both frequently unavailable (e.g. a field with no enclosing
-- window title, like a Spotlight-style panel; or a field with no
-- placeholder/label at all) -- so this joins whatever's actually present
-- rather than requiring all three.
local function describeTarget(app, win, elem)
  local parts = { app and app:title() or "unknown app" }
  local winTitle = win and win:title()
  if winTitle and winTitle ~= "" then table.insert(parts, winTitle) end
  local fieldLabel = elem and capture.describeElement(elem)
  if fieldLabel then table.insert(parts, fieldLabel) end
  return table.concat(parts, " - ")
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

-- Best-effort re-highlight of the just-replaced selection, so a
-- selection-scoped edit leaves the new text selected the same way typing
-- over a highlighted range normally would. `range.location` is carried
-- through unchanged from the original probe (the field isn't focused
-- during the edit, so nothing else can shift it); only the length changes,
-- to match the newly written text. Silently a no-op if the element
-- doesn't support setting its selection range -- this is cosmetic, never
-- required for the write itself to have succeeded.
local function reselect(elem, range, newText)
  pcall(function()
    elem:setAttributeValue("AXSelectedTextRange", {
      location = range.location,
      length = capture.utf16Length(newText),
    })
  end)
end

-- Fire-and-forget subprocesses (`open`, etc). hs.task objects with no live
-- Lua reference can be garbage-collected before their process finishes,
-- silently dropping the call (confirmed empirically: a bare
-- `hs.task.new(...):start()` with no retained reference reliably lost a
-- launch). Keeping a reference here until the completion callback fires
-- avoids that -- same fix editWithEmacs.spoon uses for emacsclient calls.
obj._pendingTasks = {}

function obj:runTask(launchPath, args, env)
  local task
  task = hs.task.new(launchPath, function()
    self._pendingTasks[task] = nil
  end, args)
  if env then task:setEnvironment(env) end
  self._pendingTasks[task] = true
  task:start()
end

-- Single-quotes a string for safe embedding in a shell command.
local function shQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function obj:launchHost(path)
  local mode = self.config.hostMode
  if mode == "window" then
    -- The temp file path is passed via $INSTANTVIM_PATH, not as a literal
    -- argument, and resolved inside a login shell rather than handed
    -- straight to `-e`. Ghostty's own AppKit integration inspects `-e`'s
    -- resolved command for arguments that are existing files and, if found,
    -- unconditionally shows an "Allow Ghostty to execute '<path>'?" prompt
    -- before running it (a deliberate sandbox-escape mitigation on
    -- Ghostty's side, not a bug) -- and, worse, ends up creating a second,
    -- separate surface for it alongside the one from our own `-e` command
    -- (confirmed the hard way: the extra tab literally tries to run the
    -- temp file's contents as a shell script, then exits). Since the path
    -- only ever appears inside a shell variable reference, never as a
    -- literal argument, neither of those trigger. The login shell (`-l`)
    -- also picks up PATH from your shell profile, same reasoning as
    -- resolveNvimPath below, so nvimPath doesn't strictly need to be an
    -- absolute path here anymore -- resolving it anyway keeps this working
    -- even if config.nvimPath is overridden with something unusual.
    local shell = os.getenv("SHELL") or "/bin/zsh"
    local cmd = "exec " .. shQuote(resolveNvimPath(self.config.nvimPath)) .. ' "$INSTANTVIM_PATH"'
    self:runTask(self.config.ghosttyAppPath .. "/Contents/MacOS/ghostty",
      { "-e", shell, "-lc", cmd }, { INSTANTVIM_PATH = path })
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
  -- #5). Same for the window title -- grabbed now for the notify()
  -- messages below, since by close time focus has long since moved on.
  local app = hs.application.frontmostApplication()
  local win = app and app:focusedWindow()
  local label = describeTarget(app, win, elem)

  -- Rich-text round-trip (see richtext.lua / wishlist.md) for opted-in apps,
  -- only when the feature is enabled; everything else falls through to the
  -- plain-text path unchanged.
  local bundleID = app and app:bundleID()
  local profileName = self.config.enableRichText and bundleID
    and self.config.contentTypeByBundleID[bundleID] or nil
  local probeOpts = {
    richProfile = profileName and richtext.profiles[profileName] or nil,
    richProfileName = profileName,
    richtext = richtext,
    pandocPath = self.config.pandocPath,
    tempDir = self.config.tempDir,
  }

  capture.probe(elem, probeOpts, function(result)
    -- Rich is always Tier B (paste-on-quit); its markdown must never reach a
    -- Tier A live setAttributeValue, so it wins over tierOverrideByBundleID.
    local tier = result.rich and "B"
      or (self.config.tierOverrideByBundleID[bundleID] or result.tier)

    if tier == "C" then
      self:notify("field is read-only or secure (" .. (result.reason or "unreadable") .. ")", true)
      return
    end

    -- Rich content is edited as Markdown regardless of the app's own file type.
    local ext = result.rich and "md" or capture.inferExtension(app, elem, self.config)
    local path = string.format("%s/instantvim-%s.%s", self.config.tempDir, hs.host.uuid(), ext)

    local ok, err = writeFile(path, result.value)
    if not ok then
      self:notify("could not write temp file: " .. tostring(err), true)
      return
    end

    self.session = {
      elem = elem,
      tier = tier,
      scope = result.scope,
      selRange = result.selRange,
      rich = result.rich,
      app = app,
      pid = app and app:pid(),
      path = path,
      label = label,
    }

    local scopeLabel = result.scope == "selection" and ", selection" or ""
    local richLabel = result.rich and ", rich" or ""
    self:notify(string.format("Tier %s (%s%s%s) - editing %s", tier, tier == "A" and "live sync" or "sync on quit", scopeLabel, richLabel, label))
    self:setStatus(string.format("editing (%s%s)", tier, result.rich and " rich" or ""), tier .. (result.rich and "R" or ""))
    -- Give the alert above a moment on screen before the host window
    -- appears and steals attention -- hs.alert floats above other windows,
    -- but launching immediately made it too easy to miss in practice.
    hs.timer.doAfter(0.2, function() self:launchHost(path) end)
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

  -- Selection scope replaces just the originally-highlighted range via
  -- AXSelectedText, the same attribute VoiceOver/dictation use to type
  -- over a selection, instead of AXValue's whole-field replace.
  local attr = (s.scope == "selection") and "AXSelectedText" or "AXValue"
  local ok = pcall(function() s.elem:setAttributeValue(attr, txt) end)
  if not ok then
    self.logger.w("setAttributeValue failed; degrading to paste-on-quit")
    s.tier = "B"
    self:notify("live write failed - will paste on quit instead", true)
    return
  end

  if s.scope == "selection" and s.selRange then
    reselect(s.elem, s.selRange, txt)
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
        -- Rich sessions put the formatting on the pasteboard under its UTI
        -- (writing e.g. RTF also auto-populates a plain-text representation,
        -- so non-rich paste targets still get text); plain sessions just set
        -- the string. Either way the paste below is a normal Cmd+V.
        local pandocOpts = { pandocPath = self.config.pandocPath, tempDir = self.config.tempDir }
        local reselectText = txt
        local profile = s.rich and richtext.profiles[s.rich]
        local built = profile and richtext.buildPasteboard(profile, txt, pandocOpts)
        if built then
          hs.pasteboard.writeAllData(built.data)
          -- Markdown length counts markup the field won't render; size the
          -- selection re-highlight off the plain-text rendering instead.
          reselectText = built.plain
        else
          if s.rich then
            self:notify("rich conversion failed - pasted as plain text", true)
          end
          hs.pasteboard.setContents(txt)
        end
        -- Selection scope relies on the source field's own selection
        -- still being highlighted (untouched since capture, since the
        -- field was never refocused during the edit) -- select-all here
        -- would blow that away and paste over the whole field instead.
        if s.scope ~= "selection" then
          hs.eventtap.keyStroke({ "cmd" }, "a")
        end
        hs.eventtap.keyStroke({ "cmd" }, "v")
        if s.scope == "selection" and s.selRange and capture.isElementAlive(s.elem) then
          reselect(s.elem, s.selRange, reselectText)
        end
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
  self:notify("edit session closed - " .. (s.label or "unknown target"))
end

--- Aborts a stuck or unwanted session without writing anything back to the
--- source field. Unlike onClose(), this never touches the clipboard or the
--- original app -- it just drops the lock and cleans up the temp file, so
--- it's safe to call when the host (e.g. Ghostty/nvim) never actually
--- launched and VimLeave will consequently never fire. If the nvim window
--- did launch, it's left open; closing/quitting it afterwards just hits
--- onClose()'s "no session" no-op.
function obj:cancel()
  local s = self.session
  if not s then
    self:notify("no edit in progress")
    return
  end
  self.session = nil
  os.remove(s.path)
  self:setStatus("idle")
  self:notify("edit session cancelled")
end

local ACTION_DESCRIPTIONS = {
  edit = "Edit focused field with Neovim [instantvim]",
  cancel = "Cancel in-progress edit session [instantvim]",
}

local MOD_SYMBOLS = { cmd = "⌘", ctrl = "⌃", alt = "⌥", shift = "⇧" }

local function keyLabel(spec)
  local mods, key = spec[1], spec[2]
  local out = {}
  for _, m in ipairs(mods) do
    table.insert(out, MOD_SYMBOLS[m] or m)
  end
  table.insert(out, key:upper())
  return table.concat(out)
end

function obj:bindHotkeys(mapping)
  local def = {
    edit = function() self:edit() end,
    cancel = function() self:cancel() end,
  }
  self.hotkeyMapping = mapping
  for name, spec in pairs(mapping) do
    if def[name] and spec then
      KeybindRegistry.bind({
        scope = "global",
        mods = spec[1],
        key = spec[2],
        desc = ACTION_DESCRIPTIONS[name] or name,
        fn = def[name],
        spoonName = self.name,
      })
    end
  end
end

--- Structured {key, description} rows for instantvim's hotkeys, for external
--- cheat-sheet tools (e.g. CheatSheet.spoon) to query.
function obj:bindings()
  local rows = {}
  for name, spec in pairs(self.hotkeyMapping or {}) do
    if spec then
      table.insert(rows, { key = keyLabel(spec), description = ACTION_DESCRIPTIONS[name] or name })
    end
  end
  return rows
end

-- hs.settings key under which the rich-text toggle is persisted, so a choice
-- made from the menu bar survives reloads and app restarts (hs.settings is
-- backed by NSUserDefaults).
local RICHTEXT_SETTING = "instantvim.enableRichText"

--- Apply the persisted rich-text toggle, if the user has ever set it from the
--- menu bar. This takes precedence over config.enableRichText so a menu choice
--- sticks across reloads; a setup that has never toggled keeps whatever the
--- config says. Reset by toggling again, or by clearing the
--- "instantvim.enableRichText" key via hs.settings.
function obj:loadPersistedState()
  local persisted = hs.settings.get(RICHTEXT_SETTING)
  if type(persisted) == "boolean" then
    self.config.enableRichText = persisted
  end
end

--- Verifies the rich-text feature's dependency (pandoc) when it's enabled,
--- notifying if it's missing (rich-enabled apps then fall back to plain
--- text). A no-op when the feature is off. Returns whether the dependency is
--- satisfied. Shared by start() and toggleRichText() so every "enable" path
--- runs the same check.
function obj:checkRichTextDeps()
  if not self.config.enableRichText then return true end
  if richtext.available({ pandocPath = self.config.pandocPath }) then return true end
  self:notify("pandoc not found on PATH - rich-text apps fall back to plain text. See README.", true)
  return false
end

--- Flip the rich-text gate at runtime (from the menu bar). Enabling runs the
--- pandoc check, same as start(), so a missing dependency is surfaced the
--- moment the feature is turned on rather than silently at edit time.
function obj:toggleRichText()
  self.config.enableRichText = not self.config.enableRichText
  hs.settings.set(RICHTEXT_SETTING, self.config.enableRichText) -- persist across reloads
  if not self.config.enableRichText then
    self:notify("rich text disabled")
  elseif self:checkRichTextDeps() then
    self:notify("rich text enabled")
  end
end

--- Build the menu bar dropdown. Passed to hs.menubar as a function so it's
--- rebuilt fresh (current status, current hostMode) each time it's opened.
function obj:menuItems()
  local items = {
    { title = "instantvim: " .. self.status, disabled = true },
    { title = "-" },
    { title = "Edit Focused Field", fn = function() self:edit() end },
    {
      title = "Cancel Edit Session",
      disabled = self.session == nil,
      fn = function() self:cancel() end,
    },
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
  table.insert(items, {
    title = "Rich Text (RTF)",
    checked = self.config.enableRichText,
    fn = function() self:toggleRichText() end,
  })
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
  -- Restore a persisted rich-text toggle (menu choice survives reloads),
  -- then check its dependency; enabling it in config or via a prior toggle
  -- surfaces a missing pandoc at start.
  self:loadPersistedState()
  self:checkRichTextDeps()
  self:bindHotkeys({ edit = self.config.hotkey, cancel = self.config.cancelHotkey })
  menubar.start(self.spoonPath .. "menubar-icon.png")
  menubar.setMenu(function() return self:menuItems() end)
  self.logger.i("instantvim started")
  return self
end

function obj:stop()
  KeybindRegistry.unbindBySpoon(self.name)
  menubar.stop()
  return self
end

return obj
