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
dofile("ClassColors.lua")
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
    local v = values[((i - 1) % #values) + 1]
    -- clamp like a real rng (contract: honor [lo,hi]) so the simboss
    -- static-drop shuffle indexes stay valid.
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
  end
end

local realRandom = math.random

-- Fresh harness state per section.
dofile("LootWindow.lua")

local function resetHarness(rollTime)
  ZugLoot.Timer.CancelAll()
  Sim.pending = {}
  Sim.live = nil
  Sim.running = false
  Sim.auto = false
  Sim.lastEntries = {}
  Sim.doneRows = {}
  Sim.pendingAward = nil
  ML.session = nil
  ML.pendingAwardMenu = nil
  ZugLoot.LootWindow.Clear()
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

-- Regression: cancelling the last item with the roll window open must
-- not leave a "rolling" detail behind, and a stale feed timer firing
-- afterwards must be a silent no-op — not "attempt to index nil
-- (Sim.lua:198 sess.itemID)".
resetHarness()
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
math.random = realRandom
ZugLoot.LootWindow.SetItems({ { itemID = 1001, link = "1001" } }, "sim")
ZugLoot.LootWindow.OpenDetail(1001)
ZugLoot.LootWindow.detail.phase = "rolling"
ZugLoot.LootWindow.detail.sessionID = ML.session and ML.session.id
ML.Cancel()
ok(ML.session == nil, "cancelled session nil")
ok(ZugLoot.LootWindow.detail == nil, "orphaned rolling detail closed")
-- A late feed for the dead session: must not error, must not record.
local okFeed, errFeed = pcall(ZugLoot.Timer.Update, 0.5)
ok(okFeed, "stale feed after cancel does not error: " .. tostring(errFeed))
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 0, "stale feed records nothing")
ok(drain(), "drain after stale feed")

-- 1. No sheet -> refuses, no crash, tells user to import.
ZugLoot.DB = {}
printed = {}
Sim.SimItem("1001")
ok(#printed == 1 and string.find(printed[1], "requires a loaded sheet"), "sim without sheet refuses")
Sim.SimBoss("TestBoss")
ok(string.find(printed[#printed], "requires a loaded sheet"), "simboss without sheet refuses")

-- 2. SimItem replays live: session created silent, raider window shown,
-- rolls fed on timers, finish on roll timer, then the ML picks the award
-- from the menu; history + won + drop written.
resetHarness()
math.random = rigged({ 90, 80 }) -- Aaa 90(+10=100) beats Bbb 80
Sim.SimItem("1001")
ok(ML.session ~= nil, "live session created")
eq(ML.session.mode, "SIM", "sim session mode")
ok(ML.session.silent, "sim session silent (no broadcast)")
eq(#shownItems, 1, "raider window shown once")
ok(string.find(shownItems[1], "1001"), "raider window shows the item")
math.random = realRandom
-- Mid-roll: nothing resolved yet, no history.
ZugLoot.Timer.Update(0.5)
ok(ML.session ~= nil, "session still open mid-roll")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 0, "no history before finish")
ok(drain(), "timers drain")
ok(ML.session ~= nil, "session held for ML award decision")
ok(ML.pendingAwardMenu ~= nil, "award menu pending")
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(drain(), "drain award")
ok(ML.session == nil, "session closed after ML award")
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

-- 3-5. Chat routing per grouping: solo prints locally, raid splits
-- RAID/RAID_WARNING, party stays on PARTY. One table-driven run.
for _, g in ipairs({
  { mode = "solo", want = {}, localOnly = true },
  { mode = "raid", want = { RAID = true, RAID_WARNING = true } },
  { mode = "party", want = { PARTY = true } },
}) do
  resetHarness()
  grouping = g.mode
  math.random = rigged({ 90, 80 })
  Sim.SimItem("1001")
  ok(drain(), "drain " .. g.mode)
  ML.AwardChosen({ name = "Aaa", via = "winner" })
  ok(drain(), "drain " .. g.mode .. " award")
  math.random = realRandom
  if g.localOnly then
    eq(#chatSent, 0, "no SendChatMessage while solo")
    local sawStart, sawResult, sawWinner = false, false, false
    for i = 1, #printed do
      if string.find(printed[i], "ZugLoot rolling") then sawStart = true end
      if string.find(printed[i], "ZugLoot result") then sawResult = true end
      if string.find(printed[i], "SR winner: Aaa", 1, true) then sawWinner = true end
    end
    ok(sawStart and sawResult and sawWinner, "solo sees start/result/winner locally")
  else
    local channels = {}
    for i = 1, #chatSent do channels[chatSent[i].channel] = true end
    for ch in pairs(g.want) do ok(channels[ch], g.mode .. " uses " .. ch) end
    for i = 1, #chatSent do
      ok(g.want[chatSent[i].channel], g.mode .. " stays on expected channels")
      -- Group chat carries no color codes: names stay plain in SendChatMessage.
      ok(not string.find(chatSent[i].msg, "|c", 1, true),
        g.mode .. " chat has no color codes: " .. tostring(chatSent[i].msg))
    end
  end
end

-- 6. Open item (not on sheet): ALL sheet players roll, SIM-OPEN mode + stub.
resetHarness()
math.random = rigged({ 10, 20, 30 })
Sim.SimItem("9999")
ok(drain(), "drain open")
ML.AwardChosen({ name = "Ccc", via = "winner" })
ok(drain(), "drain open award")
math.random = realRandom
local res3 = SRData.GetRolls(ZugLoot.DB.sheet, 9999)[1]
eq(#res3.entries, 3, "open sim rolls all sheet players")
eq(res3.winners[1], "Ccc", "open sim highest base wins")
eq(res3.mode, "SIM-OPEN", "open mode tagged")
ok(SRData.IsUnreserved(ZugLoot.DB.sheet, 9999), "sim stubs off-sheet item")
local simCards = ZugLoot.ItemCards.BuildCards(ZugLoot.DB.sheet)
eq(simCards[#simCards].itemID, 9999, "stub card at the bottom")
ok(simCards[#simCards].unsr, "stub card flagged")

-- 7. SimBoss: queue only — the ML initiates each roll from the loot
-- window; one-win chains across drops.
resetHarness()
-- 1001: Aaa 90(+10=100) beats Bbb 80 -> Aaa wins, marked won.
-- 1002: Aaa 99(excluded), Ccc 50(+50=100) -> Ccc wins.
math.random = rigged({ 2, 2, 2, 90, 80, 99, 50 }) -- drop shuffle: identity, no double
Sim.SimBoss("TestBoss")
math.random = realRandom
-- Queued, nothing rolling: ML must initiate.
ok(ML.session == nil, "simboss starts nothing by itself")
eq(#ZugLoot.LootWindow.items, 2, "loot window lists both drops")
eq(ZugLoot.LootWindow.items[1].status, "open", "first drop open")
-- ML rolls the first item: strict ordering while it plays.
Sim.RequestRoll(1001)
ok(ML.session ~= nil, "ML-initiated session live")
ZugLoot.Timer.Update(0.5)
ok(SRData.RollCount(ZugLoot.DB.sheet, 1001) <= 1, "first item in flight")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1002), 0, "second item waits for first")
-- Roll finishes -> award menu is on the ML: session held, auto nothing.
ok(drain(), "drain first item")
ok(ML.session ~= nil, "first session held for ML award decision")
ok(ML.pendingAwardMenu ~= nil, "award menu pending")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 1, "boss sim history 1001")
-- ML awards: winner marked, next item still queued (no auto-play).
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(drain(), "drain after award")
ok(ML.session == nil, "session closed after ML award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "boss sim: 1001 won by Aaa")
eq(#Sim.pending, 1, "second item still queued (ML-driven)")
eq(#shownItems, 1, "roller window shown for played item only")
-- ML rolls the second item; Aaa is excluded by the one-win rule.
Sim.RequestRoll(1002)
ok(drain(), "drain second item")
ML.AwardChosen({ name = "Ccc", via = "winner" })
ok(drain(), "drain after second award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1002, "Ccc"), "boss sim: 1002 won by Ccc (Aaa excluded)")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1002), 1, "boss sim history 1002")
eq(#dropAdds, 2, "boss sim logs both awards")
eq(#shownItems, 2, "roller window shown per played item")

-- 8. Excluded re-roll visible with tag (async path via raid result line).
resetHarness()
SRData.MarkWon(ZugLoot.DB.sheet, 1001, "Aaa")
math.random = rigged({ 99, 10 })
Sim.SimItem("1001")
ok(drain(), "drain excluded")
ML.AwardChosen({ name = "Bbb", via = "winner" })
ok(drain(), "drain excluded award")
math.random = realRandom
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
local tieMenu = ML.pendingAwardMenu and ML.pendingAwardMenu.data
ok(tieMenu and tieMenu.winners and tieMenu.winners[1] ~= nil, "tie resolved to a winner")
ML.AwardChosen({ name = tieMenu.winners[1].name, via = "winner" })
ok(drain(), "drain tie award")
ok(ML.session == nil, "session closed after ML award")
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
printed = {}
Sim.SimBoss("TestBoss")
ok(string.find(printed[#printed], "already running"), "second sim refused while running")
Sim.Stop()
eq(#Sim.pending, 0, "simstop clears queue")
-- Hard stop: the session is dead, timers are dead, windows are closed.
ok(ML.session == nil, "simstop kills the live session")
ok(ML.pendingAwardMenu == nil, "simstop clears the award menu")
eq(ZugLoot.Timer.Pending(), 0, "simstop kills sim timers")
ok(ZugLoot.LootWindow.detail == nil, "simstop closes the detail")
ok(ZugLoot.LootWindow.frame == nil or ZugLoot.LootWindow.frame.hidden ~= false,
  "simstop hides the loot window")
-- A new sim starts clean immediately; the stopped item cannot be awarded.
Sim.SimItem("1001")
ok(ML.session ~= nil, "new sim starts right after stop")
ML.Cancel() -- tidy: requeues per Cancel semantics, then stop everything
Sim.Stop()
ok(ML.session == nil, "stop after cancel stays stopped")
math.random = realRandom

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

-- 15. In-client menu + confirm: with popup API present, ShowAwardMenu
-- routes to the AwardMenuUI frame instead of printing, and AwardChosen
-- fires the pre-formatted confirm (regression: solo sim died in
-- StaticPopup.lua with "bad argument #2" — text must arrive formatted).
resetHarness()
StaticPopupDialogs = {}
StaticPopup_Show = function(name)
  local dlg = StaticPopupDialogs[name]
  assert(dlg, "dialog registered")
  -- what StaticPopup.lua:1603 does with a text that still holds %s:
  if string.find(dlg.text, "%s", 1, true) then
    error("bad argument #2 to 'format' (no value)")
  end
  table.insert(printed, "POPUP: " .. dlg.text)
end
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
local menuShown = nil
ZugLoot.AwardMenuUI = { Show = function(sess, data) menuShown = data end }
ok(drain(), "drain to award menu")
math.random = realRandom
ok(ML.session ~= nil, "session held for ML award decision")
ok(menuShown ~= nil, "in-client menu frame shown (not printed)")
eq(menuShown.winners[1].name, "Aaa", "menu top winner")
-- ML picks the winner row: confirm popup fires pre-formatted.
printed = {}
ML.AwardChosen({ name = "Aaa", via = "winner" })
local sawPopup = false
for i = 1, #printed do
  if string.find(printed[i], "POPUP: Award", 1, true) then sawPopup = true end
end
ok(sawPopup, "award confirm shown with item + winner filled in")
local confirmText = StaticPopupDialogs["ZUGLOOT_AWARD"].text
ok(not string.find(confirmText, "item:1001", 1, true),
  "confirm names the item, got: " .. tostring(confirmText))
-- ML clicks Award in the popup: award lands, session closes.
StaticPopupDialogs["ZUGLOOT_AWARD"].OnAccept()
ok(drain(), "drain after confirm")
ok(ML.session == nil, "session closed after award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "winner marked after confirm")
ZugLoot.AwardMenuUI = nil
StaticPopupDialogs = nil
StaticPopup_Show = nil

-- 16. Fresh loot session: a second simboss starts clean — no done rows,
-- queue, detail, menu, raider rolls or trailing timers from the first run.
-- (Ragnaros regression: the second run showed stale done/rolling rows.)
resetHarness()
math.random = rigged({ 2, 2, 2, 90, 80, 50, 50 }) -- identity shuffle, no double
Sim.SimBoss("TestBoss")
Sim.RequestRoll(1001)
ok(drain(), "drain fresh-run item 1")
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(drain(), "drain fresh-run award")
math.random = realRandom
eq(#Sim.pending, 1, "first run leaves one item queued")
ok(Sim.doneRows[1001] ~= nil, "first run records a done row")
-- Leftover detail + raider rolls + a stray timer, as a live client has.
ZugLoot.LootWindow.OpenDetail(1001)
ZugLoot.RaiderLootUI = ZugLoot.RaiderLootUI or {}
ZugLoot.RaiderLootUI.rolls = { { player = "Aaa" } }
local hideCalls2 = 0
local origHide = ZugLoot.RaiderLootUI.Hide
ZugLoot.RaiderLootUI.Hide = function() hideCalls2 = hideCalls2 + 1 end
ZugLoot.Timer.After(99, function() end)
ok(ZugLoot.Timer.Pending() >= 1, "stray timer present")
-- Sheet history/won marks persist (raid-night state); session state resets.
local histBefore = SRData.RollCount(ZugLoot.DB.sheet, 1001)
ok(histBefore >= 1, "history recorded by first run")
math.random = rigged({ 2, 2, 2, 1, 1, 1, 1 }) -- identity shuffle, no double
Sim.SimBoss("TestBoss")
math.random = realRandom
eq(Sim.doneRows[1001], nil, "done rows forgotten")
eq(#Sim.pending, 2, "queue rebuilt fresh (no leftovers)")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), histBefore, "history kept")
ok(ML.session == nil, "no live session carried over")
ok(ML.pendingAwardMenu == nil, "no pending menu carried over")
ok(ZugLoot.LootWindow.detail == nil, "open detail closed")
ok(ZugLoot.Timer.Pending() == 0, "trailing timers cancelled")
ok(hideCalls2 >= 1, "raider window hidden (rolls cleared)")
eq(#ZugLoot.LootWindow.items, 2, "loot window lists only the new drops")
ok(not ZugLoot.LootWindow.Find(1001) or ZugLoot.LootWindow.Find(1001).status == "open",
  "rebuilt row starts open, not done")
ZugLoot.RaiderLootUI.Hide = origHide

-- 17. No item may vanish: the row stays (rolling) while the roll runs and
-- after a no-winner finish; only the ML's award (or direct award) marks
-- it done. Covers: zero-roll sessions (all excluded),roller-less on-sheet
-- items, and stub items created by earlier runs.
resetHarness()
-- Everyone has already won 1001 -> all SR rolls excluded -> no winner.
SRData.MarkWon(ZugLoot.DB.sheet, 1001, "Aaa")
SRData.MarkWon(ZugLoot.DB.sheet, 1001, "Bbb")
math.random = rigged({ 90, 80 })
Sim.SimItem("1001")
ok(ML.session ~= nil, "no-winner session still runs")
eq(Sim.live and Sim.live.itemID, 1001, "item tracked live while rolling")
ok(ZugLoot.LootWindow.Find(1001) ~= nil, "row present at roll start")
eq(ZugLoot.LootWindow.Find(1001).status, "rolling", "row rolling, not removed")
ok(drain(), "drain no-winner item")
math.random = realRandom
-- Nothing auto-closed or auto-skipped: the ML still owns the decision.
ok(ML.session ~= nil, "session parked on the award menu (no auto-close)")
ok(ML.pendingAwardMenu ~= nil, "award menu pending even with no winners")
ok(ML.pendingAwardMenu.data.none, "menu flagged none")
ok(Sim.live ~= nil and Sim.live.itemID == 1001, "item still live after the roll")
ok(ZugLoot.LootWindow.Find(1001) ~= nil, "row still listed after the roll")
eq(ZugLoot.LootWindow.Find(1001).status, "rolling", "row still rolling until awarded")
-- ML hands it to someone else: only now does it go done.
ML.AwardChosen({ name = "Stranger", via = "menu" })
ok(drain(), "drain no-winner award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Stranger"), "ML pick awarded")
ok(Sim.live == nil, "item no longer live after award")
local doneRow = ZugLoot.LootWindow.Find(1001)
ok(doneRow ~= nil, "awarded row still listed")
eq(doneRow and doneRow.status, "done", "awarded row marked done")

-- 18. Roller-less on-sheet items fall back to an open roll of the sheet
-- (instead of finishing with zero rolls and no winner).
resetHarness()
ZugLoot.DB.sheet.items[1001].rollers = {}
math.random = rigged({ 2, 2, 2, 42, 43, 44, 1, 1 }) -- identity shuffle + 3 open rolls
Sim.SimBoss("TestBoss")
Sim.RequestRoll(1001)
ok(drain(), "drain roller-less item")
math.random = realRandom
ok(SRData.RollCount(ZugLoot.DB.sheet, 1001) >= 1, "roller-less item still rolled")
local hr = SRData.GetRolls(ZugLoot.DB.sheet, 1001)[1]
ok(#hr.entries > 0, "fallback produced real rolls")
ok(ZugLoot.LootWindow.Find(1001) ~= nil, "fallback item still listed")
ML.AwardChosen({ name = hr.winners[1], via = "winner" })
ok(drain(), "drain fallback award")
ok(Sim.live == nil, "fallback item cleared on award")
eq(ZugLoot.LootWindow.Find(1001).status, "done", "fallback item done on award")

return T
