-- tests/test_sim.lua
-- Sim writes into the loaded sheet: requires sheet, uses sheet players only,
-- records roll history + won marks + drop log. Pure modules + Sim with
-- stubbed WoW/print globals.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else T.pass = T.pass + 1 end
end
local function ok(v, msg)
  if not v then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else T.pass = T.pass + 1 end
end

ZugLoot = {}
dofile("Util.lua")
dofile("Constants.lua")
dofile("SRData.lua")
dofile("Resolver.lua")
dofile("ItemCards.lua")

ZugLoot.Caps = ZugLoot.Caps or { SR = 100, MS = 100, OS = 99, TMOG = 98 }
ZugLoot.Util = ZugLoot.Util or dofile("Util.lua")
local printed = {}
ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
ZugLoot.BossData = { TestBoss = { 1001, 1002 } }
local dropAdds = {}
ZugLoot.DropLog = { Add = function(itemID, link, src, outcome, winner)
  table.insert(dropAdds, { itemID = itemID, winner = winner }) end }
ZugLoot.MainWindow = nil
ZugLoot.SRView = nil
time = time or os.time

dofile("Sim.lua")
local Sim = ZugLoot.Sim
local SRData = ZugLoot.SRData

local function makeSheet()
  local s = SRData.NewSheet()
  s.items[1001] = { quality = 4, rollers = {
    { name = "Aaa", rolls = 1, sr_plus = 10 },
    { name = "Bbb", rolls = 2, sr_plus = nil },
  } }
  s.items[1002] = { quality = 4, rollers = {
    { name = "Aaa", rolls = 1, sr_plus = nil },
    { name = "Ccc", rolls = 1, sr_plus = 50 },
  } }
  return s
end

