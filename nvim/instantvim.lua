-- instantvim.lua — nvim-side wiring for instantvim.
--
-- Wires the current buffer's BufWritePost to instantvim's Tier A live
-- write-back, and (globally, once) VimLeave to onClose, so the source
-- field updates as you `:w` and the session gets cleaned up when you quit.
--
-- This file is NOT auto-loaded by instantvim's launch (by design: nvim is
-- started bare so your full personal config loads untouched). Wire it up
-- once in your own config, e.g.:
--
--   vim.api.nvim_create_autocmd("BufReadPost", {
--     pattern = "/tmp/instantvim-*",
--     callback = function() dofile("/absolute/path/to/instantvim/nvim/instantvim.lua") end,
--   })

local buf = vim.api.nvim_get_current_buf()

-- Same root cause as instantvim's own nvimPath resolution (see README
-- Troubleshooting): Ghostty's `-e` runs nvim through `/usr/bin/login`,
-- which `exec`s it directly rather than through a shell, so nvim's own
-- $PATH never picks up entries a shell profile adds (e.g. Homebrew's
-- /opt/homebrew/bin, where `hs` typically lives). A bare
-- jobstart({"hs", ...}) fails with "'hs' is not executable" as a result.
-- Routing through `$SHELL -lc` forces a login shell that sources the
-- profile, so `hs` resolves the same way it would in a normal terminal.
-- Always detach: routing through a login shell (below) makes job startup
-- slow enough (it sources your shell profile) that `:wq` -- write and quit
-- in the same command -- reliably kills the writeBack job before `hs` gets
-- to run, since nvim exits right after BufWritePost fires with no gap for
-- an undetached job to finish in. Same reasoning already applied to the
-- VimLeave/onClose call below; it now applies here too.
local function callHammerspoon(fn, opts)
  local cmd = string.format("hs -c 'spoon.instantvim:%s()'", fn)
  local jobOpts = opts or {}
  jobOpts.detach = true
  vim.fn.jobstart({ vim.o.shell, "-lc", cmd }, jobOpts)
end

vim.api.nvim_create_autocmd("BufWritePost", {
  buffer = buf,
  callback = function() callHammerspoon("writeBack") end,
})

-- Global, not buffer-scoped: VimLeave fires once for the whole nvim
-- process, and there is no guarantee the instantvim buffer is still
-- `current` at that point (e.g. the user opened other splits/buffers
-- while editing). A buffer-local VimLeave autocmd would silently miss
-- that case.
--
-- This is the primary path for onClose(): both host modes ("window" and
-- "keystroke") just launch nvim directly, with nothing else watching for
-- it to exit. onClose() is idempotent, so firing it more than once is
-- harmless.
vim.api.nvim_create_autocmd("VimLeave", {
  callback = function() callHammerspoon("onClose") end,
})
