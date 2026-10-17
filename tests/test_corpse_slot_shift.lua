-- tests/test_corpse_slot_shift.lua
-- Verification of corpse slot shifting, candidate dynamic re-resolution, and C-API fallback.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then
    T.fail = T.fail + 1
    table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else
    T.pass = T.pass + 1
  end
end

local function ok(v, msg)
  if not v then
    T.fail = T.fail + 1
    table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else
    T.pass = T.pass + 1
  end
end

ZugLoot = {}
dofile("Constants.lua")
dofile("Util.lua")
dofile("ClassColors.lua")
dofile("Timer.lua")
dofile("RollList.lua")
dofile("SRData.lua")
dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")

local ML = ZugLoot.MasterLootUI
local LW = ZugLoot.LootWindow

-- Mock state
local loot = {}
local candidates = {}
local masterCalls = {}

GetNumLootItems = function() return #loot end
GetLootSlotLink = function(slot) return loot[slot] and loot[slot].link end
GetLootSlotInfo = function(slot)
  local item = loot[slot]
  if not item then return nil end
  return "texture", item.link, 1, item.quality
end
GetItemInfo = function(link)
  for _, item in ipairs(loot) do
    if item.link == link then
      return "Item " .. item.id, item.link, item.quality
    end
  end
  return nil
end
GetLootMethod = function() return "master" end
GetLootThreshold = function() return 2 end -- green+ is roll
UnitName = function(u) return u == "player" and "MasterLooter" or nil end

GetMasterLootCandidate = function(idx)
  return candidates[idx]
end

GiveMasterLoot = function(slot, candidateIdx)
  table.insert(masterCalls, { slot = slot, idx = candidateIdx, api = "GiveMasterLoot" })
end

ZugLoot.SRSecurity = {
  IsSolo = function() return false end,
  IsInRaid = function() return true end,
  IsInGroup = function() return true end,
  AmML = function() return true end,
  LootMethod = function() return "master" end,
}

-- 1. Test Corpse Slot Shift Reconciliation
-- Initial corpse:
-- Slot 1: 5001 (Grey Ruined Pelt)
-- Slot 2: 17001 (Epic Pants)
-- Slot 3: 17002 (Epic Robe)
loot = {
  { id = 5001, link = "item:5001:0:0:0", quality = 0 },
  { id = 17001, link = "item:17001:0:0:0", quality = 4 },
  { id = 17002, link = "item:17002:0:0:0", quality = 4 },
}
candidates = { "WarriorA", "PriestB", "MageC" }

ML.lootOpen = true
LW.SetItems({
  { itemID = 5001, link = "item:5001:0:0:0", quality = 0, slot = 1, free = true },
  { itemID = 17001, link = "item:17001:0:0:0", quality = 4, slot = 2 },
  { itemID = 17002, link = "item:17002:0:0:0", quality = 4, slot = 3 },
}, "loot")

-- Now slot 1 (trash) is looted off corpse! Slots collapse in WoW engine!
table.remove(loot, 1)
-- Now corpse is:
-- Slot 1: 17001
-- Slot 2: 17002
eq(#loot, 2, "corpse collapsed to 2 slots")

-- Award item 17002 (was slot 3 at scan time, now slot 2) to PriestB
masterCalls = {}
local res = ML.Award(17002, "PriestB")
ok(res ~= false, "award succeeded")
eq(#masterCalls, 1, "exactly one master loot call issued")
eq(masterCalls[1].slot, 2, "corpse slot shift reconciled: targeted slot 2, not stale slot 3")
eq(masterCalls[1].idx, 2, "PriestB candidate index matched")

-- 2. Test Candidate Index Shift (Player in front released spirit / moved out of range)
-- WarriorA leaves range, so PriestB shifts from candidate 2 to candidate 1
candidates = { "PriestB", "MageC" }
masterCalls = {}
-- Award remaining item 17001 (which is at slot 1) to PriestB
local res2 = ML.Award(17001, "PriestB")
ok(res2 ~= false, "award succeeded")
eq(#masterCalls, 1, "master loot call issued")
eq(masterCalls[1].slot, 1, "targeted correct slot 1")
eq(masterCalls[1].idx, 1, "dynamically re-resolved candidate index 1 for PriestB, not stale index 2")

-- 3. Test Candidate Disconnected / Out of Range
candidates = { "MageC" } -- PriestB has zoned out
LW.SetItems({ { itemID = 17001, link = "item:17001:0:0:0", quality = 4, slot = 1 } }, "loot")
local res3 = ML.Award(17001, "PriestB")
eq(res3, false, "award refused when player is not a valid loot candidate")

-- 4. Test GiveMasterLootCandidate API Fallback
GiveMasterLoot = nil
GiveMasterLootCandidate = function(slot, candidateIdx)
  table.insert(masterCalls, { slot = slot, idx = candidateIdx, api = "GiveMasterLootCandidate" })
end

masterCalls = {}
loot = { { id = 17001, link = "item:17001:0:0:0", quality = 4 } }
candidates = { "MageC" }
LW.SetItems({ { itemID = 17001, link = "item:17001:0:0:0", quality = 4, slot = 1 } }, "loot")
local res4 = ML.Award(17001, "MageC")
ok(res4 ~= false, "award succeeded with GiveMasterLootCandidate")
eq(#masterCalls, 1, "call issued")
eq(masterCalls[1].api, "GiveMasterLootCandidate", "used GiveMasterLootCandidate fallback")
eq(masterCalls[1].slot, 1, "slot 1")
eq(masterCalls[1].idx, 1, "candidate 1")

if T.fail == 0 then
  print("corpse slot shift and candidate invariants passed")
else
  for _, e in ipairs(T.errors) do print(e) end
  os.exit(1)
end

return T
