#!/usr/bin/env bash
# instantvim-dispatch.sh — the dedicated background Ghostty instance's
# `command` (see host/quick-terminal.config and launchd/com.instantvim.qt.plist).
#
# Blocks on a FIFO for a path to edit, runs nvim on it, then tells
# Hammerspoon the session ended so it can paste-back (Tier B) and hide the
# quick terminal. Runs forever as the quick terminal's persistent command;
# each nvim invocation is one instantvim edit session.
set -u

# Ghostty spawns this via a login shell with --noprofile --norc, so none of
# the usual shell startup files run and PATH stays at the bare macOS
# default (/usr/bin:/bin:/usr/sbin:/sbin plus Ghostty's own bundle dir) --
# confirmed empirically: neither `nvim` nor `hs` resolved without this,
# so nvim silently never launched even though the FIFO round-trip worked.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

FIFO="${INSTANTVIM_FIFO:-/tmp/instantvim.fifo}"
[ -p "$FIFO" ] || mkfifo "$FIFO"

while :; do
  if IFS= read -r path < "$FIFO"; then
    if [ -n "$path" ]; then
      nvim -- "$path"
    fi
    hs -c "spoon.instantvim:onClose()"
  fi
done
