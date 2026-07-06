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

local function callHammerspoon(fn, opts)
  vim.fn.jobstart({ "hs", "-c", "spoon.instantvim:" .. fn .. "()" }, opts or {})
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
-- harmless. `detach = true` because nvim is exiting right after this
-- callback runs and would otherwise take the job down with it before `hs`
-- finishes.
vim.api.nvim_create_autocmd("VimLeave", {
  callback = function() callHammerspoon("onClose", { detach = true }) end,
})
