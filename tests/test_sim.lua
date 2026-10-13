-- tests/test_sim.lua
-- Sim replays the live pipeline (MasterLootUI session + timers + routed chat
-- + windows) with precomputed fake rolls. Timer is pumped by hand; chat and
-- windows are stubbed and asserted. RunSimSession stays as the sync core.
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
dofile("Timer.lua")

ZugLoot.Caps = ZugLoot.Caps or { SR = 100, MS = 100, OS = 99, TMOG = 98 }
ZugLoot.Util = ZugLoot.Util or dofile("Util.lua")
local printed = {}
ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
ZugLoot.BossData = { TestBoss = { 1001, 1002 } }
local dropAdds = {}
ZugLoot.DropLog = { Add = function(itemID, link, src, outcome, winner)
  table.insert(dropAdds, { itemID = itemID, src = src, winner = winner }) end }
ZugLoot.MainWindow = nil
ZugLoot.SRView = nil
time = time or os.time

-- Chat capture: { {msg, channel} }.
local chatSent = {}
SendChatMessage = function(msg, channel)
  table.insert(chatSent, { msg = msg, channel = channel })
end

-- Grouping knob: "solo" | "party" | "raid".
local grouping = "solo"
ZugLoot.SRSecurity = {
  IsInRaid = function() return grouping == "raid" end,
  IsInParty = function() return grouping == "party" end,
  IsInGroup = function() return grouping ~= "solo" end,
  IsSolo = function() return grouping == "solo" end,
}

-- Raider window capture.
local shownItems, fedRolls, hideCalls = {}, {}, 0
ZugLoot.RaiderLootUI = {
  ShowItem = function(link) table.insert(shownItems, link) end,
  OnRoll = function() end,
  Hide = function() hideCalls = hideCalls + 1 end,
}

dofile("Comm.lua")
dofile("MasterLootUI.lua")
dofile("Sim.lua")
local Sim = ZugLoot.Sim
local SRData = ZugLoot.SRData
local ML = ZugLoot.MasterLootUI

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

local realRandom = math.random

-- Fresh harness state per section.
local function resetHarness(rollTime)
  ZugLoot.Timer.CancelAll()
  Sim.pending = {}
  Sim.running = false
  ML.session = nil
  printed, dropAdds, chatSent, shownItems, fedRolls = {}, {}, {}, {}, {}
  hideCalls = 0
  grouping = "solo"
  ZugLoot.DB = { sheet = makeSheet(), rollTime = rollTime or 2 }
end

-- Pump timers until quiet (guard against runaway).
local function drain(step)
  local guard = 0
  while ZugLoot.Timer.Pending() > 0 and guard < 500 do
    ZugLoot.Timer.Update(step or 0.5)
    guard = guard + 1
  end
  return guard < 500
end

