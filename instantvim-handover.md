# instantvim — Build Handover

> **Reader:** Claude Code (agentic build). This is a spec, not a tutorial. Build in the phases below; each phase has acceptance criteria you must verify before moving on. Read **§2 Hard Constraints** before writing any code — they encode failures you will otherwise discover the expensive way.

## 1. Goal

A macOS tool that lets me edit **any focused text field in any app** using my **real Neovim** (full personal config, not a vim emulation layer), then flows the result back into the original field.

User story:
1. Cursor is in some text field (browser textarea, native app, Slack, etc.).
2. I press a global hotkey.
3. The Ghostty **quick terminal** drops down running my configured `nvim` on a temp buffer pre-filled with the field's current contents.
4. I edit. On `:w`, changes flow back into the original field **live** where the OS allows it; otherwise they flow back **on quit**.
5. Quick terminal hides; focus returns to the original app.

This is `editWithEmacs.spoon`'s round-trip, retargeted to Neovim + Ghostty, with a capability-tiered write-back.

## 2. Hard Constraints (read first)

These are non-negotiable facts about the platform. Do not design around wishful versions of them.

1. **Write-back capability is per-field, detected at runtime — not global.** The mechanism that works depends entirely on whether the OS lets you *set* the focused element's value. There is no single write path that works everywhere. See §4.1 (the three-tier model). This is the core of the design.

2. **Live sync is only possible in Tier A.** Setting `AXValue` directly needs no focus change, so nvim can keep focus while the field updates. Every other write path (paste) requires *refocusing the target app*, which yanks the user out of nvim — so it can only fire on quit. "Live where possible, else on quit" **is** "Tier A vs Tier B." Don't try to make paste-based write-back live.

3. **Secure fields are invisible.** Password fields, 1Password, anything marked secure returns nothing via the Accessibility API. Detect and abort with a user notification. Never attempt keystroke scraping of these.

4. **Electron / browser `contentEditable` do not expose settable values or reliable selection ranges.** They are Tier B at best (read via AX or clipboard, write via paste-on-quit). Do not attempt cursor-range-precise edits there.

5. **Stash the source element reference AND source app PID at capture time.** By write-back, focus is on the terminal — `frontmostApplication()` will return Ghostty, not the source. If you don't capture the target up front, you have nothing to write back to.

6. **On macOS, you cannot inject a command into the running Ghostty quick terminal from the CLI.** `ghostty +new-window --command …` uses native IPC that (as of the 1.3 series, 2025→2026) is **not wired up on macOS**; the macOS path is `open -na Ghostty.app`, which spawns whole new *instances*, not a command into an existing surface. **Verify this against the installed Ghostty version** — if macOS `+new-window` now works, it simplifies §4.3 considerably. If it doesn't, use the FIFO-dispatcher pattern in §4.3.

7. **Hammerspoon's `hs` CLI must be installed** (`hs.ipc.cliInstall()`), because Neovim calls back into the Spoon through it. Verify at load.

## 3. Prior Art — study, don't reinvent

- **`editWithEmacs.spoon`** — https://github.com/dmgerman/editWithEmacs.spoon — the exact round-trip pattern (hotkey → grab focused field → open editor buffer → callback writes result back via the `hs` CLI). **Adapt the pattern — do not literally fork.** This is a fresh Neovim project, not a downstream of an Emacs Spoon: the Elisp half is gone, and the capture/write-back is replaced by the AX capability-tier engine (§4.1), which is the whole point. Read it closely and lift the debugged Hammerspoon↔editor callback wiring, but start a clean repo and attribute per §11. Forks worth diffing for that wiring: `jeremyf/editWithEmacs.spoon`, `stuart-warren/editWithEmacs.spoon`.
- **`VimMode.spoon`** — https://github.com/dbalatero/VimMode.spoon — reference for reading focused-field values and the Advanced (AX) vs Fallback (clipboard) split. Its author's writeup on field reading is the definitive doc on what breaks and where: https://balatero.com/writings/hammerspoon/retrieving-input-field-values-and-cursor-position-with-hammerspoon/
- **Ghostty quick terminal** — toggled by `keybind = global:ctrl+grave_accent=toggle_quick_terminal` (global requires Accessibility permission; Ghostty must be running). Dedicated-background-quick-terminal pattern: ghostty-org/ghostty discussion #7978.

