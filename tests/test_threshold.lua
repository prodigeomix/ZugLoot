-- tests/test_threshold.lua
-- Party loot threshold (GetLootThreshold: 1 common .. 4 epic) is the single
-- roll-row cutoff: grey (quality 0) is always free; anything below the
-- threshold loots straight to the player (plain LootSlot, even under
-- master loot); at/above it rolls (group-loot method: Blizzard's
-- Need/Greed owns those rows, we only list them).
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else T.pass = T.pass + 1 end
end
local function ok(v, msg)
  if not v then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else T.pass = T.pass + 1 end
end

-- Save client globals (other test files share this lua state; restore at
-- the end so this file runs in any order).
local saveThreshold = GetLootThreshold
local saveMethod = GetLootMethod
local saveNum = GetNumLootItems
local saveLink = GetLootSlotLink
local saveInfo = GetLootSlotInfo
local saveItemInfo = GetItemInfo
local saveUnit = UnitName
local saveLootSlot = LootSlot
local saveMaster = GiveMasterLoot

ZugLoot = {}
dofile("Util.lua")
dofile("Constants.lua")
dofile("ClassColors.lua")
dofile("Timer.lua")

ZugLoot.Caps = ZugLoot.Caps or { SR = 100, MS = 100, OS = 99, TMOG = 98 }
ZugLoot.Print = function() end
time = time or os.time
CreateFrame = nil -- headless: data layer only

local grouping, method, thresh = "solo", nil, 2
ZugLoot.SRSecurity = {
  IsSolo = function() return grouping == "solo" end,
  LootMethod = function() return method end,
}
GetLootThreshold = function() return thresh end
GetLootMethod = function() return method end

local lootSlots = {}
GetNumLootItems = function() return #lootSlots end
GetLootSlotLink = function(slot) return lootSlots[slot] and lootSlots[slot].link end
GetLootSlotInfo = function(slot)
  local s = lootSlots[slot]
  if not s then return nil end
  return "tex", s.name or s.link, 1, s.quality
end
GetItemInfo = function() return nil end -- cold cache

dofile("RollList.lua")
dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")
local LW = ZugLoot.LootWindow
local ML = ZugLoot.MasterLootUI

local function scanKinds()
  local kinds = {}
  for slot = 1, GetNumLootItems() do
    local e = ML.ScanSlot(slot, nil) -- nil = live party threshold
    if e.coin then kinds[#kinds + 1] = "coin"
    elseif e.group then kinds[#kinds + 1] = "group"
    elseif e.free then kinds[#kinds + 1] = "free"
    else kinds[#kinds + 1] = "roll" end
  end
  return kinds
end

-- 1. Uncommon threshold (party default): grey/white free, green+ rolls.
grouping, method, thresh = "solo", nil, 2
lootSlots = {
  { link = "item:5001:0:0:0", quality = 0, name = "Ruined Pelt" },
  { link = "item:5002:0:0:0", quality = 1, name = "Linen Cloth" },
  { link = "item:5003:0:0:0", quality = 2, name = "Green Tunic" },
  { link = "item:5004:0:0:0", quality = 3, name = "Blue Blade" },
  { link = "item:5005:0:0:0", quality = 4, name = "Epic Helm" },
}
eq(table.concat(scanKinds(), ","), "free,free,roll,roll,roll", "uncommon: grey/white free, green+ roll")
eq(ML.LootThreshold(), 2, "live threshold read")

-- 2. Grey is always free, even at an epic threshold — and even at a
-- common (1) threshold: poor (0) is below everything. Green/blue free
-- too at epic.
thresh = 4
eq(table.concat(scanKinds(), ","), "free,free,free,free,roll", "epic: only epics roll")
eq(ML.LootThreshold(), 4, "threshold follows the party setting")
thresh = 1
lootSlots = {
  { link = "item:5001:0:0:0", quality = 0, name = "Ruined Pelt" },
  { link = "item:5002:0:0:0", quality = 1, name = "Linen Cloth" },
}
eq(table.concat(scanKinds(), ","), "free,roll", "common: grey still free, white rolls")
thresh = 2

-- 3. Group-loot method: at-threshold items are Blizzard group rolls
-- (listed, never looted); below-threshold stays free.
grouping, method, thresh = "party", "group", 2
lootSlots = {
  { link = "item:5001:0:0:0", quality = 0, name = "Ruined Pelt" },
  { link = "item:5002:0:0:0", quality = 1, name = "Linen Cloth" },
  { link = "item:5003:0:0:0", quality = 2, name = "Green Tunic" },
  { link = "item:5004:0:0:0", quality = 3, name = "Blue Blade" },
  { link = "item:5005:0:0:0", quality = 4, name = "Epic Helm" },
}
local kinds = scanKinds()
eq(table.concat(kinds, ","), "free,free,group,group,group", "group loot owns at-threshold rows")

-- 4. No client API (headless): falls back to uncommon.
GetLootThreshold = nil
eq(ML.LootThreshold(), 2, "fallback is uncommon")
GetLootThreshold = function() return thresh end
thresh = 2

-- 5. Unknown quality (cold cache, no slot quality): never a roll row.
lootSlots = { { link = "item:5009:0:0:0", quality = nil, name = "Mystery" } }
local e = ML.ScanSlot(1, nil)
ok(e ~= nil and e.free and not e.group, "unknown quality is free, not rollable")

-- 6. Explicit threshold arg still honored (rare+ callers).
lootSlots = { { link = "item:5003:0:0:0", quality = 2, name = "Green Tunic" } }
local er = ML.ScanSlot(1, 4)
ok(er ~= nil and er.free, "explicit rare cutoff keeps greens free")

-- 7. ML self-take of a below-threshold item under MASTER loot goes
-- through the handoff with the ML's own index (verified live: plain
-- LootSlot is a silent no-op there — LOOT-ISSUED ok=true, server
-- ignores it, row strands [done]).
grouping, method, thresh = "party", "master", 2
UnitName = function() return "Me" end
ZugLoot.SRSecurity.AmML = function() return true end
LW.blizzardTakeover = true
ML.lootOpen = true
local plain, master = {}, {}
LootSlot = function(s, f) table.insert(plain, { s, f }) end
GiveMasterLoot = function(slot, idx) table.insert(master, { slot, idx }) end
GetMasterLootCandidate = function(a, b)
  local i = (type(a) == "number" and b == nil) and a or b
  if i == 1 then return "Me" end
  return nil
end
lootSlots = { { link = "item:5001:0:0:0", quality = 0, name = "Ruined Pelt" } }
local scanned = ML.ScanSlot(1, nil)
ok(scanned ~= nil and scanned.free, "grey scans free under master loot")
LW.SetItems({ { itemID = 5001, link = "item:5001:0:0:0",
  quality = 0, slot = 1, free = true } }, "loot")
eq(LW.OnRowClick(5001, 1), "looting", "grey click loots (ML self-take)")
eq(#master, 1, "ML grey self-take hands off via master loot")
eq(master[1][1], 1, "correct corpse slot")
eq(master[1][2], 1, "own candidate index")
eq(#plain, 0, "no dead plain LootSlot for ML self-take")
GetMasterLootCandidate = nil
ZugLoot.SRSecurity.AmML = nil

-- Restore client globals for the other test files.
GetLootThreshold = saveThreshold
GetLootMethod = saveMethod
GetNumLootItems = saveNum
GetLootSlotLink = saveLink
GetLootSlotInfo = saveInfo
GetItemInfo = saveItemInfo
UnitName = saveUnit
LootSlot = saveLootSlot
GiveMasterLoot = saveMaster

return T
