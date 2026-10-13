-- ZugLoot/Sim.lua
-- In-game simulation: /zl sim <itemlink|itemID> [fillers], /zl simboss <boss>.
-- Requires the loaded sheet (Z.DB.sheet): every roller is a player from the
-- sheet, and every simulated session is written back into the sheet
-- (sheet.rolls history + won marks + drop log), exactly like a live roll.
-- Uses the same Resolver pure module as real sessions and as tests/.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.Sim = M

function M.RequireSheet()
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then
    Z.Print("Simulation requires a loaded sheet. Import one first: /zl import or Load from File.")
    return nil
  end
  return sheet
end

local function now()
  return (time and time()) or 0
end

-- Print one simulated session (same lines the Sheet tab shows per player).
-- Already-won rollers appear with their roll shown but marked excluded.
local function printSession(itemID, res, sheet)
  local i = 1
  while res.entries and res.entries[i] ~= nil do
    local e = res.entries[i]
    local tag = e.missroll and " MISSRROLL(ignored)" or ""
    local excluded = e.excludedWon or (sheet.won[itemID] and sheet.won[itemID][e.name])
    local won = excluded and " [already won]" or ""
    Z.Print("  roll " .. e.name .. " " .. e.base .. " + " .. (e.sr_plus or 0) .. " = " .. e.effective .. tag .. won)
    i = i + 1
  end
  if Z.Util.ArrayCount(res.winners or {}) > 0 then
    Z.Print("  => winner: " .. res.winners[1].name .. " (" .. res.winners[1].effective .. ")")
  else
    Z.Print("  => no winner")
  end
  if Z.Util.ArrayCount(res.tied or {}) > 0 then
    local t = {}
    for k = 1, Z.Util.ArrayCount(res.tied) do table.insert(t, res.tied[k].name) end
    Z.Print("  => tie: " .. table.concat(t, ", ") .. " (re-roll)")
  end
end

-- Resolve a fake session and write it back: roll history, won marks (skipped
-- on ties — ties need a re-roll, like live), drop log, window refresh.
function M.RunSimSession(sheet, itemID, mode, rolls, itemLink)
  local res = Z.Resolver.ResolveItem(sheet, itemID, rolls,
    { cap = Z.Caps.SR, requireSR = (mode == "SIM"), itemCount = 1 })
  printSession(itemID, res, sheet)
  if Z.Util.ArrayCount(res.entries or {}) > 0 then
    -- Simulated off-sheet item: same unreserved stub as live rolls.
    if Z.SRData.EnsureUnreserved then
      Z.SRData.EnsureUnreserved(sheet, itemID, nil)
    end
    Z.SRData.RecordRolls(sheet, itemID, Z.Resolver.ToHistoryEntry(res, mode, now()))
  end
  local tied = Z.Util.ArrayCount(res.tied or {})
  local winners = res.winners or {}
  if tied == 0 and Z.Util.ArrayCount(winners) > 0 then
    for i = 1, Z.Util.ArrayCount(winners) do
      local name = winners[i].name
      Z.SRData.MarkWon(sheet, itemID, name)
      if Z.DropLog then Z.DropLog.Add(itemID, itemLink, "sim", "award", name) end
    end
  end
  if Z.MainWindow then Z.MainWindow.Refresh() end
  if Z.SRView then Z.SRView.Refresh() end
  return res
end

-- Open-roll fakes for items nobody SR'd: every player on the sheet rolls.
function M.FakeOpenRolls(sheet, fillers, rng)
  rng = rng or function(lo, hi) return math.random(lo, hi) end
  local rolls = {}
  local names = Z.SRData.AllPlayerNames(sheet)
  for i = 1, Z.Util.ArrayCount(names) do
    table.insert(rolls, { name = names[i], roll = rng(1, Z.Caps.SR), type = "MS" })
  end
  for f = 1, (fillers or 0) do
    table.insert(rolls, { name = "Filler" .. f, roll = rng(1, Z.Caps.SR), type = "MS" })
  end
  return rolls
end

function M.SimItem(argText)
  local sheet = M.RequireSheet()
  if not sheet then return end
  local link, n = string.match((argText or ""), "(%S+)%s*(%d*)")
  local itemID = Z.Util.ItemID(link or "")
  if not itemID then Z.Print("Usage: /zl sim <itemlink|itemID> [fillers]") return end
  local fillers = tonumber(n) or 0
  local onSheet = sheet.items[itemID] ~= nil
  local mode, rolls
  if onSheet then
    mode = "SIM"
    rolls = Z.Resolver.FakeRolls(sheet, itemID,
      { cap = Z.Caps.SR, fillers = fillers, sheetOnly = (fillers == 0) })
  else
    mode = "SIM-OPEN"
    rolls = M.FakeOpenRolls(sheet, fillers)
  end
  Z.Print("SIM " .. mode .. " item " .. itemID .. " (" .. Z.Util.ArrayCount(rolls) .. " rolls):")
  return M.RunSimSession(sheet, itemID, mode, rolls, link)
end

function M.SimBoss(name)
  local sheet = M.RequireSheet()
  if not sheet then return end
  name = Z.Util.Trim(name or "")
  local table_ = Z.BossData[name]
  if not table_ then
    local avail = {}
    for b in pairs(Z.BossData) do table.insert(avail, b) end
    Z.Print("Unknown boss. Try: " .. table.concat(avail, ", "))
    return
  end
  Z.Print("SIM boss " .. name .. " drops (sheet players, one-win applies across drops):")
  for i = 1, Z.Util.ArrayCount(table_) do
    local itemID = table_[i]
    M.SimItem(tostring(itemID))
  end
  Z.Print("SIM boss " .. name .. " done — see the Sheet tab.")
end