## 4. Architecture

### 4.1 The three-tier capability model (the heart of it)

At capture time, get the system-wide focused element and probe **one** thing: is `AXValue` settable?

```lua
local sw      = hs.axuielement.systemWideElement()
local elem    = sw:attributeValue("AXFocusedUIElement")
local value   = elem and elem:attributeValue("AXValue")          -- current text (may be nil)
local settable= elem and elem:isAttributeSettable("AXValue")     -- the tier discriminator
```

That sorts every field:

| Tier | Condition | Read | Write-back | Live? |
|------|-----------|------|-----------|-------|
| **A** | `AXValue` readable **and** settable (most native Cocoa fields) | AX | `setAttributeValue("AXValue", …)` — no focus change | **Yes**, on every `:w` |
| **B** | readable **not** settable (Electron, browser contentEditable) | AX, or select-all+copy fallback | refocus source + paste | No — quit only |
| **C** | not readable (secure/password) | — | — | Abort + notify |

The user's chosen behavior ("live where possible, else quit" + "whatever works, degrade gracefully") **is exactly this table**. Implement the table; the behavior falls out.

### 4.2 Data flow

```
[hotkey]
  → capture: focused elem, AXValue, tier, source app + PID   (stash all)
  → write value to /tmp/instantvim-<uuid>.<ext>
  → hand path to the nvim host (§4.3), show it
  → user edits
      Tier A: BufWritePost → `hs -c "spoon.instantvim:writeBack()"` → setAttributeValue   (live)
      Tier B: no-op on :w
  → user quits nvim
      → dispatcher calls `hs -c "spoon.instantvim:onClose()"`
      → Tier B: activate source app, restore clipboard-safe paste
      → hide host, return focus, clean up temp file
```

### 4.3 The nvim host (most fragile part)

Target: run nvim inside the Ghostty **quick terminal**. Because of Constraint #6, you can't push a command into the QT from the CLI on macOS. Use a **FIFO dispatcher**:

Run a **dedicated background Ghostty instance** (LaunchAgent + its own `--config-file`) that owns the quick terminal and whose `command` is a dispatcher loop:

```sh
#!/usr/bin/env bash
# instantvim-dispatch.sh — the quick terminal's `command`
FIFO=/tmp/instantvim.fifo
[ -p "$FIFO" ] || mkfifo "$FIFO"
while :; do
  if read -r path < "$FIFO"; then
    [ -n "$path" ] && nvim "$path"
    hs -c "spoon.instantvim:onClose()"
  fi
done
```

Hotkey side (Hammerspoon): write the temp path to the FIFO, then toggle the QT visible. On nvim exit the loop blocks again and `onClose` hides the QT. Keeping this on a *dedicated* instance keeps the dispatcher `command` off normal Ghostty windows.

**Fallbacks, in order of preference if QT hosting proves fiddly:**
1. Keystroke injection: toggle QT visible, then `hs.eventtap.keyStrokes("nvim "..path.."\n")`. Simpler, but racy (foreground-process/shell state). Acceptable for a v0 spike.
2. Throwaway window: `open -na Ghostty.app --args -e nvim <path>`. Dead simple, always works, but spawns a new instance per invocation (instance sprawl) and isn't the quick terminal. Good for proving Phases 1–2 before tackling the QT.

Build order deliberately uses fallback #2 first (see Phase 1), then swaps in the QT host in Phase 3.

## 5. Repo layout

```
instantvim/
├── README.md
├── Spoons/
│   └── instantvim.spoon/
│       ├── init.lua              # hotkey, capture, tier probe, writeBack, onClose
│       └── capture.lua           # AX read/probe + clipboard fallback helpers
├── host/
│   ├── instantvim-dispatch.sh    # FIFO dispatcher (QT command)
│   └── quick-terminal.config     # dedicated Ghostty instance config
├── nvim/
│   └── instantvim.lua            # autocmds: BufWritePost → writeBack, VimLeave hook
├── launchd/
│   └── com.instantvim.qt.plist   # background Ghostty QT host
└── install.sh                    # symlinks, hs.ipc.cliInstall check, mkfifo, load agent
```

## 6. Build plan (phased — verify acceptance before advancing)

