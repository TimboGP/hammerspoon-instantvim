--- menubar.lua — menu bar status item for instantvim.
---
--- Same minimal shape as WindowMgmt.spoon's menubar module: a status title
--- plus a lazily-built menu (setMenu takes a function, called by
--- hs.menubar each time before it's shown, so it always reflects current
--- state without needing manual refresh calls).

local M = {}

local item = nil
local blinkTimer = nil
local blinkVisible = true
local label = nil -- nil while idle; a short tag like "A" or "AR" while editing

-- labelColor is the system dynamic color menu bar text normally renders in
-- (adapts to light/dark mode on its own). The blink toggles its alpha
-- rather than swapping the "_" for spaces -- no substitute character has
-- the exact same advance width as "_", which made the icon visibly creep
-- left/right on every tick. Same glyph, same run, only alpha changes: the
-- layout literally cannot shift.
local LABEL_COLOR = { list = "System", name = "labelColor" }

local function render()
  if not item then return end
  if not label then
    item:setTitle("")
    return
  end
  local text = hs.styledtext.new(" (" .. label .. ")", { color = LABEL_COLOR })
  local cursorColor = blinkVisible and LABEL_COLOR or { list = "System", name = "labelColor", alpha = 0 }
  local cursor = hs.styledtext.new("_", { color = cursorColor })
  item:setTitle(text .. cursor)
end

--- M.start(iconPath) -- iconPath is the menu bar glyph, rendered as a
--- template image so macOS recolors it for light/dark mode and the
--- menu-open highlight automatically. The source PNG is stored at 3x pixel
--- density; sizing it down to 19x18pt here (rather than shipping a smaller
--- file) keeps it crisp on Retina displays.
function M.start(iconPath)
  item = hs.menubar.new()
  local icon = hs.image.imageFromPath(iconPath)
  if icon then
    icon:size({ w = 19, h = 18 }, true)
    item:setIcon(icon)
  end
  M.setStatus(nil)
  return item
end

function M.stop()
  if blinkTimer then
    blinkTimer:stop()
    blinkTimer = nil
  end
  if item then
    item:delete()
    item = nil
  end
end

--- M.setStatus(tag) -- tag nil/false means idle (icon only, no blink).
--- Any other value is shown as "(tag)" next to the icon with a blinking
--- text-cursor "_", e.g. setStatus("A") or setStatus("AR") for tier A rich.
function M.setStatus(tag)
  label = tag or nil
  if label and not blinkTimer then
    blinkVisible = true
    blinkTimer = hs.timer.new(0.8, function()
      blinkVisible = not blinkVisible
      render()
    end)
    blinkTimer:start()
  elseif not label and blinkTimer then
    blinkTimer:stop()
    blinkTimer = nil
    blinkVisible = true
  end
  render()
end

function M.setMenu(menuTable)
  if item then
    item:setMenu(menuTable)
  end
end

return M
