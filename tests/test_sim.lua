-- tests/test_sim.lua
-- Sim replays the live pipeline (MasterLootUI session + routed chat
-- + windows) with precomputed fake rolls. Feeds + finish run inline;
-- chat and windows are stubbed and asserted. Every test drives the real
-- pipeline (BeginSession/Finish/AwardChosen) — no parallel sync core.
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
  Sim.lives = {}
  Sim.FakeCount = 2 -- pinned headcount: rigged rng maps 1:1 onto rolls
  ML.session = nil
  ML.sessions = {}
  ML.parkedSessions = nil
  ML.pendingAwardMenu = nil
  ML.pendingAwardMenus = nil
  ZugLoot.LootWindow.Clear()
  printed, dropAdds, chatSent, shownItems, fedRolls = {}, {}, {}, {}, {}
  hideCalls = 0
  grouping = "solo"
  ZugLoot.DB = { sheet = makeSheet(), rollTime = rollTime or 2 }
end

-- Quiescence helper: sim feeds + finish run inline now (no timers), so
-- there is never anything to pump — kept as a trivially-true call so the
-- flow reads unchanged ("run to quiescence", now instant).
local function drain(step)
  return true
end

-- Regression: cancelling with the roll window open must not leave a
-- "rolling" detail behind, and a feed for the dead session id must be a
-- silent no-op. (Inline finish parks the session, so Cancel targets the
-- parked award menu's session — same path as cancelling a live roll.)
resetHarness()
math.random = rigged({ 90, 80 }) -- holder SR rolls, no kind draws
Sim.SimItem("1001")
math.random = realRandom
ZugLoot.LootWindow.SetItems({ { itemID = 1001, link = "1001" } }, "sim")
ZugLoot.LootWindow.OpenDetail(1001)
ZugLoot.LootWindow.detail.phase = "rolling"
local parkedSess = ML.SessionAny(1001)
ZugLoot.LootWindow.detail.sessionID = parkedSess and parkedSess.id
ML.Cancel(1001)
ok(ML.session == nil, "cancelled session nil")
ok(ZugLoot.LootWindow.detail == nil, "orphaned rolling detail closed")
-- An echo for the dead session: refused silently — nothing printed,
-- nothing routed — and the cancelled roll's history (written once by
-- the inline finish, before Cancel) is NOT duplicated.
local nHistBefore = SRData.RollCount(ZugLoot.DB.sheet, 1001)
local nPrintedBefore = #printed
local okFeed, errFeed = pcall(function()
  ZugLoot.MasterLootUI.EchoSimRoll(parkedSess, "Aaa", 50, 1, 100)
end)
ok(okFeed, "stale echo after cancel does not error: " .. tostring(errFeed))
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), nHistBefore, "stale echo records nothing new")
eq(#printed, nPrintedBefore, "stale echo prints nothing")
-- A stray chat line with no live session is likewise a no-op (the
-- intake guards on M.session, same as the live event path).
local okStray, errStray = pcall(function()
  ZugLoot.MasterLootUI.IntakeChatRoll("Aaa rolls 50 (1-100)")
end)
ok(okStray, "stray chat line does not error: " .. tostring(errStray))
eq(#printed, nPrintedBefore, "stray chat line prints nothing")
ok(drain(), "drain after stale feed")

-- 0. Chat intake: one parser behind live chat and sim echoes.
-- ParseSystemRoll reads "Name rolls R (min-max)" and rejects chatter.
local pp, pr,plo, phi = ML.ParseSystemRoll("Aaa rolls 90 (1-100)")
eq(pp, "Aaa", "parser reads the roller")
eq(pr, 90, "parser reads the roll")
eq(plo, 1, "parser reads min")
eq(phi, 100, "parser reads max")
ok(ML.ParseSystemRoll("Raid rolling Thunderfury...") == nil, "parser ignores roll calls")
ok(ML.ParseSystemRoll("Aaa wins Thunderfury (raid-roll).") == nil, "parser ignores award lines")
ok(ML.ParseSystemRoll("") == nil, "parser ignores empty lines")
ok(ML.ParseSystemRoll(nil) == nil, "parser ignores nil")
-- IntakeChatRoll routes to the live session (same path as OnEvent).
resetHarness()
ML.BeginSession(1001, "item:1001", "SR", false)
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
eq(#ML.session.rolls, 1, "chat line registers on the session")
eq(ML.session.rolls[1].name, "Aaa", "chat roller named")
eq(ML.session.rolls[1].type, "SR", "holder 1-100 reads SR")
ML.IntakeChatRoll("Aaa rolls 50 (1-100)") -- first-roll-only
 eq(#ML.session.rolls, 1, "duplicate chat roll ignored")
ML.IntakeChatRoll("Raid rolling Thunderfury...") -- not a roll
 eq(#ML.session.rolls, 1, "chatter ignored")
ML.Cancel(1001)
-- EchoSimRoll prints the line AND registers it (one call, both halves).
resetHarness()
local es = ML.BeginSession(1001, "item:1001", "SIM-OPEN", true)
printed = {}
ML.EchoSimRoll(es, "Bbb", 77, 1, 100)
eq(#ML.session.rolls, 1, "echo registers on the session")
eq(ML.session.rolls[1].name, "Bbb", "echo roller named")
eq(ML.session.rolls[1].roll, 77, "echo roll kept")
local sawEchoLine = false
for i = 1, #printed do
  if string.find(printed[i], "Bbb rolls 77 (1-100)", 1, true) then sawEchoLine = true end
end
ok(sawEchoLine, "echo prints the system-roll line locally")
-- Range-blind ranges still derive kind from the range (OS 1-99).
ML.EchoSimRoll(es, "Ossy", 55, 1, 99)
eq(ML.session.rolls[2].type, "OS", "echo 1-99 reads OS")
ML.Cancel(1001)

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
math.random = rigged({ 90, 80 }) -- holder SR rolls, no kind draws -- Aaa 90(+10=100) beats Bbb 80
Sim.SimItem("1001")
-- Inline finish parks the session with the menu pending (no live session
-- left behind to observe — the roll already resolved).
ok(ML.SessionAny(1001) ~= nil, "session parked for ML award decision")
ok(ML.pendingAwardMenu ~= nil, "award menu pending")
eq(#shownItems, 1, "raider window shown once")
ok(string.find(shownItems[1], "1001"), "raider window shows the item")
math.random = realRandom
ok(drain(), "feeds + finish inline")
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(drain(), "drain award")
ok(ML.SessionAny(1001) == nil, "session closed after ML award")
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
  -- Holders roll SR with no kind draws: Aaa 90(+10), Bbb 80.
  math.random = rigged({ 90, 80 })
  Sim.SimItem("1001")
  ok(drain(), "drain " .. g.mode)
  ML.AwardChosen({ name = "Aaa", via = "winner" })
  ok(drain(), "drain " .. g.mode .. " award")
  math.random = realRandom
  if g.localOnly then
    eq(#chatSent, 0, "no SendChatMessage while solo")
    local sawStart, sawResult, sawWinner, sawEcho = false, false, false, false
    for i = 1, #printed do
      -- Pysanka-style lines, printed locally while solo.
      if string.find(printed[i], "1001", 1, true) then sawStart = true end
      if string.find(printed[i], "Aaa: 90 (SR)", 1, true) then sawResult = true end
      -- Sim awards stay local-print (source "sim" never chats).
      if string.find(printed[i], "Awarded 1001 to", 1, true) then sawWinner = true end
      -- Fake rolls echo as system-roll chat lines, ML-local only.
      if string.find(printed[i], "Aaa rolls 90 (1-100)", 1, true) then sawEcho = true end
    end
    ok(sawStart and sawResult and sawWinner, "solo sees start/result/winner locally")
    ok(sawEcho, "solo sees the fake-roll echo locally")
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

-- 6. Open item (not on sheet): small group (pinned to 2 here), SIM-OPEN
-- mode + stub. Aaa MS 10 vs Bbb MS 20 -> Bbb wins.
resetHarness()
math.random = rigged({ 1, 10, 1, 20 }) -- MS kind + roll per roller
Sim.SimItem("9999")
ok(drain(), "drain open")
ML.AwardChosen({ name = "Bbb", via = "winner" })
ok(drain(), "drain open award")
math.random = realRandom
local res3 = SRData.GetRolls(ZugLoot.DB.sheet, 9999)[1]
eq(#res3.entries, 2, "open sim rolls a small group")
eq(res3.winners[1], "Bbb", "open sim highest base wins")
eq(res3.mode, "SIM-OPEN", "open mode tagged")
ok(SRData.IsUnreserved(ZugLoot.DB.sheet, 9999), "sim stubs off-sheet item")
local simCards = ZugLoot.ItemCards.BuildCards(ZugLoot.DB.sheet)
eq(simCards[#simCards].itemID, 9999, "stub card at the bottom")
ok(simCards[#simCards].unsr, "stub card flagged")

-- 7. SimBoss: queue only — the ML initiates each roll from the loot
-- window; the running roll must be finished/closed before the next starts
-- (sequential holds); one-win chains across drops.
resetHarness()
-- 1001: Aaa 90(+10=100) beats Bbb 80 -> Aaa wins, marked won.
-- 1002: Aaa 99(excluded), Ccc 50(+50=100) -> Ccc wins.
math.random = rigged({ 2, 2, 2, 90, 80, 99, 50, 1, 1, 1, 1 }) -- identity, no double
Sim.SimBoss("TestBoss")
math.random = realRandom
-- Queued, nothing rolling: ML must initiate.
ok(ML.session == nil, "simboss starts nothing by itself")
eq(#ZugLoot.LootWindow.items, 2, "loot window lists both drops")
eq(ZugLoot.LootWindow.items[1].status, "open", "first drop open")
-- Roll the first item; a SECOND roll while its award pends is refused.
Sim.RequestRoll(1001)
ok(ML.SessionAny(1001) ~= nil, "first session resolved (parked)")
ok(ML.pendingAwardMenu ~= nil, "first award pending")
-- Multi-roll: the second item rolls while the first award pends
-- (roll A, park, roll B, award B, award A).
Sim.RequestRoll(1002)
ok(ML.SessionAny(1002) ~= nil, "second session runs while first parked")
ok(drain(), "drain second item")
-- The first already parked at its inline finish (award rows in the list,
-- session out of the live table); the menu pends for the ML.
ok(ML.SessionAny(1001) == nil or ML.ParkedSession(1001) ~= nil
  or ML.pendingAwardMenus ~= nil, "first resolved")
ok(ML.ParkedSession(1001) ~= nil, "finished session kept for award/continue")
ok(ZugLoot.LootWindow.Find(1001) ~= nil, "1001 row parked for award")
ML.AwardChosen({ name = "Ccc", via = "winner" }, 1002)
ok(drain(), "drain 1002 award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1002, "Ccc"), "1002 won by Ccc (Aaa excluded)")
ok(ZugLoot.LootWindow.Find(1002) == nil, "1002 left the list")
ok(ML.ParkedSession(1001) ~= nil, "1001 parked session survives 1002 award")
ok(ML.pendingAwardMenus[1001] ~= nil, "1001 menu still pending")
-- Back to the first: award off its parked menu.
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(drain(), "drain 1001 award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "1001 won by Aaa")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 1, "1001 history intact")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1002), 1, "1002 history intact")
ok(next(ML.sessions) == nil, "no sessions left")
ok(next(ML.pendingAwardMenus or {}) == nil, "no menus left")
eq(#dropAdds, 2, "boss sim logs both awards")
eq(#shownItems, 2, "roller window shown per played item")

-- 7d. Sim Continue: finish parks the roll, Continue feeds FRESH rolls
-- for the still-unrolled members on the same session, Finish re-resolves.
resetHarness()
Sim.FakeCount = 4 -- pinned: Aaa SR, Bbb SR + 2 extra
math.random = rigged({ 90, 80, 40, 30 })
Sim.SimItem("1001")
ok(drain(), "drain 7d roll")
math.random = realRandom
ok(ML.ParkedSession(1001) ~= nil, "7d session parked after finish")
local sess7d = ML.ParkedSession(1001)
local nBefore = #sess7d.rolls
ok(nBefore >= 2, "7d first round recorded")
-- New sheet members joined: fresh names roll on Continue.
table.insert(ZugLoot.DB.sheet.items[1001].rollers, { name = "New", rolls = 1 })
math.random = rigged({ 77, 76, 75, 74 })
ZugLoot.LootWindow.OpenDetail(1001)
eq(ZugLoot.LootWindow.doAction(1001, "continue"), "continuing", "7d Continue")
ok(ML.SessionFor(1001) == sess7d, "7d same session re-attached")
ok(drain(), "drain 7d continued feeds")
local nAfter = #sess7d.rolls
ok(nAfter > nBefore, "7d continued rolls appended (" .. nBefore .. "->" .. nAfter .. ")")
local sawNew = false
for i = 1, #sess7d.rolls do
  if sess7d.rolls[i].name == "New" then sawNew = true end
end
ok(sawNew, "7d newcomer rolled on Continue")
math.random = realRandom
-- Finish again re-resolves the COMBINED list (no double finish —
-- feeds ran inline, nothing lingers); award closes it out.
ML.Finish(true, 1001)
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(drain(), "drain 7d award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "7d award after continue")

-- 8. Excluded re-roll visible with tag (async path via raid result line).
resetHarness()
SRData.MarkWon(ZugLoot.DB.sheet, 1001, "Aaa")
math.random = rigged({ 99, 10 }) -- holder SR rolls, no kind draws
Sim.SimItem("1001")
ok(drain(), "drain excluded")
ML.AwardChosen({ name = "Bbb", via = "winner" })
ok(drain(), "drain excluded award")
math.random = realRandom
local exclPrinted = false
for i = 1, #printed do
  -- Pysanka-style roll lines carry the tag inline ("Aaa: 99 (SR) [already won]").
  if string.find(printed[i], "Aaa: 99 (SR) [already won]", 1, true) then exclPrinted = true end
end
ok(exclPrinted, "sim result shows won re-roll with tag")
local h1001 = SRData.GetRolls(ZugLoot.DB.sheet, 1001)[1]
eq(#h1001.excluded, 1, "sim history records excluded")
eq(h1001.excluded[1].name, "Aaa", "sim history excluded name")

-- 9. Tie in sim resolves through the REAL pipeline: a tied finish
-- leaves the session open (no award, no won mark), the ML continues
-- with fresh tie-break rolls, and the combined list resolves.
resetHarness()
printed, dropAdds = {}, {}
-- Aaa 50(+10=60) ties Bbb 60: tie-breaks 70 vs 71 settle it.
math.random = rigged({ 50, 60, 70, 71 })
Sim.SimItem("1001")
math.random = realRandom
-- finishSim already tie-looped inline (same path as §10): the parked
-- menu holds the resolved winner, history written once per round.
ok(ML.pendingAwardMenu ~= nil, "tie winner parked for the ML")
ok(SRData.RollCount(ZugLoot.DB.sheet, 1001) >= 1, "tie rounds recorded")
local tieW = ML.pendingAwardMenu.data.winners
ok(tieW and tieW[1] ~= nil, "tie resolved to a winner")
ok(#dropAdds == 0, "no award logged before the ML picks one")
ML.AwardChosen({ name = tieW[1].name, via = "winner" })
ok(drain(), "drain tie award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, tieW[1].name), "tie winner marked")
eq(#dropAdds, 1, "exactly one award after tie")

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
ok(ML.SessionAny(1001) == nil, "session closed after ML award")
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
math.random = rigged({ 90, 80 }) -- holder SR rolls, no kind draws
Sim.SimItem("1001")
printed = {}
Sim.SimBoss("TestBoss")
ok(string.find(printed[#printed], "already running"), "second sim refused while running")
Sim.Stop()
eq(#Sim.pending, 0, "simstop clears queue")
-- Hard stop: session dead, menu cleared, windows closed (no timers exist
-- to kill anymore — feeds ran inline).
ok(ML.SessionAny(1001) == nil, "simstop kills the live session")
ok(ML.pendingAwardMenu == nil, "simstop clears the award menu")
ok(ZugLoot.LootWindow.detail == nil, "simstop closes the detail")
ok(ZugLoot.LootWindow.frame == nil or ZugLoot.LootWindow.frame.hidden ~= false,
  "simstop hides the loot window")
-- A new sim starts clean immediately; the stopped item cannot be awarded.
Sim.SimItem("1001")
ok(ML.SessionAny(1001) ~= nil, "new sim starts right after stop")
ML.Cancel() -- tidy: requeues per Cancel semantics, then stop everything
Sim.Stop()
ok(ML.SessionAny(1001) == nil, "stop after cancel stays stopped")
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
local menuShown = nil
ZugLoot.AwardMenuUI = { Show = function(sess, data) menuShown = data end }
Sim.SimItem("1001")
ok(drain(), "drain to award menu")
math.random = realRandom
ok(ML.SessionAny(1001) ~= nil, "session held for ML award decision")
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
ok(ML.SessionAny(1001) == nil, "session closed after award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "winner marked after confirm")
ZugLoot.AwardMenuUI = nil
StaticPopupDialogs = nil
StaticPopup_Show = nil

-- 16. Fresh loot session: a second simboss starts clean — leftover
-- detail, menu and raider rolls from the first run do not carry over.
-- Awarded items are GONE (no done rows kept anywhere).
resetHarness()
math.random = rigged({ 2, 2, 2, 90, 80, 50, 50, 1, 1 }) -- identity, no double
Sim.SimBoss("TestBoss")
Sim.RequestRoll(1001)
ok(drain(), "drain fresh-run item 1")
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(drain(), "drain fresh-run award")
math.random = realRandom
eq(#Sim.pending, 1, "first run leaves one item queued")
ok(ZugLoot.LootWindow.Find(1001) == nil, "awarded item left the list")
-- A second run rebuilds ONLY its own queue; awarded rows never come back.
-- (Second run while the first still has an item queued is refused — the ML
-- finishes or stops the first run first; so stop it, then start fresh.)
Sim.Stop()
math.random = rigged({ 2, 2, 2, 1, 1, 1, 1 }) -- identity shuffle, no double
Sim.SimBoss("TestBoss")
math.random = realRandom
eq(#Sim.pending, 2, "queue rebuilt fresh (no leftovers)")
ok(ZugLoot.LootWindow.Find(1001) ~= nil, "rebuilt list has the new run's rows")
eq(ZugLoot.LootWindow.Find(1001).status, "open", "rebuilt row starts open")
eq(#ZugLoot.LootWindow.items, 2, "loot window lists only the new drops")
-- Sheet history carries the record instead of the list.
ok(SRData.RollCount(ZugLoot.DB.sheet, 1001) >= 1, "history recorded by first run")

-- 16b. Awarded items leave the list; last award closes the window.
resetHarness()
math.random = rigged({ 2, 2, 2, 90, 80, 50, 50, 1, 1 })
Sim.SimBoss("TestBoss")
eq(#ZugLoot.LootWindow.items, 2, "both queued items listed")
Sim.RequestRoll(1001)
ok(drain(), "drain 16b item")
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(drain(), "drain 16b award")
ok(ZugLoot.LootWindow.Find(1001) == nil, "awarded item left the list")
ok(ZugLoot.LootWindow.Find(1002) ~= nil, "unrolled item still listed")
math.random = realRandom
-- Roll and award the last one: window closes, run ends.
Sim.RequestRoll(1002)
ok(drain(), "drain 16b last item")
ML.AwardChosen({ name = "Ccc", via = "winner" })
ok(drain(), "drain 16b last award")
eq(#ZugLoot.LootWindow.items, 0, "list empty after last award")
ok(Sim.running == false, "sim run ended")
ok(ZugLoot.LootWindow.frame == nil or ZugLoot.LootWindow.frame.hidden ~= false,
  "loot window closed when nothing left")
-- Sheet history carries the record instead of the list.
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 1, "1001 session in history")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1002), 1, "1002 session in history")

-- 17. No item may vanish: the row stays (rolling) while the roll runs and
-- after a no-winner finish; only the ML's award (or direct award) marks
-- it done. Covers: zero-roll sessions (all excluded),roller-less on-sheet
-- items, and stub items created by earlier runs.
resetHarness()
-- Everyone has already won 1001 -> all SR rolls excluded -> no winner.
SRData.MarkWon(ZugLoot.DB.sheet, 1001, "Aaa")
SRData.MarkWon(ZugLoot.DB.sheet, 1001, "Bbb")
math.random = rigged({ 90, 80 }) -- holder SR rolls, no kind draws
Sim.SimItem("1001")
ok(ML.SessionAny(1001) ~= nil, "no-winner session parked")
ok(Sim.live ~= nil or Sim.lives ~= nil, "live tables intact after inline finish")
ok(ZugLoot.LootWindow.Find(1001) ~= nil, "row present at roll start")
eq(ZugLoot.LootWindow.Find(1001).status, "rolling", "row rolling, not removed")
ok(drain(), "drain no-winner item")
math.random = realRandom
-- Nothing auto-closed or auto-skipped: the ML still owns the decision.
ok(ML.SessionAny(1001) ~= nil, "session parked on the award menu (no auto-close)")
ok(ML.pendingAwardMenu ~= nil, "award menu pending even with no winners")
ok(ML.pendingAwardMenu.data.none, "menu flagged none")
ok(ML.ParkedSession(1001) ~= nil, "session parked for award")
ok(ZugLoot.LootWindow.Find(1001) ~= nil, "row still listed after the roll")
eq(ZugLoot.LootWindow.Find(1001).status, "rolling", "row still rolling until awarded")
-- ML hands it to someone else: only now does it go done.
ML.AwardChosen({ name = "Stranger", via = "menu" })
ok(drain(), "drain no-winner award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Stranger"), "ML pick awarded")
ok(Sim.live == nil, "item no longer live after award")
ok(ZugLoot.LootWindow.Find(1001) == nil, "awarded row left the list")

-- 18. Roller-less on-sheet items fall back to an open roll of the sheet
-- (instead of finishing with zero rolls and no winner).
resetHarness()
ZugLoot.DB.sheet.items[1001].rollers = {}
Sim.FakeCount = 3 -- pinned open group
math.random = rigged({ 2, 2, 2, 42, 43, 44, 1, 1 }) -- identity shuffle + open rolls
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
ok(Sim.lives == nil or Sim.lives[1001] == nil, "fallback item cleared on award")
ok(ZugLoot.LootWindow.Find(1001) == nil, "fallback award left the list")

-- 19. Solo rehearsal (/zl rehearse): corpse items queue with invented
-- rollers (3-5, no sheet needed), auto-play through the live pipeline,
-- and awards REALLY loot the corpse (solo LootSlot path). The real sheet
-- stays loaded throughout: invented names are fenced off sheet writes
-- (SR typing, won marks, history) via the session invented roster.
resetHarness()
grouping = "solo"
ZugLoot.DB.rehearse = true
ZugLoot.DB.sheet = nil -- no sheet: rehearsal must not require one
local lootSlots = {
  { link = nil, amount = "5 Copper" },
  { link = "item:1001:0:0:0", quality = 4 },
  { link = "item:9:0:0:0", quality = 1 },
}
GetNumLootItems = function() return #lootSlots end
GetLootSlotLink = function(s) return lootSlots[s] and lootSlots[s].link end
LootSlotIsCoin = function(s)
  return (lootSlots[s] and lootSlots[s].link == nil) and 1 or 0
end
GetLootSlotInfo = function(s)
  if lootSlots[s] and lootSlots[s].link == nil then
    return "Interface\\Icons\\INV_Misc_Coin_01", lootSlots[s].amount
  end
end
GetItemInfo = function(link)
  for i = 1, #lootSlots do
    if lootSlots[i].link == link then return "Item" .. i, link, lootSlots[i].quality end
  end
end
local lootedSlots = {}
-- Headless corpse: LootSlot removes the slot (client would fire
-- LOOT_SLOT_CLEARED; the rescan then confirms it).
LootSlot = function(slot, force)
  table.insert(lootedSlots, { slot, force })
  table.remove(lootSlots, slot)
end
UnitName = function() return "SoloPlayer" end
GetLootMethod = nil
CreateFrame = nil -- headless: data layer only
-- Manual default (general rollAuto off): items queue, nothing auto-plays —
-- the ML picks each item's Roll button.
ZugLoot.DB.rollAuto = false
math.random = rigged({ 4, 1, 90, 1, 80, 1, 70, 1, 60 })
-- headcount 4, then MS kind + roll per invented roller
local LW = ZugLoot.LootWindow
local realSheet = makeSheet()
ZugLoot.DB.sheet = realSheet -- loaded sheet must be parked, never marked
ML.OnLootOpened()
math.random = realRandom
eq(#LW.items, 3, "corpse rows listed (coin + 2 items)")
ok(Sim.rehearseRun, "rehearsal run started")
eq(#Sim.pending, 2, "both items queued, none auto-playing")
ok(ML.session == nil, "manual default: no auto-start")
eq(ZugLoot.DB.sheet, realSheet, "real sheet stays loaded (no swap)")
-- ML picks the head item's Roll button: queued entry plays with fakes.
eq(LW.doAction(1001, "roll"), "rolling", "Roll button plays queued entry")
-- Regression: the doAction flip must NOT wipe the rolls playOne just
-- landed (sim/rehearse starters own the rolling flip; the router's
-- re-flip cleared d.rolls -> "0 fake rolls" in the ML window, and
-- dragged the finished award view back to a sessionless rolling view
-- -> "waiting for rolls..." on a finished roll).
-- (playOne finishes inline, so the window is already at the award
-- phase with the menu — and the fed rolls must still be listed.)
eq(#(LW.detail and LW.detail.rolls or {}), 4, "ML window keeps the 4 fed rolls")
ok(LW.detail and LW.detail.menu ~= nil, "ML window holds the award menu")
eq(LW.detail and LW.detail.phase, "award", "ML window shows the award view")
local winLines = LW.DetailLines()
local sawWinRoll = false
for i = 1, #winLines do
  if string.find(winLines[i], "winner:", 1, true) then sawWinRoll = true end
end
ok(sawWinRoll, "ML window lists the winner, not waiting-for-rolls")
local liveEntry = nil
for _, e in pairs(Sim.lives or {}) do liveEntry = e break end
ok(liveEntry ~= nil and liveEntry.rehearse, "queued entry playing")
eq(#(liveEntry and liveEntry.rolls or {}), 4, "4 invented rolls (3-5 range)")
local invented = true
for i = 1, #(liveEntry and liveEntry.rolls or {}) do
  local nm = liveEntry.rolls[i].name
  local known = nm == "Aaa" or nm == "Bbb" or nm == "Ccc"
  if known then invented = false end
end
ok(invented, "rollers invented, none from the real sheet")
ok(not SRData.HasWon(realSheet, 1001, "Aldric"), "real sheet untouched")
-- Fence: invented names never read as SR even when the real sheet knows
-- a same-named roller (fake 1-100 stays MS, no bonus, no won flag).
-- (playOne finishes inline now, so the session is parked: fetch it via
-- SessionAny, which covers parked sessions too.)
local fenceSess = ML.SessionAny(1001)
ok(fenceSess ~= nil and fenceSess.invented ~= nil, "session carries invented roster")
ML.ApplySystemRoll(fenceSess, "Aldric", 99, 1, 100)
local lastFeed = fenceSess.rolls[#fenceSess.rolls]
eq(lastFeed.type, "MS", "invented 1-100 reads MS, never SR")
-- Fence probe cleaned up (first-roll-only would drop Aldric's real feed).
for i = #fenceSess.rolls, 1, -1 do
  if fenceSess.rolls[i].name == "Aldric"
      and fenceSess.rolls[i].roll == 99 then
    table.remove(fenceSess.rolls, i)
    break
  end
end
-- NOTE: playOne finishes inline now, so the head entry already resolved
-- into the parked award menu below (no live session, no pending timers).
-- Head plays: drain feeds + finish timer, menu pends for the ML.
ok(drain(), "drain rehearsal head")
ok(ML.pendingAwardMenu ~= nil, "award menu pending for ML pick")
-- Award it: corpse take fires for real (solo LootSlot + force flag).
local beforeLoot = #lootedSlots
ML.AwardChosen({ name = "Aldric", via = "winner" })
ok(drain(), "drain rehearsal award")
eq(#lootedSlots, beforeLoot + 1, "award really looted the corpse")
eq(lootedSlots[#lootedSlots][2], 1, "corpse take passes force flag")
-- Manual mode: second item waits for its Roll button (no auto-advance).
ok(ML.pendingAwardMenu == nil, "manual mode: no auto-advance")
ok(Sim.rehearseRun, "run stays open with items queued")
eq(LW.doAction(9, "roll"), "rolling", "Roll button plays second entry")
ok(drain(), "drain rehearsal second item")
if ML.pendingAwardMenu ~= nil then
  local beforeLoot2 = #lootedSlots
  ML.AwardChosen({ name = "Bryn", via = "winner" })
  ok(drain(), "drain rehearsal second award")
  eq(#lootedSlots, beforeLoot2 + 1, "second award looted the corpse")
end
ok(drain(), "drain rehearsal teardown")
ok(not Sim.rehearseRun, "run ended")
eq(ZugLoot.DB.sheet, realSheet, "real sheet still loaded after run")
ok(not SRData.HasWon(realSheet, 1001, "Aldric")
  and not SRData.HasWon(realSheet, 9, "Bryn"),
  "rehearsal marks never touched the real sheet")
eq(SRData.RollCount(realSheet, 1001), 0, "no rehearsal history on real sheet")
-- General auto-start flag on: head auto-plays straight off the scan.
-- Fresh corpse (the 1001/9 rows were awarded + removed above).
lootSlots = {
  { link = "item:1001:0:0:0", quality = 4 },
  { link = "item:9:0:0:0", quality = 1 },
}
ZugLoot.DB.rollAuto = true
math.random = rigged({ 3, 1, 90, 1, 80, 1, 70 })
-- headcount 3, then MS kind + roll per invented roller
ML.OnLootOpened()
math.random = realRandom
ok(Sim.rehearseRun, "auto run started")
ok(ML.pendingAwardMenu ~= nil, "auto-start: head resolved, menu pending")
Sim.StopRehearsal()
ok(not Sim.rehearseRun, "auto run stopped")
eq(ZugLoot.DB.sheet, realSheet, "sheet untouched by stop")
ZugLoot.DB.rollAuto = false
-- 19b. Second corpse mid-run tops up (ResetFresh wipes the queue on
-- every corpse): unplayed entries from corpse A survive alongside B's.
-- X-close on a rolling window finishes+parks (shared Close path), so a
-- fresh roll for the next item starts clean with intake on the alias.
ZugLoot.DB.rehearse = true
ZugLoot.DB.rollAuto = false
lootSlots = {
  { link = "item:1001:0:0:0", quality = 4 },
  { link = "item:1002:0:0:0", quality = 4 },
}
ML.OnLootOpened()
eq(#Sim.pending, 2, "corpse A queues two entries")
eq(LW.doAction(1001, "roll"), "rolling", "A head rolling")
ok(drain(), "drain A head")
ok(ML.pendingAwardMenu ~= nil, "A head awaiting award")
-- Loot corpse B while A's award pends: B's rows queue, A's menu lives.
lootSlots = {
  { link = "item:1003:0:0:0", quality = 4 },
}
ML.OnLootOpened()
local queuedB = false
for i = 1, #Sim.pending do
  if Sim.pending[i] and Sim.pending[i].itemID == 1003 then queuedB = true end
end
ok(queuedB, "corpse B tops up the run")
-- A's menu parks into A's cache entry (awards need A's corpse open, so
-- A is awarded after walking back — the designed resume flow).
local aMenuParked = false
for _, e in pairs(ML.corpseCache or {}) do
  if e and e.awardMenus then
    for k, menu in pairs(e.awardMenus) do
      if menu and menu.sess and menu.sess.itemID == 1001 then
        aMenuParked = true
      end
    end
  end
end
ok(aMenuParked, "A award menu parked in A's cache entry")
-- A's UNPLAYED queue entry (1002) shelves with A's corpse too — B's scan
-- ResetFresh must not orphan it.
local aQueueParked = false
for _, e in pairs(ML.corpseCache or {}) do
  if e and e.rehearsePending then
    for j = 1, #e.rehearsePending do
      if e.rehearsePending[j] and e.rehearsePending[j].itemID == 1002 then
        aQueueParked = true
      end
    end
  end
end
ok(aQueueParked, "A unplayed queue entry shelved with A's corpse")
eq(LW.doAction(1003, "roll"), "rolling", "B rolls while A parked")
ok(drain(), "drain B head")
ok(ML.pendingAwardMenu ~= nil, "B award menu pending")
ML.AwardChosen({ name = "Bryn", via = "winner" })
ok(drain(), "drain B award")
-- Walk back to A: window, roll state and award menu restore whole.
lootSlots = {
  { link = "item:1001:0:0:0", quality = 4 },
  { link = "item:1002:0:0:0", quality = 4 },
}
ML.OnLootOpened()
ok(ML.pendingAwardMenu ~= nil, "A award menu restored on walk-back")
ML.AwardChosen({ name = "Aldric", via = "winner" })
ok(drain(), "drain A award")
ok(not Sim.rehearseRun, "interleaved run ended")
eq(ZugLoot.DB.sheet, realSheet, "sheet still loaded after interleave")
-- Flag off: corpse scan queues nothing.
ZugLoot.DB.rehearse = false
ML.OnLootOpened()
ok(not Sim.rehearseRun, "flag off: no rehearsal run")
-- New corpse during a live sim follows the shared fresh-corpse rule
-- (ResetFresh clears all flows equally — sims die on new corpses by
-- design); rehearsal then starts clean on the fresh rows like any flow.
ZugLoot.DB.rehearse = true
lootSlots = { { link = "item:2001:0:0:0", quality = 4 } } -- fresh corpse
ML.OnLootOpened()
local freshQ = false
for i = 1, #Sim.pending do
  if Sim.pending[i] and Sim.pending[i].itemID == 2001 then freshQ = true end
end
ok(freshQ, "fresh corpse queues under shared fresh-corpse rule")
Sim.StopRehearsal()
ZugLoot.DB.rehearse = false
-- Cleanup live-only globals this section introduced.
GetNumLootItems, GetLootSlotLink, LootSlotIsCoin, GetLootSlotInfo = nil, nil, nil, nil
GetItemInfo, LootSlot, UnitName = nil, nil, nil

return T
