# instantvim

Edit any focused text field in any macOS app using your real, fully-configured
Neovim — not a vim emulation layer — then flow the result back into the
original field.

1. Cursor is in some text field (browser textarea, native app, Slack, etc.).
2. Press a global hotkey (default `hyper+e`).
3. A Ghostty quick terminal drops down running your configured `nvim` on a
   temp buffer pre-filled with the field's current contents.
4. Edit. On `:w`, changes flow back into the original field **live** where
   the OS allows it; otherwise they flow back **on quit**.
5. Quick terminal hides; focus returns to the original app.

## How it works

At capture time, instantvim probes the focused element's accessibility
attributes and classifies it into one of three tiers:

| Tier | Condition | Write-back | Live? |
|------|-----------|-----------|-------|
| **A** | `AXValue` readable and settable (most native Cocoa fields) | `setAttributeValue` — no focus change | Yes, on every `:w` |
| **B** | readable but not settable (Electron, browser `contentEditable`) | refocus source + paste | No — quit only |
| **C** | not readable (secure/password fields) | — | Refused, notified |

There is no single write path that works everywhere — the tier is detected
per field, at runtime. See [`instantvim-handover.md`](instantvim-handover.md)
for the full design rationale.

The nvim host runs inside a **dedicated background Ghostty instance**
(launched via `launchd`, hidden, never shown as a normal window) whose
`command` is a small FIFO dispatcher loop. Hammerspoon writes the temp file
path into the FIFO and simulates that instance's own (internal-only)
quick-terminal keybind to show/hide it. This exists because macOS Ghostty has
no CLI/IPC way to push a command into an already-running quick terminal
(verified against Ghostty 1.3.1 — `+new-window` reports "not supported on
this platform" on macOS).

## Install

```sh
./install.sh
```

**Required, not optional** — `hostMode = "qt"` (the default) does nothing
without it. Symlinking the Spoon and calling `spoon.instantvim:start()` is
enough to get the hotkey, capture, and tier detection working, but with no
dedicated Ghostty instance running there's nothing listening on the FIFO:
the hotkey fires, the menu bar tracks "editing (A)", a temp file gets
written — and no terminal ever appears, silently. That exact symptom means
`install.sh` hasn't been run (or the launchd agent isn't loaded) — see
Troubleshooting below.

`install.sh` symlinks the Spoon into `~/.hammerspoon/Spoons`, ensures the
`hs` CLI is installed, creates the FIFO, generates and loads the `launchd`
agent for the dedicated Ghostty instance. It's safe to re-run any time. It
prints two manual steps it deliberately does *not* do for you (editing your
Hammerspoon and Neovim configs directly), since those are your dotfiles:

1. Add to your Hammerspoon config:
   ```lua
   hs.loadSpoon("instantvim")
   spoon.instantvim:start()
   ```
2. Add to your Neovim config, so instantvim's buffers get live write-back and
   cleanup wired up:
   ```lua
   vim.api.nvim_create_autocmd("BufReadPost", {
     pattern = "/tmp/instantvim-*",
     callback = function() dofile("/absolute/path/to/instantvim/nvim/instantvim.lua") end,
   })
   ```

## Menu bar

`spoon.instantvim:start()` adds a "✎ idle" menu bar item (title tracks live
session state, e.g. "✎ editing (A)"). Its menu:

- **Edit Focused Field** — same action as the hotkey.
- **Host Mode** — switch `qt`/`window`/`keystroke` live.
- **Restart Quick Terminal Host** — `launchctl kickstart`s the dedicated
  Ghostty instance, for when the FIFO dispatcher gets stuck.
- **Reload Config** — `hs.reload()`.

## Configuration

All configuration lives in `spoon.instantvim.config` (see
[`init.lua`](init.lua) for the full, documented table). Notable keys:

- `hotkey` — the trigger, default `hyper+e`.
- `hostMode` — `"qt"` (dedicated quick terminal, the default), `"window"`
  (throwaway `open -na Ghostty` instance per invocation), or `"keystroke"`
  (type `nvim <path>` into whatever's focused). `"window"`/`"keystroke"` are
  useful for bringing the round trip up before the quick-terminal host is
  installed.
- `filetypeByBundleID` / `filetypeByURLPattern` — extension inference so nvim
  gets useful syntax/LSP for the temp buffer. Defaults to `.md`.
- `tierOverrideByBundleID` — force a tier for apps that misreport
  `isAttributeSettable`.

## Repo layout

The repo root doubles as the `.spoon` directory (same convention as
`editWithEmacs.spoon` and `WindowMgmt.spoon`), so it can be symlinked or
`git submodule add`-ed straight into `~/.hammerspoon/Spoons/instantvim.spoon`.

```
init.lua, capture.lua, menubar.lua   hotkey, AX capture/probe, tier engine, menu bar
host/                                 FIFO dispatcher + dedicated Ghostty instance config
nvim/                                 BufWritePost / VimLeave wiring
launchd/                              background agent for the dedicated Ghostty instance
install.sh
```

## Troubleshooting

**Hotkey works, menu bar tracks an active session, but no terminal ever
appears.** `install.sh` hasn't been run (or its launchd agent didn't load),
so there's no dedicated Ghostty instance listening for the FIFO write.
Check, in order:

```sh
# Is the launchd agent registered and running?
launchctl print gui/$(id -u)/com.instantvim.qt | grep state

# Is the dedicated instance actually up? (there should be two Ghostty
# processes: your normal one, plus this one with --config-file=...quick-terminal.config)
ps aux | grep -i ghostty

# Is the FIFO a real named pipe, not a stray regular file left behind by
# writing to a path that didn't exist yet?
file /tmp/instantvim.fifo   # must say "fifo (named pipe)", not "ASCII text"
```

If any of those look wrong, run `./install.sh` (safe to re-run) and try
the hotkey again.

**Terminal appears but nvim doesn't launch inside it.** Ghostty spawns the
dispatcher via a login shell with `--noprofile --norc`, so `PATH` stays at
the bare macOS default and never picks up Homebrew's `bin` dirs — fixed as
of the dispatcher script exporting `PATH` itself, but if you're running an
older checkout, `git pull` the submodule/repo and re-run `install.sh`
(which restarts the dedicated instance).

## Credits

The hotkey → capture → external-editor → write-back round-trip, and the
Hammerspoon↔editor callback over the `hs` CLI, are adapted from
[**editWithEmacs.spoon**](https://github.com/dmgerman/editWithEmacs.spoon) by
Daniel German (with Jeremy Friesen), MIT-licensed (declared in-code in the
project's `init.lua`; forks by
[Jeremy Friesen](https://github.com/jeremyf/editWithEmacs.spoon) and
[Stuart Warren](https://github.com/stuart-warren/editWithEmacs.spoon) were
also consulted). instantvim retargets that pattern to Neovim + Ghostty and
replaces the clipboard-based write-back with an Accessibility-API
capability-tier engine.

Field-reading approach informed by
[**VimMode.spoon**](https://github.com/dbalatero/VimMode.spoon) by David
Balatero, and its author's writeup on [retrieving input field values and
cursor position with
Hammerspoon](https://balatero.com/writings/hammerspoon/retrieving-input-field-values-and-cursor-position-with-hammerspoon/).
No code from VimMode.spoon is reused — it's cited for its documentation of
what the Accessibility API does and doesn't expose.

## License

MIT — see [`LICENSE`](LICENSE).
