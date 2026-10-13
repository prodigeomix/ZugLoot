-- ZugLoot/DropLog.lua
-- Drop/audit log: every observed drop + award. Ring buffer (cap 500).
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.DropLog = M

function M.Add(itemID, itemLink, source, outcome, winner)
  Z.DB.drops = Z.DB.drops or {}
  table.insert(Z.DB.drops, {
    t = (time and time()) or 0,
    itemID = itemID,
    link = itemLink,
    source = source or "?",
    outcome = outcome or "?",
    winner = winner,
  })
  while Z.Util.ArrayCount(Z.DB.drops) > Z.Limits.DROP_LOG_MAX do
    table.remove(Z.DB.drops, 1)
  end
  if Z.Comm and outcome == "award" then
    -- awards already broadcast by MasterLootUI; log-only here.
  end
end

function M.Clear()
  if not Z.SRSecurity.CanImport() then
    Z.Print("Only the master looter or raid leader can clear the log.")
    return
  end
  Z.DB.drops = {}
  Z.Print("Drop log cleared.")
end

-- Class-colored name for display strings (nil-safe headless).
local function PName(name)
  if Z.ClassColors and Z.ClassColors.ColoredName then
    return Z.ClassColors.ColoredName(name)
  end
  return tostring(name or "")
end

function M.Lines()
  local out = {}
  local n = Z.Util.ArrayCount(Z.DB.drops or {})
  for i = n, 1, -1 do
    local d = Z.DB.drops[i]
    table.insert(out, tostring(d.t) .. " [" .. tostring(d.source) .. "] " .. tostring(d.link or d.itemID) ..
      " " .. tostring(d.outcome) .. (d.winner and (" -> " .. PName(d.winner)) or ""))
  end
  if Z.Util.ArrayCount(out) == 0 then table.insert(out, "(log empty)") end
  return out
end

function M.Show()
  -- Rolls tab in the main window owns the log view now; kept for API compat.
  if Z.MainWindow then Z.MainWindow.Toggle("rolls") return end
end