### Phase 0 — Scaffolding
- Spoon skeleton, hotkey binding (default `hyper+e`, configurable), temp dir under `/tmp`.
- Assert `hs.ipc` present; if `hs` CLI missing, notify and stop.
- **Accept:** pressing the hotkey writes a timestamped temp file containing the focused field's current text, and logs the detected tier. No editor yet.

### Phase 1 — Tier A round trip (simplest host)
- Use host fallback #2 (`open -na … -e nvim`) — defer the quick terminal.
- Capture → temp file → nvim → `BufWritePost` → `writeBack()` → `setAttributeValue("AXValue", …)`.
- **Accept:** in TextEdit / a native `NSTextView`, editing in nvim and pressing `:w` updates the source field within ~200ms, focus unchanged. Round trip is lossless for multiline UTF-8.

### Phase 2 — Tiering + Tier B + Tier C
- Add the `isAttributeSettable` probe and branch.
- Tier B: on `VimLeave`, activate source app (by stashed PID), clipboard-safe paste (save clipboard → set → `cmd+a`, `cmd+v` → restore).
- Tier C: notify "field is read-only/secure" and abort at capture.
- **Accept:** works in a browser `<textarea>` (Tier A or B depending on browser) and a Slack/VS Code message box (Tier B, writes on quit only). A password field is refused with a clear notification and never opens an editor.

### Phase 3 — Ghostty quick-terminal host
- Dedicated background Ghostty instance (launchd) + `instantvim-dispatch.sh` as its `command`.
- Hotkey writes path → FIFO, toggles QT visible; `onClose` hides it.
- **Accept:** the whole flow runs inside the quick terminal with the dropdown animation; no stray Ghostty instances accumulate across 20 invocations.

