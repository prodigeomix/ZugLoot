-- tests/test_sim.lua
-- Sim is ONLY a way to test master looting: it opens the SAME roll
-- window through the SAME MasterLootUI roll, with fake rolls landing
-- instantly (no timers, no scheduling). One roll at a time; the window
-- owns everything; closing it ends the roll.
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
dofile("ClassColors.lua")
dofile("SRData.lua")
dofile("Resolver.lua")
dofile("ItemCards.lua")
dofile("Timer.lua")

ZugLoot.Caps = ZugLoot.Caps or { SR = 100, MS = 100, OS = 99, TMOG = 98 }
local printed = {}
ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
AtlasCFM = { InstanceData = { TestRaid = { Name = "Test Raid", Acronym = "TR", MaxPlayers = 40,
  Bosses = { { id = "TestBoss", name = "Test Boss", items = {
      { id = 1001, dropRate = 20 }, { id = 1002, dropRate = 8 },
      { id = 1003, dropRate = 0 } } },
    { id = "SecondBoss", name = "Second Boss", items = { { id = 1005, dropRate = 100 } } },
    { id = "TRTrash", name = "Trash Mobs-Test Raid", defaults = { dropRate = 0.3 },
      items = { { id = 1004, dropRate = 100 } } } } } } }
dofile("AtlasLoot.lua")
ZugLoot.DropLog = { Add = function() end }
ZugLoot.MainWindow = nil
ZugLoot.SRView = nil
time = time or os.time

SendChatMessage = function() end
UnitName = function() return "SoloPlayer" end
GetNumRaidMembers = function() return 0 end
GetRaidRosterInfo = function() return nil end

local grouping = "solo"
ZugLoot.SRSecurity = {
  IsInRaid = function() return grouping == "raid" end,
  IsInParty = function() return grouping == "party" end,
  IsInGroup = function() return grouping ~= "solo" end,
  IsSolo = function() return grouping == "solo" end,
}

local shownItems, hideCalls = {}, 0
ZugLoot.RaiderLootUI = {
  ShowItem = function(link) table.insert(shownItems, link) end,
  OnRoll = function() end,
  Hide = function() hideCalls = hideCalls + 1 end,
}

dofile("RollList.lua")
dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")
dofile("Sim.lua")
local Sim = ZugLoot.Sim
local SRData = ZugLoot.SRData
local ML = ZugLoot.MasterLootUI
local LW = ZugLoot.LootWindow
ML.lootOpen = true

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

