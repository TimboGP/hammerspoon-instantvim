--- menubar.lua — menu bar status item for instantvim.
---
--- Same minimal shape as WindowMgmt.spoon's menubar module: a status title
--- plus a lazily-built menu (setMenu takes a function, called by
--- hs.menubar each time before it's shown, so it always reflects current
--- state without needing manual refresh calls).

local M = {}

local item = nil

function M.start()
  item = hs.menubar.new()
  M.setStatus("idle")
  return item
end

function M.stop()
  if item then
    item:delete()
    item = nil
  end
end

function M.setStatus(text)
  if item then
    item:setTitle("✎ " .. text)
  end
end

function M.setMenu(menuTable)
  if item then
    item:setMenu(menuTable)
  end
end

return M
