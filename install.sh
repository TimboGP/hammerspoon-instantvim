#!/usr/bin/env bash
# install.sh — wire instantvim into Hammerspoon + a dedicated background
# Ghostty quick-terminal instance.
#
# Safe to re-run: every step is idempotent.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMERSPOON_DIR="$HOME/.hammerspoon"
INSTALL_DIR="$HOME/.instantvim"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.instantvim.qt"

echo "== instantvim install =="
echo "repo: $REPO_DIR"

# --- 1. Spoon symlink -------------------------------------------------
mkdir -p "$HAMMERSPOON_DIR/Spoons"
ln -sfn "$REPO_DIR/Spoons/instantvim.spoon" "$HAMMERSPOON_DIR/Spoons/instantvim.spoon"
echo "[ok] Spoons/instantvim.spoon symlinked into $HAMMERSPOON_DIR/Spoons"

# --- 2. hs CLI ----------------------------------------------------------
if ! command -v hs >/dev/null 2>&1; then
  echo "[!!] 'hs' CLI not found on PATH."
  echo "     Open Hammerspoon and run in its console: hs.ipc.cliInstall()"
  echo "     Then re-run this script."
else
  if hs -c "return hs.ipc.cliStatus()" 2>/dev/null | grep -q true; then
    echo "[ok] hs CLI is installed and Hammerspoon's IPC server is up"
  else
    echo "[!!] 'hs' binary found but Hammerspoon's IPC server did not respond."
    echo "     Make sure Hammerspoon is running, then run in its console:"
    echo "       hs.ipc.cliInstall()"
    echo "     instantvim.spoon also checks this itself on :start()."
  fi
fi

# --- 3. FIFO -------------------------------------------------------------
FIFO=/tmp/instantvim.fifo
if [ ! -p "$FIFO" ]; then
  mkfifo "$FIFO"
  echo "[ok] created FIFO at $FIFO"
else
  echo "[ok] FIFO already exists at $FIFO"
fi

# --- 4. Dedicated Ghostty quick-terminal host ----------------------------
mkdir -p "$INSTALL_DIR"
chmod +x "$REPO_DIR/host/instantvim-dispatch.sh"

sed "s|__DISPATCH_SCRIPT__|$REPO_DIR/host/instantvim-dispatch.sh|" \
  "$REPO_DIR/host/quick-terminal.config" > "$INSTALL_DIR/quick-terminal.config"
echo "[ok] generated $INSTALL_DIR/quick-terminal.config"

mkdir -p "$LAUNCH_AGENTS_DIR"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$PLIST_LABEL.plist"
sed "s|__QT_CONFIG_PATH__|$INSTALL_DIR/quick-terminal.config|" \
  "$REPO_DIR/launchd/com.instantvim.qt.plist" > "$PLIST_PATH"
echo "[ok] generated $PLIST_PATH"

UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM/$PLIST_LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST_PATH"
echo "[ok] loaded launchd agent $PLIST_LABEL (dedicated Ghostty instance is starting hidden in the background)"

# --- 5. Manual steps still required --------------------------------------
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
