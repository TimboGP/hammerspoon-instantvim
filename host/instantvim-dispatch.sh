#!/usr/bin/env bash
# instantvim-dispatch.sh — the dedicated background Ghostty instance's
# `command` (see host/quick-terminal.config and launchd/com.instantvim.qt.plist).
#
# Blocks on a FIFO for a path to edit, runs nvim on it, then tells
# Hammerspoon the session ended so it can paste-back (Tier B) and hide the
# quick terminal. Runs forever as the quick terminal's persistent command;
# each nvim invocation is one instantvim edit session.
set -u

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
