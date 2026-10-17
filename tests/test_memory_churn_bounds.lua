-- tests/test_memory_churn_bounds.lua
-- Memory allocation churn measurement and SavedVariables bounding verification.
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
dofile("Resolver.lua")
dofile("DropLog.lua")
dofile("RaidArchive.lua")

local Timer = ZugLoot.Timer
local DropLog = ZugLoot.DropLog
local RaidArchive = ZugLoot.RaidArchive
local SRData = ZugLoot.SRData
local Resolver = ZugLoot.Resolver
local Util = ZugLoot.Util

-- 1. Idle Timer.Update Zero-Allocation Invariant
Timer.CancelAll()
collectgarbage("collect")
local m0 = collectgarbage("count")

-- Simulate 1,000 frames (approx 16 seconds at 60 FPS) with empty timer queue
for i = 1, 1000 do
  Timer.Update(0.016)
end

local m1 = collectgarbage("count")
eq(m1 - m0, 0, "idle Timer.Update produces exactly 0 bytes of memory churn over 1000 frames")

-- 2. Timer with running callbacks: verify scratch buffer reuse
local fired = 0
Timer.After(1.0, function() fired = fired + 1 end)
Timer.After(2.0, function() fired = fired + 1 end)

for i = 1, 60 do
  Timer.Update(0.02) -- 1.2s advanced
end
eq(fired, 1, "first timer fired at 1.2s")

for i = 1, 60 do
  Timer.Update(0.02) -- 2.4s advanced
end
eq(fired, 2, "second timer fired at 2.4s")
eq(Timer.Pending(), 0, "no timers pending")

-- 3. SavedVariables Ring-Buffer Bounds Verification
ZugLoot.DB = { drops = {}, sheet = SRData.NewSheet(), raidArchive = {} }

-- A. DropLog bound (cap 500)
for i = 1, 650 do
  DropLog.Add(17000 + (i % 20), "item:17001", "raid", "award", "Player" .. (i % 40))
end
eq(#ZugLoot.DB.drops, ZugLoot.Limits.DROP_LOG_MAX, "DropLog strictly capped at DROP_LOG_MAX (500)")
eq(ZugLoot.DB.drops[#ZugLoot.DB.drops].winner, "Player" .. (650 % 40), "most recent drop is at the end of the ring buffer")

-- B. RaidArchive bound (cap 20)
for i = 1, 35 do
  local s = SRData.NewSheet()
  s.meta = { raidID = "Raid-" .. i, importedAt = i * 100 }
  ZugLoot.DB.sheet = s
  RaidArchive.ArchiveActive(ZugLoot.DB, i * 100)
end
eq(#ZugLoot.DB.raidArchive, RaidArchive.MAX_KEPT, "RaidArchive strictly capped at MAX_KEPT (20)")
eq(ZugLoot.DB.raidArchive[1].raidID, "Raid-35", "most recent raid archived at head")

-- C. Rolls per item bound (cap 25)
local s = SRData.NewSheet()
for i = 1, 40 do
  SRData.RecordRolls(s, 17063, {
    t = i,
    mode = "SR",
    rolls = { { name = "Roller" .. i, roll = i, rollType = "SR" } },
    winners = { { name = "Roller" .. i, rollType = "SR", effective = i } }
  })
end
eq(#s.rolls[17063], SRData.ROLLS_PER_ITEM_MAX, "rolls per item capped at ROLLS_PER_ITEM_MAX (25)")

-- 4. Steady-State Stress: 500 simulated loot/roll resolution cycles
-- Warm-up: fill ring buffers to steady-state capacity
for cycle = 1, 500 do
  local itemID = 17000 + (cycle % 10)
  local chatRolls = {
    { name = "Tank", roll = 85, type = "SR" },
    { name = "Healer", roll = 92, type = "MS" },
    { name = "DPS", roll = 45, type = "OS" },
  }
  local entries = Resolver.BuildEntries(s, itemID, chatRolls)
  local res = Resolver.Resolve(entries)
  SRData.RecordRolls(s, itemID, Resolver.ToHistoryEntry(res))
  DropLog.Add(itemID, "item:" .. itemID, "boss", "award", res.winner and res.winner.name)
end

collectgarbage("collect")
local baselineHeap = collectgarbage("count")

-- Steady-state execution: 500 additional cycles with ring buffers full
for cycle = 1, 500 do
  local itemID = 17000 + (cycle % 10)
  local chatRolls = {
    { name = "Tank", roll = 85, type = "SR" },
    { name = "Healer", roll = 92, type = "MS" },
    { name = "DPS", roll = 45, type = "OS" },
  }
  local entries = Resolver.BuildEntries(s, itemID, chatRolls)
  local res = Resolver.Resolve(entries)
  SRData.RecordRolls(s, itemID, Resolver.ToHistoryEntry(res))
  DropLog.Add(itemID, "item:" .. itemID, "boss", "award", res.winner and res.winner.name)
end

collectgarbage("collect")
local postHeap = collectgarbage("count")
local heapGrowth = postHeap - baselineHeap

-- Steady-state growth must be tightly bounded (< 10 KB churn due to table eviction balance)
ok(heapGrowth < 10, "steady-state heap growth over 500 loot cycles is tightly bounded (< 10 KB, actual: " .. string.format("%.1f", heapGrowth) .. " KB)")

if T.fail == 0 then
  print("memory churn and savedvariables bounds passed")
else
  for _, e in ipairs(T.errors) do print(e) end
  os.exit(1)
end

return T