-- 1. No sheet -> refuses, no crash, tells user to import.
ZugLoot.DB = {}
printed = {}
Sim.SimItem("1001")
ok(#printed == 1 and string.find(printed[1], "requires a loaded sheet"), "sim without sheet refuses")
Sim.SimBoss("TestBoss")
ok(string.find(printed[#printed], "requires a loaded sheet"), "simboss without sheet refuses")

-- 2. SimItem replays live: session created silent, raider window shown,
-- rolls fed on timers, finish on roll timer, history + won + drop written.
resetHarness()
math.random = rigged({ 90, 80 }) -- Aaa 90(+10=100) beats Bbb 80
Sim.SimItem("1001")
math.random = realRandom
ok(ML.session ~= nil, "live session created")
eq(ML.session.mode, "SIM", "sim session mode")
ok(ML.session.silent, "sim session silent (no broadcast)")
eq(#shownItems, 1, "raider window shown once")
ok(string.find(shownItems[1], "1001"), "raider window shows the item")
-- Mid-roll: nothing resolved yet, no history.
ZugLoot.Timer.Update(0.5)
ok(ML.session ~= nil, "session still open mid-roll")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 0, "no history before finish")
ok(drain(), "timers drain")
ok(ML.session == nil, "session closed after finish")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 1, "history recorded")
local hist = SRData.GetRolls(ZugLoot.DB.sheet, 1001)[1]
eq(hist.mode, "SIM", "history mode tagged SIM")
eq(hist.winners[1], "Aaa", "sim winner from sheet players")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "winner won-marked")
eq(#dropAdds, 1, "drop logged")
eq(dropAdds[1].winner, "Aaa", "drop winner")
eq(dropAdds[1].src, "sim", "drop source sim")
-- every recorded entry is a sheet player (no fake names)
local names = {}
for i = 1, #hist.entries do names[hist.entries[i].name] = true end
ok(names["Aaa"] and names["Bbb"] and names["Filler1"] == nil and names["Missroller1"] == nil,
  "only sheet players rolled")

-- 3. Solo routing: chat goes to the local frame (printed), never SendChatMessage.
resetHarness()
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
math.random = realRandom
ok(drain(), "drain solo")
eq(#chatSent, 0, "no SendChatMessage while solo")
local sawStart, sawResult, sawWinner = false, false, false
for i = 1, #printed do
  if string.find(printed[i], "ZugLoot rolling") then sawStart = true end
  if string.find(printed[i], "ZugLoot result") then sawResult = true end
  if string.find(printed[i], "Winner: Aaa") then sawWinner = true end
end
ok(sawStart and sawResult and sawWinner, "solo sees start/result/winner locally")

-- 4. Raid routing: start+result on RAID, winner on RAID_WARNING.
resetHarness()
grouping = "raid"
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
math.random = realRandom
ok(drain(), "drain raid")
local channels = {}
for i = 1, #chatSent do channels[chatSent[i].channel] = true end
ok(channels["RAID"], "raid traffic on RAID")
ok(channels["RAID_WARNING"], "winner on RAID_WARNING")
local startCh, winCh = nil, nil
for i = 1, #chatSent do
  if string.find(chatSent[i].msg, "ZugLoot rolling") then startCh = chatSent[i].channel end
  if string.find(chatSent[i].msg, "Winner:") then winCh = chatSent[i].channel end
end
eq(startCh, "RAID_WARNING", "roll start warns raid")
eq(winCh, "RAID_WARNING", "winner warns raid")

-- 5. Party routing: everything on PARTY (no raid warnings in a party).
resetHarness()
grouping = "party"
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
math.random = realRandom
ok(drain(), "drain party")
ok(#chatSent > 0, "party traffic sent")
for i = 1, #chatSent do eq(chatSent[i].channel, "PARTY", "party-only routing") end

-- 6. Open item (not on sheet): ALL sheet players roll, SIM-OPEN mode + stub.
resetHarness()
math.random = rigged({ 10, 20, 30 })
Sim.SimItem("9999")
math.random = realRandom
ok(drain(), "drain open")
local res3 = SRData.GetRolls(ZugLoot.DB.sheet, 9999)[1]
eq(#res3.entries, 3, "open sim rolls all sheet players")
eq(res3.winners[1], "Ccc", "open sim highest base wins")
eq(res3.mode, "SIM-OPEN", "open mode tagged")
ok(SRData.IsUnreserved(ZugLoot.DB.sheet, 9999), "sim stubs off-sheet item")
local simCards = ZugLoot.ItemCards.BuildCards(ZugLoot.DB.sheet)
eq(simCards[#simCards].itemID, 9999, "stub card at the bottom")
ok(simCards[#simCards].unsr, "stub card flagged")

-- 7. SimBoss: one item at a time, one-win chains across drops.
resetHarness()
-- 1001: Aaa 90(+10=100) beats Bbb 80 -> Aaa wins, marked won.
-- 1002: Aaa 99(excluded), Ccc 50(+50=100) -> Ccc wins.
math.random = rigged({ 90, 80, 99, 50 })
Sim.SimBoss("TestBoss")
math.random = realRandom
-- After a beat only the first item may have history: strict ordering.
ZugLoot.Timer.Update(0.5)
ok(SRData.RollCount(ZugLoot.DB.sheet, 1001) <= 1, "first item in flight")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1002), 0, "second item waits for first")
ok(drain(), "drain boss")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "boss sim: 1001 won by Aaa")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1002, "Ccc"), "boss sim: 1002 won by Ccc (Aaa excluded)")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 1, "boss sim history 1001")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1002), 1, "boss sim history 1002")
eq(#dropAdds, 2, "boss sim logs both awards")
eq(#shownItems, 2, "roller window shown per item")

-- 8. Excluded re-roll visible with tag (async path via raid result line).
resetHarness()
SRData.MarkWon(ZugLoot.DB.sheet, 1001, "Aaa")
math.random = rigged({ 99, 10 })
Sim.SimItem("1001")
math.random = realRandom
ok(drain(), "drain excluded")
local exclPrinted = false
for i = 1, #printed do
  if string.find(printed[i], "Aaa") and string.find(printed[i], "already won") then exclPrinted = true end
end
ok(exclPrinted, "sim result shows won re-roll with tag")
local h1001 = SRData.GetRolls(ZugLoot.DB.sheet, 1001)[1]
eq(#h1001.excluded, 1, "sim history records excluded")
eq(h1001.excluded[1].name, "Aaa", "sim history excluded name")

-- 9. Tie in sim: re-rolled on timers, then resolved (sync core unchanged).
resetHarness()
printed, dropAdds = {}, {}
local tieRes = Sim.RunSimSession(ZugLoot.DB.sheet, 1001, "SIM",
  { { name = "Aaa", roll = 50, type = "SR" }, { name = "Bbb", roll = 60, type = "SR" } }, "1001")
eq(#tieRes.tied, 2, "tie detected")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 1, "tie session still recorded")
ok(not SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "no won mark on tie")
eq(#dropAdds, 0, "no award logged on tie")

-- 10. Async tie: tied players re-roll automatically, session closes.
resetHarness()
-- Feed Aaa 50(+10=60) vs Bbb 60 -> tie; reroll round gives distinct values.
-- (rng stays rigged through the drain so re-rolls are deterministic.)
math.random = rigged({ 50, 60, 70, 71 })
Sim.SimItem("1001")
ok(drain(), "drain tie")
math.random = realRandom
ok(ML.session == nil, "tied session closes after re-rolls")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 2, "tie round + winning round recorded")
eq(#dropAdds, 1, "exactly one award after tie")

-- 11. Busy guards: live session blocks sim; running sim blocks sim; simstop clears.
resetHarness()
ML.session = { id = 1, itemID = 5, itemLink = "x", mode = "SR", rolls = {}, itemCount = 1 }
printed = {}
Sim.SimItem("1001")
ok(string.find(printed[#printed], "already running"), "sim refused during live session")
ML.session = nil
resetHarness()
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
math.random = realRandom
printed = {}
Sim.SimBoss("TestBoss")
ok(string.find(printed[#printed], "already running"), "second sim refused while running")
Sim.Stop()
eq(#Sim.pending, 0, "simstop clears queue")
ok(drain(), "drain after stop")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 1, "current item still finishes")

-- 12. ToHistoryEntry shape shared with live: winners/entries/missrolls/t sorted.
local r = ZugLoot.Resolver.ResolveItem(makeSheet(), 1001,
  { { name = "Aaa", roll = 90, type = "SR" }, { name = "Bbb", roll = 80, type = "SR" } },
  { cap = 100, requireSR = true })
local h = ZugLoot.Resolver.ToHistoryEntry(r, "SIM", 1234)
eq(h.t, 1234, "history time")
eq(h.mode, "SIM", "history mode")
eq(h.winners[1], "Aaa", "history winner")
eq(h.entries[1].effective, 100, "history sorted desc")
eq(h.missrolls, 0, "history missroll count")

-- 13. AllPlayerNames: unique + sorted across items.
local an = SRData.AllPlayerNames(makeSheet())
eq(#an, 3, "three unique players")
eq(an[1], "Aaa", "sorted")
eq(an[3], "Ccc", "sorted")

-- 14. Unknown boss lists available.
ZugLoot.DB = { sheet = makeSheet() }
printed = {}
Sim.SimBoss("Nope")
ok(string.find(printed[#printed], "TestBoss"), "unknown boss hint")

return T
