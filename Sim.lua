-- ZugLoot/Sim.lua
-- In-game simulation: /zl sim <link> [N], /zl simboss <boss>.
-- Uses the same Resolver as live rolls.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.Sim = M

function M.SimItem(argText)
  local link, n = string.match((argText or ""), "(%S+)%s*(%d*)")
  local itemID = Z.Util.ItemID(link or "")
  if not itemID then Z.Print("Usage: /zl sim <itemlink|itemID> [fillers]") return end
  local fillers = tonumber(n) or 2
  local sheet = (Z.DB and Z.DB.sheet) or Z.SRData.NewSheet()
  local rolls = Z.Resolver.FakeRolls(sheet, itemID, { cap = Z.Caps.SR, fillers = fillers })
  local res = Z.Resolver.ResolveItem(sheet, itemID, rolls, { cap = Z.Caps.SR, requireSR = sheet.items[itemID] ~= nil, itemCount = 1 })
  Z.Print("SIM item " .. itemID .. " (" .. Z.Util.ArrayCount(rolls) .. " rolls):")
  for i = 1, Z.Util.ArrayCount(res.entries) do
    local e = res.entries[i]
    local tag = e.missroll and " MISSRROLL(ignored)" or ""
    local won = (sheet.won[itemID] and sheet.won[itemID][e.name]) and " WON-excluded" or ""
    Z.Print("  roll " .. e.name .. " " .. e.base .. " + " .. (e.sr_plus or 0) .. " = " .. e.effective .. tag .. won)
  end
  if Z.Util.ArrayCount(res.winners) > 0 then
    Z.Print("  => winner: " .. res.winners[1].name .. " (" .. res.winners[1].effective .. ")")
  else
    Z.Print("  => no winner")
  end
  if Z.Util.ArrayCount(res.tied) > 0 then
    local t = {}
    for i = 1, Z.Util.ArrayCount(res.tied) do table.insert(t, res.tied[i].name) end
    Z.Print("  => tie: " .. table.concat(t, ", ") .. " (re-roll)")
  end
end

function M.SimBoss(name)
  name = Z.Util.Trim(name or "")
  local table_ = Z.BossData[name]
  if not table_ then
    local avail = {}
    for b in pairs(Z.BossData) do table.insert(avail, b) end
    Z.Print("Unknown boss. Try: " .. table.concat(avail, ", "))
    return
  end
  Z.Print("SIM boss " .. name .. " drops:")
  for i = 1, Z.Util.ArrayCount(table_) do
    local itemID = table_[i]
    M.SimItem(tostring(itemID) .. " 1")
  end
end