local function rigged(values)
  local i = 0
  return function(lo, hi)
    i = i + 1
    local v = values[((i - 1) % #values) + 1]
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
  end
end
local realRandom = math.random

local function resetHarness(rollTime)
  ZugLoot.Timer.CancelAll()
  Sim.pending = {}
  Sim.running = false
  Sim.raid = nil
  Sim.FakeCount = 2
  ML.roll = nil
  LW.Clear()
  printed, shownItems = {}, {}
  hideCalls = 0
  grouping = "solo"
  ZugLoot.DB = { sheet = makeSheet(), rollTime = rollTime or 30 }
end

-- 1. SimItem: fakes land INSTANTLY — no timer drain, no scheduling.
-- Window opens rolling with the fakes listed; a real /roll joins them.
resetHarness()
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
math.random = realRandom
ok(ML.roll ~= nil, "sim opens the one roll")
eq(ML.roll.itemID, 1001, "roll targets the item")
eq(#ML.roll.rolls, 2, "both fakes landed instantly")
ok(LW.detail ~= nil and LW.detail.phase == "rolling", "window open and rolling")
eq(#LW.detail.rolls, 2, "window lists both fakes")
ok(ML.roll.rollTimer ~= nil, "roll clock armed (the only timer)")
-- A real roll joins the same list while open.
ML.IntakeChatRoll("Me rolls 55 (1-100)")
eq(#ML.roll.rolls, 3, "real roll joins the open roll")
eq(#LW.detail.rolls, 3, "window shows the real roll too")
-- Second roll refused while open.
Sim.SimItem("1002")
ok(ML.roll.itemID == 1001, "second sim refused while rolling")
-- Finish: award view on the same window, roll cleared.
eq(LW.doAction(1001, "finish"), "finished", "finish resolves")
ok(ML.roll == nil, "finished roll cleared")
eq(LW.detail.phase, "award", "same window shows the award")
ok(LW.detail.menu ~= nil, "award menu built")
eq(LW.detail.menu.winners[1].name, "Aaa", "SR+ wins (90+10)")
-- Award: won mark + row gone + run ends.
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "award won-marks")
ok(LW.Find(1001) == nil, "awarded row gone")
ok(LW.detail == nil, "window closed after award")
ok(Sim.running == false, "run ended when drained")

-- 1c. Multi-SR allowance: Bbb SR'd 1001 twice (rolls = 2), so a second
-- roll lands; a third is past the allowance and ignored. Aaa (rolls = 1)
-- still gets one roll only.
resetHarness()
ML.roll = { itemID = 1001, mode = "SR", rolls = {} }
ML.IntakeChatRoll("Bbb rolls 80 (1-100)")
ML.IntakeChatRoll("Bbb rolls 90 (1-100)")
ML.IntakeChatRoll("Bbb rolls 95 (1-100)") -- past allowance: ignored
ML.IntakeChatRoll("Aaa rolls 70 (1-100)")
ML.IntakeChatRoll("Aaa rolls 71 (1-100)") -- past allowance: ignored
eq(#ML.roll.rolls, 3, "x2 holder rolls twice, single holder once")
local bbbBest, bbbN = 0, 0
for i = 1, #ML.roll.rolls do
  if ML.roll.rolls[i].name == "Bbb" then
    bbbN = bbbN + 1
    if ML.roll.rolls[i].roll > bbbBest then bbbBest = ML.roll.rolls[i].roll end
  end
end
eq(bbbN, 2, "two Bbb rolls kept")
eq(bbbBest, 90, "third Bbb roll ignored")
eq(ML.RollAllowance(1001, "Bbb"), 2, "allowance reads the sheet count")
eq(ML.RollAllowance(1001, "Aaa"), 1, "single SR rolls once")
eq(ML.RollAllowance(1001, "Stranger"), 1, "non-holder rolls once")
local resAllow = ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001, ML.roll.rolls, { cap = 100 })
eq(resAllow.winners[1].name, "Bbb", "best of the allowance wins (90 over 70+10)")
ML.roll = nil
-- 1b. Continue rolling on a finished sim round: landed fakes kept, a
-- manual /roll joins (no auto re-fakes: the queue entry was consumed).
resetHarness()
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
math.random = realRandom
eq(LW.doAction(1001, "finish"), "finished", "sim finish resolves")
eq(LW.doAction(1001, "continue"), "rolling", "continue reopens the sim round")
ok(ML.roll ~= nil and ML.roll.mode == "SIM", "continued roll stays SIM")
eq(#ML.roll.rolls, 2, "sim fakes carried over")
ML.IntakeChatRoll("Me rolls 55 (1-100)")
eq(#ML.roll.rolls, 3, "manual roll joins the continued round")
eq(LW.doAction(1001, "finish"), "finished", "continued round re-finishes")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa") == false, "no award yet from continue")
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "continued round awards")

-- 2. Closing the window ends the roll: intake dead, no late finish.
resetHarness()
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
math.random = realRandom
eq(LW.doAction(1001, "close"), "closed", "close rolling window")
ok(ML.roll == nil, "close ends the roll")
ML.IntakeChatRoll("Late rolls 99 (1-100)")
ok(ML.roll == nil, "late roll lands nowhere")
ok(ZugLoot.Timer.Pending() == 0, "close disarms the clock")

-- 3. ... award ends the roll early and awards.
resetHarness()
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
math.random = realRandom
eq(LW.doAction(1001, "award-name", "Bbb"), "awarded Bbb", "... award lands")
ok(ML.roll == nil, "... award ends the roll")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Bbb"), "... award won-marks")
ok(LW.Find(1001) == nil, "awarded row gone")

-- 4. Timeout auto-finishes; the dead handle never fires twice.
resetHarness(2)
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
math.random = realRandom
ok(ML.roll ~= nil, "roll open")
local guard = 0
while ZugLoot.Timer.Pending() > 0 and guard < 100 do
  ZugLoot.Timer.Update(0.5)
  guard = guard + 1
end
ok(guard < 100, "clock drained")
ok(ML.roll == nil, "timeout ends the roll")
eq(LW.detail.phase, "award", "timeout flips to award view")
eq(LW.detail.menu.winners[1].name, "Aaa", "timeout awards the winner")
ok(ZugLoot.Timer.Pending() == 0, "no handles left behind")
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "timeout roll awards")

-- 5. SimBoss queues boss drops; each rolls and awards in turn.
resetHarness()
math.random = rigged({ 2, 90, 80, 2, 99, 50 })
Sim.SimBoss("Test Boss")
math.random = realRandom
eq(#Sim.pending, 2, "boss queues two drops")
eq(Sim.pending[1].itemID, 1001, "first drop queued")
ok(LW.Find(1001) ~= nil and LW.Find(1002) ~= nil, "both rows listed")
ok(Sim.RequestRoll(1001), "first drop rolls")
eq(#ML.roll.rolls, 2, "first drop fakes landed")
eq(LW.doAction(1001, "finish"), "finished", "first drop finishes")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "first drop awarded")
ok(Sim.RequestRoll(1002), "second drop rolls after award")
eq(LW.doAction(1002, "finish"), "finished", "second drop finishes")
ML.AwardChosen({ name = "Ccc", via = "winner" }, 1002)
ok(SRData.HasWon(ZugLoot.DB.sheet, 1002, "Ccc"), "second drop awarded")
ok(Sim.running == false, "run ends when drained")

-- 6. Tie stays open for a re-roll round; fresh roll decides.
resetHarness()
math.random = rigged({ 50, 50 })
Sim.SimItem("1001")
math.random = realRandom
-- Force the tie: both holders rolled the same SR number.
ML.roll.rolls = {
  { name = "Aaa", roll = 50, type = "SR", min = 1, max = 100, effective = 60 },
  { name = "Bbb", roll = 60, type = "SR", min = 1, max = 100, effective = 60 },
}
eq(ML.FinishRoll(), "tie", "tie stays open")
-- Tie re-roll: fresh roll on the same window, new numbers decide.
ok(Sim.RequestRoll(1001) == false, "tie roll still open: no double roll")
ML.EndRoll()
LW.detail.phase = "rolling"
LW.detail.rolls = {}
LW.detail.menu = nil
math.random = rigged({ 90, 80 })
ok(Sim.RequestRoll(1001) == false, "queue consumed: manual re-roll only")
math.random = realRandom
ML.BeginRoll(1001, "item:1001", "SIM", true)
ML.AddRoll("Aaa", 90, 1, 100)
ML.AddRoll("Bbb", 80, 1, 100)
eq(ML.FinishRoll(), "finished", "re-roll finishes")
eq(LW.detail.menu.winners[1].name, "Aaa", "re-roll winner")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "re-roll awards")

-- 7. SimStop: queue dropped, open roll ended, windows closed.
resetHarness()
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
math.random = realRandom
ok(ML.roll ~= nil, "roll open before stop")
Sim.Stop()
ok(ML.roll == nil, "stop ends the open roll")
ok(#Sim.pending == 0, "stop drops the queue")
ok(LW.detail == nil, "stop closes the window")
ok(ZugLoot.Timer.Pending() == 0, "stop disarms the clock")

-- 8. History: finished rolls record like live ones.
resetHarness()
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
math.random = realRandom
eq(LW.doAction(1001, "finish"), "finished", "finish for history")
local hist = SRData.GetRolls(ZugLoot.DB.sheet, 1001)
ok(#hist == 1, "one history entry")
eq(hist[1].winners[1], "Aaa", "history names the winner")
eq(hist[1].mode, "SIM", "history mode tagged")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)

-- 9. Ignored-by-mistake sim item stays operable: ignoring drops the
-- queue entry but the row stays listed; Roll re-queues fresh fakes and
-- rolls (no "not in the test queue" dead end), clearing the mark.
resetHarness()
math.random = rigged({ 2, 90, 80, 2, 99, 50 })
Sim.SimBoss("Test Boss")
math.random = realRandom
eq(#Sim.pending, 2, "boss queues two drops")
eq(LW.doAction(1001, "ignore"), "ignored 1001", "ignore first drop by mistake")
ok(LW.Find(1001) ~= nil and LW.Find(1001).ignored, "ignored sim row stays listed")
eq(#Sim.pending, 1, "ignore dropped its queue entry")
-- Roll it anyway: re-queued, fakes land, mark clears.
math.random = rigged({ 90, 80 })
eq(LW.doAction(1001, "roll"), "rolling", "ignored sim row re-rollable")
math.random = realRandom
ok(ML.roll ~= nil and ML.roll.itemID == 1001, "re-roll runs on the item")
eq(#ML.roll.rolls, 2, "rebuilt fakes landed")
ok(not LW.Find(1001).ignored, "re-roll clears the ignored mark")
eq(#Sim.pending, 1, "re-roll consumed its entry (no double queue)")
eq(LW.doAction(1001, "finish"), "finished", "re-roll finishes")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "re-rolled item awards")
-- The other drop was never touched: still queued, still rolls.
ok(Sim.RequestRoll(1002), "untouched drop still rolls")
eq(LW.doAction(1002, "finish"), "finished", "untouched drop finishes")
ML.AwardChosen({ name = "Ccc", via = "winner" }, 1002)
ok(SRData.HasWon(ZugLoot.DB.sheet, 1002, "Ccc"), "untouched drop awards")
ok(Sim.running == false, "run ends when drained")
-- Gone rows still refuse cleanly (row left the list on award).
printed = {}
ok(not Sim.RequestRoll(1001), "awarded-away row refuses")
ok(string.find(printed[#printed] or "", "not in the test queue", 1, true) ~= nil,
  "gone row keeps the honest error")

-- 10. Ignored sim row survives OTHER items' awards (live parity):
-- ignore A, roll + award B, A stays listed and ignored — then A
-- still rolls on demand.
resetHarness()
math.random = rigged({ 2, 90, 80, 2, 99, 50 })
Sim.SimBoss("Test Boss")
math.random = realRandom
eq(LW.doAction(1001, "ignore"), "ignored 1001", "ignore first drop")
ok(Sim.RequestRoll(1002), "second drop rolls")
eq(LW.doAction(1002, "finish"), "finished", "second drop finishes")
ML.AwardChosen({ name = "Ccc", via = "winner" }, 1002)
ok(SRData.HasWon(ZugLoot.DB.sheet, 1002, "Ccc"), "second drop awarded")
-- The ignored row survived the award-time re-sync, flag intact.
local kept = LW.Find(1001)
ok(kept ~= nil, "ignored row survives the other award")
ok(kept and kept.ignored, "ignored flag survives the other award")
-- ...and still rolls on demand afterwards.
math.random = rigged({ 90, 80 })
eq(LW.doAction(1001, "roll"), "rolling", "surviving row re-rolls")
math.random = realRandom
eq(#ML.roll.rolls, 2, "survivor fakes landed")
eq(LW.doAction(1001, "finish"), "finished", "survivor finishes")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "survivor awards")
ok(Sim.running == false, "run ends when drained")

-- 11. Lone-holder direct award (no roll): the row leaves the sim
-- window. The queue entry was never consumed (no roll started), so
-- the award-time re-sync must not re-list it from the stale entry —
-- while the untouched drop stays queued and listed.
resetHarness()
ZugLoot.DB.sheet.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
math.random = rigged({ 2, 90, 80, 2, 99, 50 })
Sim.SimBoss("Test Boss")
math.random = realRandom
eq(#Sim.pending, 2, "direct-award setup queues two drops")
LW.OpenDetail(1001)
ok(LW.detail.single, "lone SR holder takes the fast path")
eq(LW.doAction(1001, "award"), "awarded Aaa", "lone holder awarded without rolling")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "direct award won-marks")
ok(LW.Find(1001) == nil, "awarded row leaves the sim window")
eq(#Sim.pending, 1, "direct award consumed its queue entry")
ok(LW.Find(1002) ~= nil, "untouched drop stays listed")
ok(Sim.RequestRoll(1002), "untouched drop still rolls")

return T
