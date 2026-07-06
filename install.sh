#!/usr/bin/env bash
# install.sh — wire instantvim into Hammerspoon.
#
# Safe to re-run: every step is idempotent.
set -euo pipefail

# -P resolves symlinks physically. Without it, running this script through
# the ~/.hammerspoon/Spoons/instantvim.spoon convenience symlink resolves
# REPO_DIR to that symlink's own path -- and since step 1 below re-creates
# that exact symlink from REPO_DIR, a plain (logical) `cd`/`pwd` here turns
# it into a symlink pointing at itself (confirmed the hard way).
REPO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HAMMERSPOON_DIR="$HOME/.hammerspoon"

echo "== instantvim install =="
echo "repo: $REPO_DIR"

# --- 1. Spoon symlink -------------------------------------------------
# The repo root doubles as the .spoon directory (init.lua lives here
# alongside nvim/), matching how Hammerspoon Spoon repos are conventionally
# structured.
mkdir -p "$HAMMERSPOON_DIR/Spoons"
ln -sfn "$REPO_DIR" "$HAMMERSPOON_DIR/Spoons/instantvim.spoon"
echo "[ok] repo symlinked as $HAMMERSPOON_DIR/Spoons/instantvim.spoon"

# --- 2. hs CLI ----------------------------------------------------------
# Checked via PATH, not hs.ipc.cliStatus() -- that only looks for the CLI at
# cliInstall()'s default location (/usr/local/bin/hs), which reports a false
# negative on Apple Silicon + Homebrew setups where `hs` lives on PATH via
# /opt/homebrew/bin/hs instead. instantvim.spoon's own :start() does the
# same PATH-based check.
if command -v hs >/dev/null 2>&1; then
  echo "[ok] 'hs' CLI found on PATH ($(command -v hs))"
else
  echo "[!!] 'hs' CLI not found on PATH."
  echo "     Open Hammerspoon and run in its console: hs.ipc.cliInstall()"
  echo "     Then re-run this script."
fi

# --- 3. Manual steps still required --------------------------------------
cat <<EOF

== Remaining manual steps ==

1. Add to your Hammerspoon init.lua:

     hs.loadSpoon("instantvim")
     spoon.instantvim:start()

   Then reload Hammerspoon config (its menu bar icon -> Reload Config).

2. Add to your Neovim config, so instantvim's buffers get live write-back
   and cleanup wired up:

     vim.api.nvim_create_autocmd("BufReadPost", {
       pattern = "/tmp/instantvim-*",
       callback = function() dofile("$REPO_DIR/nvim/instantvim.lua") end,
     })

3. Press the hotkey (default: hyper+e / ctrl+alt+cmd+shift+e) in any text
   field to try it out.

EOF
