# instantvim

Edit any focused text field in any macOS app using your real, fully-configured
Neovim — not a vim emulation layer — then flow the result back into the
original field.

1. Cursor is in some text field (browser textarea, native app, Slack, etc.).
2. Press a global hotkey (default `hyper+e`).
3. A fresh Ghostty window opens running your configured `nvim` on a temp
   buffer pre-filled with the field's current contents.
4. Edit. On `:w`, changes flow back into the original field **live** where
   the OS allows it; otherwise they flow back **on quit**.
5. Quitting nvim closes the window; focus returns to the original app.

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

### Selection-scoped editing

If you highlight some text before pressing the hotkey, instantvim edits just
that selection instead of the whole field — write-back replaces only the
highlighted range, and re-highlights whatever you wrote in its place so it's
obvious what changed. No selection at capture time means the usual
whole-field behavior, unchanged.

This works over both AX write paths: Tier A fields replace via
`AXSelectedText` (the same attribute VoiceOver/dictation use to type over a
selection) on every `:w`; Tier B fields capture the selection via a plain
copy (no select-all) and paste back over it — still on quit only, since
paste still needs to refocus the source app. Formatting inside the
selection is not preserved (see [`wishlist.md`](wishlist.md)).

The nvim host runs as a **fresh, throwaway Ghostty instance per edit**
(`open -na Ghostty --args -e nvim <path>`). An earlier design ran nvim
inside a dedicated background Ghostty instance's quick terminal instead
(FIFO-dispatched, to work around macOS Ghostty having no CLI/IPC way to
push a command into an already-running quick terminal — verified against
Ghostty 1.3.1, `+new-window` reports "not supported on this platform" on
macOS). That was abandoned: macOS treats `Ghostty.app` as a single-instance
bundle for Dock/Spotlight/`open` activation, so opening Ghostty normally
kept hijacking the hidden dedicated instance instead of launching an
independent one — confirmed the hard way, it left orphaned nvim/dispatcher
processes piling up and made the user's everyday Ghostty unusable. Instead,
each edit gets its own fully independent Ghostty process; instances don't
persist past the edit session, so nothing accumulates beyond one throwaway
window per concurrent edit.

## Install

```sh
./install.sh
```

`install.sh` symlinks the Spoon into `~/.hammerspoon/Spoons` and checks that
the `hs` CLI is installed. It's safe to re-run any time. It prints two
manual steps it deliberately does *not* do for you (editing your
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
- **Cancel Edit Session** — force-clears a stuck/unwanted session (e.g. the
  Ghostty window never launched) without writing anything back to the source
  field. Disabled when there's no active session. Also bindable as a hotkey
  via `cancelHotkey` (unbound by default).
- **Host Mode** — switch `window`/`keystroke` live.
- **Reload Config** — `hs.reload()`.

## Configuration

All configuration lives in `spoon.instantvim.config` (see
[`init.lua`](init.lua) for the full, documented table). Notable keys:

- `hotkey` — the trigger, default `hyper+e`.
- `cancelHotkey` — aborts a stuck edit session (see Menu bar above); unbound
  by default, use the menu item or set this to bind a key.
- `hostMode` — `"window"` (throwaway `open -na Ghostty` instance per
  invocation, the default), or `"keystroke"` (type `nvim <path>` into
  whatever's focused; racy, last resort).
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
nvim/                                 BufWritePost / VimLeave wiring
install.sh
```

## Troubleshooting

**Hotkey works, menu bar tracks an active session, but no terminal ever
appears.** Check that `ghosttyAppPath`/`nvimPath` in `spoon.instantvim.config`
point at a real Ghostty install and an `nvim` resolvable from `open`'s
environment.

**Ghostty window opens but errors with `login: nvim: No such file or
directory`.** On macOS, Ghostty's `-e` runs the host command through
`/usr/bin/login`, which `exec`s it directly rather than through a shell —
so it never picks up PATH entries a shell profile adds (e.g. Homebrew's
`/opt/homebrew/bin`). instantvim resolves `nvimPath` to an absolute path via
your login shell before launching to work around this; if it still fails,
set `nvimPath` to an absolute path yourself (e.g.
`spoon.instantvim.config.nvimPath = "/opt/homebrew/bin/nvim"`).

**Saving in nvim errors with `'hs' is not executable`, or the field never
live-updates.** Same root cause as above, one level down: nvim's own
`jobstart({"hs", ...})` call (in `nvim/instantvim.lua`) inherits the same
Homebrew-less `$PATH`, so it can't find `hs` either. `nvim/instantvim.lua`
routes that call through `$SHELL -lc` to pick up your shell profile's PATH;
if `hs` still isn't found, make sure it's actually on your login shell's
PATH (`command -v hs` in a fresh terminal).

**A session gets stuck ("edit already in progress") after a launch
failure like the one above.** The lock is only released when nvim's
`VimLeave` fires `onClose()` — if the host never launched, that never
happens. Use **Cancel Edit Session** in the menu bar (or bind
`cancelHotkey`) to drop the lock and clean up the temp file without
touching the source field.

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