### Phase 4 — Polish
- Clipboard save/restore correctness; filetype/extension inference (e.g. GitHub comment → `.md`) so nvim gets syntax/LSP; stale-element guard (revalidate the stashed element before write, fall back to paste if invalid); notifications for each tier; user config table (hotkey, QT keybind, temp dir, per-app tier overrides à la VimMode's `useFallbackMode`).
- **Accept:** clipboard contents are identical before/after a Tier B edit; a captured element that was destroyed mid-edit degrades to paste instead of erroring.

## 7. Reference snippets (adapt, don't copy blindly)

**Capture (init.lua):**
```lua
function obj:capture()
  local sw   = hs.axuielement.systemWideElement()
  local elem = sw:attributeValue("AXFocusedUIElement")
  if not elem then return self:notify("No focused element") end
  local value = elem:attributeValue("AXValue")
  if value == nil then return self:notify("Field is secure/unreadable (Tier C)") end -- Tier C
  local tier  = elem:isAttributeSettable("AXValue") and "A" or "B"
  self.session = {
    elem = elem,
    tier = tier,
    app  = hs.application.frontmostApplication(),   -- stash source app/PID
    path = ("/tmp/instantvim-%s.md"):format(hs.host.uuid()),
  }
  hs.execute(("printf '%%s' %q > %q"):format(value, self.session.path))
  self:launchHost(self.session.path)
end
```

**Write-back, Tier A (called from nvim via `hs -c`):**
```lua
function obj:writeBack()
  local s = self.session; if not s or s.tier ~= "A" then return end
  local f = io.open(s.path, "r"); local txt = f:read("*a"); f:close()
  s.elem:setAttributeValue("AXValue", txt)   -- no focus change → safe to call live
end
```

**Close / Tier B paste-back:**
```lua
function obj:onClose()
  local s = self.session; if not s then return end
  if s.tier == "B" then
    local f = io.open(s.path, "r"); local txt = f:read("*a"); f:close()
    local saved = hs.pasteboard.getContents()
    s.app:activate()
    hs.timer.doAfter(0.15, function()
      hs.pasteboard.setContents(txt)
      hs.eventtap.keyStroke({"cmd"}, "a"); hs.eventtap.keyStroke({"cmd"}, "v")
      hs.timer.doAfter(0.15, function() hs.pasteboard.setContents(saved or "") end)
    end)
  end
  self:hideHost(); os.remove(s.path); self.session = nil
end
```

**nvim/instantvim.lua:**
```lua
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_create_autocmd("BufWritePost", {
  buffer = buf,
  callback = function() vim.fn.jobstart({ "hs", "-c", "spoon.instantvim:writeBack()" }) end,
})
-- onClose is triggered by the dispatcher after nvim exits, so no VimLeave hook needed
-- when using the FIFO host. Add a VimLeave fallback only for host fallback #2.
```

## 8. Config assumptions (change if wrong)

- Hotkey: `hyper+e` (⌃⌥⌘⇧ E).
- Quick terminal toggle: `global:ctrl+grave_accent=toggle_quick_terminal`.
- Neovim: user saves manually with `:w` (live sync is `:w`-driven, not autosave-driven). If autosave is desired later, gate `writeBack` behind a debounce.
- Temp files: `/tmp/instantvim-*.md`, deleted on close.
- Editor config: none injected — launch bare `nvim` so the user's full config loads. That's the whole point.

## 9. Open questions (decide during build)

- ~~**Selection vs whole-field.**~~ **Resolved (v0.3):** a highlighted selection at capture time scopes both read and write-back to just that range, on both Tier A (`AXSelectedText`, live) and Tier B (plain copy/paste, on quit) — see README's "Selection-scoped editing". `AXSelectedTextRange` is read at capture only to re-highlight the replaced text afterwards, never to splice document text, which sidesteps needing it to be reliable in Tier B.
- **Filetype inference.** Worth a per-app/per-URL map (Tier A native code editor → detect language)? Or always `.md`? Start with `.md`.
- **Concurrency.** Single quick terminal ⇒ one edit session at a time. Enforce a lock; ignore or queue a second hotkey press while a session is open.
- **Ghostty version drift.** Re-check Constraint #6 against the installed version at build time; if macOS `+new-window --command` works now, replace the FIFO dispatcher with a direct IPC call.

## 10. Definition of done

Global hotkey opens my real Neovim in the Ghostty quick terminal on the focused field's contents; edits sync back live in native fields and on-quit in Electron/browser fields; secure fields are refused cleanly; clipboard and focus are left as they were; no Ghostty instance sprawl; all config lives in one documented `init.lua` table.

## 11. Attribution

instantvim is a **fresh repository** that adapts a pattern from prior work; it is **not a git fork** of any upstream. Do the following before first commit and treat it as a build acceptance item, not an afterthought.

**Before writing code:**
1. Open `editWithEmacs.spoon`'s `LICENSE` file (https://github.com/dmgerman/editWithEmacs.spoon) and read it. Most Hammerspoon Spoons are MIT, but **verify — do not assume**. Note the license type and the copyright line (author + year) verbatim.
2. If it is MIT (or similar permissive), you may reuse code. If it is copyleft (GPL/LGPL) or has no license at all, **stop and surface this to the user** — "no license" means no reuse rights by default, and copyleft would force instantvim's license. Do not silently copy in either case.

**In the repo:**
3. Add instantvim's own `LICENSE` (default MIT unless the user says otherwise; if any upstream is copyleft, match it or write original code only).
4. For any file that is a **near-verbatim** port of an editWithEmacs source file (the callback wiring is the likely candidate), preserve the original copyright header **and** add yours below it, e.g.:
   ```
   -- Portions adapted from editWithEmacs.spoon
   --   Copyright (c) <year> <original author>, <original license>
   --   https://github.com/dmgerman/editWithEmacs.spoon
   -- Modifications Copyright (c) 2026 <your name>, MIT
   ```
5. For files that only **share the design** (the tier engine, the Ghostty host, the nvim autocmds — original code), no header is required; the README credit covers them.

**README — add a `## Credits` (or `## Acknowledgements`) section:**
6. State the lineage honestly and specifically. Draft:
   > The hotkey → capture → external-editor → write-back round-trip, and the Hammerspoon↔editor callback over the `hs` CLI, are adapted from **editWithEmacs.spoon** by David M. German (and forks by Jeremy Friesen and Stuart Warren). instantvim retargets that pattern to Neovim + Ghostty and replaces the clipboard-based write-back with an Accessibility-API capability-tier engine. Field-reading approach informed by **VimMode.spoon** by David Balatero.
7. Link every named project. Verify the real names against each repo's own author/`LICENSE`/README rather than trusting the draft above — get people's names right.

**Acceptance:** `LICENSE` present and compatible with every reused source; every near-verbatim file carries a dual header; README `Credits` names and links editWithEmacs.spoon (and VimMode.spoon) with an accurate one-line description of what was borrowed. If any upstream license blocks reuse, that was raised with the user, not worked around.