-- deterministic rng: returns sequence lo..hi cycling; pass explicit fns instead.
local function rigged(values)
  local i = 0
  return function(lo, hi)
    i = i + 1
    return values[((i - 1) % #values) + 1]
  end
end

-- 1. No sheet -> refuses, no crash, tells user to import.
ZugLoot.DB = {}
printed = {}
Sim.SimItem("1001")
ok(#printed == 1 and string.find(printed[1], "requires a loaded sheet"), "sim without sheet refuses")
Sim.SimBoss("TestBoss")
ok(string.find(printed[#printed], "requires a loaded sheet"), "simboss without sheet refuses")

-- 2. SimItem on sheet item: only sheet players roll (no Filler/Missroller),
-- history written, winner won-marked, drop logged.
ZugLoot.DB = { sheet = makeSheet() }
printed, dropAdds = {}, {}
-- rig: Aaa rolls 90, Bbb rolls 80 -> Aaa wins with +10 = 100.
local realRandom = math.random
math.random = rigged({ 90, 80 })
local res = Sim.SimItem("1001")
math.random = realRandom
ok(res ~= nil, "sim returns result")
eq(res.winners[1].name, "Aaa", "sim winner from sheet players")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 1, "history recorded")
local hist = SRData.GetRolls(ZugLoot.DB.sheet, 1001)[1]
eq(hist.mode, "SIM", "history mode tagged SIM")
eq(hist.winners[1], "Aaa", "history winners")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "winner won-marked")
eq(#dropAdds, 1, "drop logged")
eq(dropAdds[1].winner, "Aaa", "drop winner")

-- every recorded entry is a sheet player (no fake names)
local names = {}
for i = 1, #hist.entries do names[hist.entries[i].name] = true end
ok(names["Aaa"] and names["Bbb"] and names["Filler1"] == nil and names["Missroller1"] == nil,
  "only sheet players rolled")

-- 3. Open item (not on sheet): ALL sheet players roll (Aaa,Bbb,Ccc).
ZugLoot.DB = { sheet = makeSheet() }
printed = {}
math.random = rigged({ 10, 20, 30 })
local res3 = Sim.SimItem("9999")
math.random = realRandom
eq(#res3.entries, 3, "open sim rolls all sheet players")
eq(res3.winners[1].name, "Ccc", "open sim highest base wins")
eq(SRData.GetRolls(ZugLoot.DB.sheet, 9999)[1].mode, "SIM-OPEN", "open mode tagged")

-- 4. SimBoss chains one-win: Aaa wins 1001, can't win 1002 -> Ccc takes it.
ZugLoot.DB = { sheet = makeSheet() }
printed, dropAdds = {}, {}
-- 1001: Aaa 90(+10=100) beats Bbb 80 -> Aaa wins, marked won.
-- 1002: Aaa 99(excluded), Ccc 50(+50=100) -> Ccc wins.
math.random = rigged({ 90, 80, 99, 50 })
Sim.SimBoss("TestBoss")
math.random = realRandom
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "boss sim: 1001 won by Aaa")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1002, "Ccc"), "boss sim: 1002 won by Ccc (Aaa excluded)")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 1, "boss sim history 1001")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1002), 1, "boss sim history 1002")
eq(#dropAdds, 2, "boss sim logs both awards")
-- Aaa rolled 99 on 1002 while already won on 1001... note 1002 is a different
-- item so Aaa is NOT excluded there. Re-check with same-item re-roll:
-- Aaa's excluded re-roll on 1001 shows in print output with the tag.
ZugLoot.DB = { sheet = makeSheet() }
printed = {}
SRData.MarkWon(ZugLoot.DB.sheet, 1001, "Aaa")
math.random = rigged({ 99, 10 })
Sim.SimItem("1001")
math.random = realRandom
local exclPrinted = false
for i = 1, #printed do
  if string.find(printed[i], "Aaa") and string.find(printed[i], "already won") then exclPrinted = true end
end
ok(exclPrinted, "sim print shows won re-roll with tag")
local h1001 = SRData.GetRolls(ZugLoot.DB.sheet, 1001)[1]
eq(#h1001.excluded, 1, "sim history records excluded")
eq(h1001.excluded[1].name, "Aaa", "sim history excluded name")

-- 5. Tie in sim: recorded, no won mark (needs re-roll like live).
-- Aaa 50(+10=60) vs Bbb 60 -> tie at 60.
ZugLoot.DB = { sheet = makeSheet() }
printed, dropAdds = {}, {}
local tieRes = Sim.RunSimSession(ZugLoot.DB.sheet, 1001, "SIM",
  { { name = "Aaa", roll = 50, type = "SR" }, { name = "Bbb", roll = 60, type = "SR" } }, "1001")
eq(#tieRes.tied, 2, "tie detected")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 1, "tie session still recorded")
ok(not SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "no won mark on tie")
eq(#dropAdds, 0, "no award logged on tie")

-- 6. ToHistoryEntry shape shared with live: winners/entries/missrolls/t sorted.
local r = ZugLoot.Resolver.ResolveItem(makeSheet(), 1001,
  { { name = "Aaa", roll = 90, type = "SR" }, { name = "Bbb", roll = 80, type = "SR" } },
  { cap = 100, requireSR = true })
local h = ZugLoot.Resolver.ToHistoryEntry(r, "SIM", 1234)
eq(h.t, 1234, "history time")
eq(h.mode, "SIM", "history mode")
eq(h.winners[1], "Aaa", "history winner")
eq(h.entries[1].effective, 100, "history sorted desc")
eq(h.missrolls, 0, "history missroll count")

-- 7. AllPlayerNames: unique + sorted across items.
local an = SRData.AllPlayerNames(makeSheet())
eq(#an, 3, "three unique players")
eq(an[1], "Aaa", "sorted")
eq(an[3], "Ccc", "sorted")

-- 8. Unknown boss lists available.
ZugLoot.DB = { sheet = makeSheet() }
printed = {}
Sim.SimBoss("Nope")
ok(string.find(printed[#printed], "TestBoss"), "unknown boss hint")

return T
