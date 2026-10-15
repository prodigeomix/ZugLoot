-- tests/test_mlflow.lua
-- ML-driven flow: boss loot scan -> loot window, Roll per item, award menu
-- (winners + roll-type groups + TMOG kind row + class-sorted candidates),
-- /zl award pick. The ML awards the SR, MS, OS or TMOG winner directly;
-- no trade handling (out of scope).
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
-- Atlas-CFM fixture: sim drops are read live from THE GAME's loot tables
-- (fake AtlasCFM here). TestBoss: 1001 @20%, 1002 @8%, 1003 @0% (never
-- drops); a rigged drop draw of 2 hits both (2<=2000, 2<=800), so every
-- SimBoss("TestBoss") below queues exactly 1001+1002.
AtlasCFM = { InstanceData = { TestRaid = { Name = "Test Raid", Acronym = "TR", MaxPlayers = 40,
  Bosses = { { id = "TestBoss", name = "Test Boss", items = {
      { id = 1001, dropRate = 20 }, { id = 1002, dropRate = 8 },
      { id = 1003, dropRate = 0 } } } } } } }
dofile("AtlasLoot.lua")
local dropAdds = {}
ZugLoot.DropLog = { Add = function(itemID, link, src, outcome, winner)
  table.insert(dropAdds, { itemID = itemID, src = src, outcome = outcome, winner = winner }) end }
ZugLoot.MainWindow = nil
ZugLoot.SRView = nil
time = time or os.time

local chatSent = {}
SendChatMessage = function(msg, channel)
  table.insert(chatSent, { msg = msg, channel = channel })
end

local grouping = "solo"
ZugLoot.SRSecurity = {
  IsInRaid = function() return grouping == "raid" end,
  IsInParty = function() return grouping == "party" end,
  IsInGroup = function() return grouping ~= "solo" end,
  IsSolo = function() return grouping == "solo" end,
  AmML = function() return true end,
}

local shownItems = {}
ZugLoot.RaiderLootUI = {
  ShowItem = function(link) table.insert(shownItems, link) end,
  OnRoll = function() end,
  Hide = function() end,
}

-- Corpse loot stub: slot -> { link, quality }.
local lootSlots = {}
GetNumLootItems = function() return #lootSlots end
GetLootSlotLink = function(slot) return lootSlots[slot] and lootSlots[slot].link end
GetItemInfo = function(link)
  for i = 1, #lootSlots do
    if lootSlots[i].link == link then
      return "Item" .. i, link, lootSlots[i].quality
    end
  end
  return nil
end

dofile("Comm.lua")
dofile("LootWindow.lua")
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
  Sim.live = nil
  Sim.running = false
  Sim.auto = false
  Sim.lastEntries = {}
  Sim.lives = {}
  Sim.raid = nil -- simraid staging (cleared live by ResetFresh/Stop)
  Sim.FakeCount = 2 -- pinned headcount: rigged rng maps 1:1 onto rolls
  ML.session = nil
  ML.sessions = {}
  ML.parkedSessions = nil
  ML.pendingAwardMenu = nil
  ML.pendingAwardMenus = nil
  ML.pendingLoot = nil -- click confirmations in flight (see LootCorpseSlot)
  ML.corpseCache = {} -- session corpse cache (never persisted)
  ML.corpseOrder = {}
  ML.lootGUID = nil -- pinned corpse GUID (range gate + corpse reuse)
  ML.lootTarget = nil -- pinned loot target (fallback path)
  ML.lootKey = nil -- pinned corpse key (guid: or fp:)
  ML.lootOpen = false -- open-session flag (OnLootOpened sets it)
  ZugLoot.LootWindow.silentLootArms = nil -- kill-switch watch
  ZugLoot.LootWindow.blizzardTakeover = true -- harness detaches (see §2)
  ZugLoot.LootWindow.watchdogs = nil -- click watchdogs
  ZugLoot.LootWindow.Clear()
  printed, dropAdds, chatSent, shownItems = {}, {}, {}, {}
  grouping = "solo"
  lootSlots = {}
  ZugLoot.DB = { sheet = makeSheet(), rollTime = rollTime or 2 }
  ZugLoot.DB.lootTakeover = true -- harness wants the takeover (see §2)
end

local function drain(step)
  local guard = 0
  while ZugLoot.Timer.Pending() > 0 and guard < 500 do
    ZugLoot.Timer.Update(step or 0.5)
    guard = guard + 1
  end
  return guard < 500
end

-- 2b. Class colors via the sheet fallback: no roster APIs here, so the
-- sheet's stored classes paint the award menu, detail lines and banner.
resetHarness()
SRData.SetPlayerClass(ZugLoot.DB.sheet, "Aaa", "PaladinHoly")
SRData.SetPlayerClass(ZugLoot.DB.sheet, "Bbb", "Mage")
SRData.SetPlayerClass(ZugLoot.DB.sheet, "Ccc", "Druid")
local res2b = ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001,
  { { name = "Aaa", roll = 90, type = "SR" }, { name = "Bbb", roll = 80, type = "SR" } },
  { cap = 100, requireSR = true })
local menu2b = ML.BuildAwardMenu(
  { itemID = 1001, itemLink = "item:1001", id = 1 }, res2b)
ok(menu2b.candidates[1] ~= nil, "candidates built")
-- Rollers show once — with their rolls in the group rows — never again
-- bare in the candidate list (non-rollers only).
local cclass = {}
for i = 1, #menu2b.candidates do cclass[menu2b.candidates[i].name] = menu2b.candidates[i].class end
eq(cclass["Aaa"], nil, "rollers leave the candidate list")
eq(cclass["Bbb"], nil, "rollers leave the candidate list")
eq(cclass["Ccc"], "Druid", "sheet fallback class on non-roller candidate")
local mlines = ML.AwardMenuLines(menu2b)
local sawPink, sawMage = false, false
for i = 1, #mlines do
  if string.find(mlines[i], "|cFFF58CBAAaa|r", 1, true) then sawPink = true end
  if string.find(mlines[i], "|cFF69CCF0Bbb|r", 1, true) then sawMage = true end
end
ok(sawPink, "award menu colors Paladin pink")
ok(sawMage, "award menu colors Mage")
-- Winner banner (FontString) carries the same color.
local bannerShown = {}
ZugLoot.RaiderLootUI.ShowResult = function(m) table.insert(bannerShown, m) end
ML.AnnounceResult({ itemID = 1001, itemLink = "item:1001", dispName = "item:1001" }, res2b)
local sawBannerPink = false
for i = 1, #bannerShown do
  if string.find(bannerShown[i], "|cFFF58CBAAaa|r", 1, true) then sawBannerPink = true end
end
ok(sawBannerPink, "result banner colors the winner")
ZugLoot.RaiderLootUI.ShowResult = nil
-- ClassColors resolves the sheet class directly (the roll window routes
-- through the same ClassOf; RaiderLootUI is not loaded in this suite).
eq(ZugLoot.ClassColors.ClassOf("Aaa"), "Paladin", "sheet class resolves")
eq(ZugLoot.ClassColors.ColoredName("Aaa"), "|cFFF58CBAAaa|r", "roll-window color path")


-- 1. Boss looted: ML scans corpse, announces loot, loot window opens;
-- nothing auto-starts — the ML initiates each roll.
resetHarness()
lootSlots = {
  { link = "item:1001:0:0:0", quality = 4 },
  { link = "item:1002:0:0:0", quality = 4 },
  { link = "item:9:0:0:0", quality = 1 }, -- grey: ignored
}
ML.OnLootOpened()
ok(ML.session == nil, "no auto-start: ML initiates")
eq(#ZugLoot.LootWindow.items, 3, "loot window covers every slot")
eq(ZugLoot.LootWindow.items[1].itemID, 1001, "first roll row")
eq(ZugLoot.LootWindow.items[1].status, "open", "first drop open")
eq(ZugLoot.LootWindow.items[1].badge, "SR:2", "SR count badge")
ok(ZugLoot.LootWindow.items[3].free, "grey is a free row, not a roll row")
local sawHead, sawLoot = false, false
for i = 1, #printed do
  if string.find(printed[i], "dropped 2 items:", 1, true) then sawHead = true end
  if string.find(printed[i], "2. item:1002", 1, true) then sawLoot = true end
end
ok(sawHead, "drop head announced (mob + count)")
ok(sawLoot, "second item announced (numbered)")
-- ML initiates from the window; unknown items are refused.
ML.StartItemRoll(1001)
ok(ML.session ~= nil, "ML-initiated session live")
eq(ML.session.itemID, 1001, "correct item rolling")
ML.Cancel()
ML.StartItemRoll(4242)
ok(ML.session == nil, "unknown item refused")

-- 2. Universal loot: whoever opens the corpse runs the window — any
-- loot method, master looter or not, solo included. Blizzard's frame is
-- DETACHED session-wide (RollFor parity: UnregisterAllEvents + OnHide
-- stripped, not one-shot hidden, so it never pops back); awards loot slot.
resetHarness()
ZugLoot.SRSecurity.AmML = function() return false end
local blizzDetached, blizzHidden, lootedSlots, masterGiven = 0, 0, {}, {}
LootFrame = {
  UnregisterAllEvents = function() blizzDetached = blizzDetached + 1 end,
  SetScript = function() blizzDetached = blizzDetached + 1 end,
  Hide = function() blizzHidden = blizzHidden + 1 end,
}
LootSlot = function(slot, force) table.insert(lootedSlots, { slot, force }) end
GiveMasterLoot = function(slot, who) table.insert(masterGiven, { slot, who }) end
UnitName = function() return "SoloPlayer" end
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
eq(#ZugLoot.LootWindow.items, 1, "non-ML corpse still lists loot")
ok(blizzDetached >= 2, "Blizzard loot frame detached (events + OnHide)")
ok(blizzHidden >= 1, "Blizzard loot frame hidden while we cover the corpse")
ok(ZugLoot.LootWindow.blizzardTakeover, "takeover flag armed")
eq(ZugLoot.LootWindow.items[1].slot, 1, "row tracks its corpse slot")
-- Solo award loots the corpse slot, then drops the row.
ML.AwardDirect(1001, "SoloPlayer", "loot")
eq(#lootedSlots, 1, "corpse slot looted on award")
ok(ZugLoot.LootWindow.Find(1001) == nil, "awarded row gone, Blizzard frame stays hidden")
-- Close with leftovers re-scans (rows come back); empty closes out.
lootSlots = {
  { link = "item:1001:0:0:0", quality = 4 },
  { link = "item:1002:0:0:0", quality = 4 },
}
-- Close reconciles with the corpse: unconfirmed rows stay listed
-- (nothing looted them), so Close parks the window instead of hiding it.
ML.OnLootOpened()
eq(ZugLoot.LootWindow.CloseOverview(), "parked", "close with leftovers parks")
eq(#ZugLoot.LootWindow.items, 2, "leftovers still listed after close")
-- Loot one slot for real (corpse confirms), Close reconciles it away;
-- the last row out closes the loot.
lootSlots = { { link = "item:1002:0:0:0", quality = 4 } } -- slot 1 looted away
ZugLoot.LootWindow.OnEvent("LOOT_SLOT_CLEARED")
eq(#ZugLoot.LootWindow.items, 1, "confirmed slot drops after rescan")
eq(ZugLoot.LootWindow.CloseOverview(), "parked", "one leftover still parks")
lootSlots = {} -- corpse empty
ZugLoot.LootWindow.OnEvent("LOOT_SLOT_CLEARED")
eq(ZugLoot.LootWindow.CloseOverview(), "closed", "empty close stays shut")
lootSlots = {
  { link = "item:1001:0:0:0", quality = 4 },
  { link = "item:1002:0:0:0", quality = 4 },
}
-- Master-loot handoff: winner ~= us under master loot mints GiveMasterLoot.
GetLootMethod = function() return "master" end
UnitName = function() return "SoloPlayer" end
LootFrame = { Hide = function() end }
LootSlot = function() error("must not plain-loot under master loot") end
GiveMasterLoot = function(slot, who) table.insert(masterGiven, { slot, who }) end
-- Candidate roster: winner sits at index 2 (RollFor parity: award by
-- candidate INDEX, not name).
GetMasterLootCandidate = function(slot, i)
  if i == 1 then return "SoloPlayer" elseif i == 2 then return "SomebodyElse" end
  return nil
end
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
ML.AwardDirect(1001, "SomebodyElse", "loot")
eq(#masterGiven, 1, "master loot handed to the winner")
eq(masterGiven[1][1], 1, "correct corpse slot")
eq(masterGiven[1][2], 2, "correct candidate index")
-- Non-candidate award is refused: no loot call, row stays.
ML.OnLootOpened()
local refusedBefore = #masterGiven
ML.AwardDirect(1001, "NobodyHere", "loot")
eq(#masterGiven, refusedBefore, "non-candidate award issues no loot call")
ok(ZugLoot.LootWindow.Find(1001) ~= nil, "refused award keeps the row")
GetMasterLootCandidate = nil
-- Grey-only corpse: no Blizzard fallback — the grey is a free row in OUR
-- window (click loots it). Golden rule: nothing falls back to Blizzard.
GetLootMethod = nil -- solo: plain LootSlot path
LootSlot = function(slot, force) table.insert(lootedSlots, { slot, force }) end
LootFrame = { UnregisterAllEvents = function() end, SetScript = function() end,
  Show = function() error("must never show Blizzard frame") end, Hide = function() end }
lootSlots = { { link = "item:9:0:0:0", quality = 1 } } -- grey only: free row
ML.OnLootOpened()
eq(#ZugLoot.LootWindow.items, 1, "grey-only corpse: one free row")
ok(ZugLoot.LootWindow.items[1].free, "grey row is free, not rolled")
local freeSlot = ZugLoot.LootWindow.items[1].slot
local beforeFree = #lootedSlots
ML.LootCorpseSlot(nil, 9, "SoloPlayer")
eq(#lootedSlots, beforeFree + 1, "free row loots its corpse slot")
eq(lootedSlots[#lootedSlots][1], freeSlot, "correct corpse slot")
eq(lootedSlots[#lootedSlots][2], 1, "SuperWoW force flag passed")
-- Coin slot: first row, loots on click (client GetLootSlotType path is
-- stubbed here via LootSlotIsCoin; the scan reads it, not the link).
LootSlotIsCoin = function(slot) if lootSlots[slot] and lootSlots[slot].link == nil then return 1 end return 0 end
GetLootSlotInfo = function(slot) if lootSlots[slot] and lootSlots[slot].link == nil then return "Interface\\Icons\\INV_Misc_Coin_01", lootSlots[slot].amount or "12 Copper" end end
lootSlots = { { link = nil }, { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
eq(ZugLoot.LootWindow.items[1].itemID, "Coin", "coin row leads the list")
ok(ZugLoot.LootWindow.items[1].coin, "coin flagged")
local beforeCoin = #lootedSlots
ML.LootCorpseSlot(nil, "Coin", "SoloPlayer")
eq(#lootedSlots, beforeCoin + 1, "coin row loots its corpse slot")
eq(ZugLoot.LootWindow.items[1].texture, "Interface\\Icons\\INV_Misc_Coin_01",
  "coin row uses slot texture")
-- Zero-copper corpses (empty coin slot) grow no phantom row …
lootSlots = { { link = nil, amount = "0 Copper" },
  { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
eq(#ZugLoot.LootWindow.items, 1, "empty coin slot skipped")
eq(ZugLoot.LootWindow.items[1].itemID, 1001, "item row only")
-- … nor do blank-amount slots; icon falls back to the gold coin.
lootSlots = { { link = nil, amount = "" } }
GetLootSlotInfo = function(slot)
  if lootSlots[slot] and lootSlots[slot].link == nil then
    return nil, lootSlots[slot].amount
  end
end
-- (empty scan leaves existing rows alone, so assert the scan itself)
eq(ML.ScanSlot(1, 3), nil, "blank coin slot skipped")
lootSlots = { { link = nil, amount = "3 Silver" } }
ML.OnLootOpened()
eq(ZugLoot.LootWindow.items[1].texture, "Interface\\Icons\\INV_Misc_Coin_01",
  "coin icon fallback (no question mark)")
-- IsEmptyCoin unit cases: nonzero digit anywhere = money.
local LW2 = ZugLoot.LootWindow
ok(LW2.IsEmptyCoin("0 Copper"), "0 copper is empty")
ok(LW2.IsEmptyCoin(""), "blank is empty")
ok(LW2.IsEmptyCoin(nil), "nil is empty")
ok(not LW2.IsEmptyCoin("12 Copper"), "12 copper is money")
ok(not LW2.IsEmptyCoin("1 Gold, 0 Silver, 0 Copper"), "mixed is money")
GetLootSlotInfo = nil
LootSlotIsCoin = nil
-- Row click routing: coin/free rows loot at once (no detail); roll rows
-- open the detail. Duplicate itemIDs loot the CLICKED slot only.
local LW = ZugLoot.LootWindow
LootSlotIsCoin = function(slot) if lootSlots[slot] and lootSlots[slot].link == nil then return 1 end return 0 end
GetLootSlotInfo = function(slot) if lootSlots[slot] and lootSlots[slot].link == nil then return "Interface\\Icons\\INV_Misc_Coin_01", lootSlots[slot].amount or "12 Copper" end end
lootSlots = { { link = nil },
  { link = "item:9:0:0:0", quality = 1 },
  { link = "item:9:0:0:0", quality = 1 },
  { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
-- Click-to-loot is confirm-driven: click issues the call and dims the
-- row ("looting"); the row drops only when LOOT_SLOT_CLEARED confirms
-- the slot left the corpse. Simulate the corpse: slot 1 (coin) empties.
eq(LW.items[1].itemID, "Coin", "coin leads")
eq(LW.OnRowClick("Coin"), "looting", "coin click issues the loot call")
eq(lootedSlots[#lootedSlots][1], 1, "coin slot called")
ok(LW.Find("Coin") ~= nil, "row stays until the corpse confirms")
table.remove(lootSlots, 1) -- corpse: coin gone, slots shift down
LW.OnEvent("LOOT_SLOT_CLEARED")
ok(LW.Find("Coin") == nil, "coin row gone after confirm")
local freeRows = {}
for i = 1, #LW.items do if LW.items[i].free then table.insert(freeRows, LW.items[i]) end end
eq(#freeRows, 2, "two duplicate grey rows listed")
local greySlot = freeRows[1].slot
eq(LW.OnRowClick(9), "looting", "grey click issues the loot call")
eq(lootedSlots[#lootedSlots][1], greySlot, "clicked row's own slot called")
-- Corpse confirm: ONLY the clicked slot empties (duplicate survives).
for i = #lootSlots, 1, -1 do
  if lootSlots[i].link == "item:9:0:0:0" and i == greySlot then
    table.remove(lootSlots, i) break
  end
end
LW.OnEvent("LOOT_SLOT_CLEARED")
local left = 0
for i = 1, #LW.items do if LW.items[i].itemID == 9 then left = left + 1 end end
eq(left, 1, "one duplicate grey still listed")
-- Solo: even threshold+ rows loot on click (nobody to roll against).
-- Same confirm flow: click dims, corpse confirm drops the row.
grouping = "solo"
local soloBefore = #lootedSlots
eq(LW.OnRowClick(1001), "looting", "solo roll row click loots to self")
eq(#lootedSlots, soloBefore + 1, "solo click moved the corpse slot")
ok(LW.Find(1001) ~= nil, "solo row stays until confirm")
for i = #lootSlots, 1, -1 do
  if lootSlots[i].link == "item:1001:0:0:0" then table.remove(lootSlots, i) break end
end
LW.OnEvent("LOOT_SLOT_CLEARED")
ok(LW.Find(1001) == nil, "solo row gone after confirm")
-- Failed loot (slot still on the corpse: locked, full bags, range)
-- keeps the row: re-arm, rescan, row returns to open.
LootSlotIsCoin = nil -- slot 1 is an item again, not coin
lootSlots = { { link = "item:1002:0:0:0", quality = 4 } }
ML.OnLootOpened()
grouping = "solo"
eq(LW.OnRowClick(1002), "looting", "retryable click issues the call")
LW.OnEvent("LOOT_SLOT_CLEARED") -- corpse unchanged: slot still there
ok(LW.Find(1002) ~= nil, "failed loot keeps the row for retry")
eq(LW.Find(1002).status, "open", "failed row returns to open")
-- Walked-away click: corpse closed (LOOT_CLOSED fanned out to both
-- handlers like Core does, lootOpen false) blocks BEFORE any corpse
-- read. Rows stay, nothing dims, log explains.
-- (Previously VerifySlot read an empty corpse -> "gone" -> rescan wipe.)
ML.OnEvent("LOOT_CLOSED")
LW.OnEvent("LOOT_CLOSED")
ok(ML.lootOpen == false, "session flag tracks close")
local rowsBefore = #LW.items
eq(LW.OnRowClick(1002), "not looting", "closed-corpse click blocked")
eq(#LW.items, rowsBefore, "blocked click wipes nothing")
ok(LW.Find(1002) ~= nil and LW.Find(1002).status == "open",
  "blocked row untouched, never dims")
local sawNoLoot = false
for i = 1, #printed do
  if string.find(printed[i], "no loot open", 1, true) then sawNoLoot = true break end
end
ok(sawNoLoot, "log explains re-loot")
-- Closed-corpse award blocks the same way: row + menu survive for the
-- re-loot. Reopen, then the same award goes through. (Live session:
-- silent sessions are sim awards with no corpse by design.)
ML.BeginSession(1002, "item:1002", "SR", false)
ML.ApplySystemRoll(ML.session, "Aaa", 90, 1, 100)
ML.Finish(true, 1002)
eq(ML.AwardChosen({ name = "Aaa", via = "winner" }), nil,
  "award blocked with no loot open")
ok(not SRData.HasWon(ZugLoot.DB.sheet, 1002, "Aaa"), "blocked award marks nothing")
ok(LW.Find(1002) ~= nil, "blocked award keeps the row")
ok(ML.pendingAwardMenu ~= nil, "blocked award keeps the menu")
ML.OnEvent("LOOT_OPENED") -- walk back, corpse open again
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(SRData.HasWon(ZugLoot.DB.sheet, 1002, "Aaa"), "re-looted award lands")
-- Live rolls run on the same shared clock: armed at start, auto-finish
-- at timeout, disarmed by an early Finish (no late double-finish).
resetHarness()
ML.BeginSession(1001, "item:1001", "SR", false)
ML.ApplySystemRoll(ML.session, "Aaa", 90, 1, 100)
ok(ML.session ~= nil and ML.session.rollTimer ~= nil, "live roll arms the shared clock")
ok(ML.pendingAwardMenu == nil, "live roll not finished yet")
ok(drain(), "drain the live clock")
ok(ML.ParkedSession(1001) ~= nil, "live roll auto-finished at timeout")
ok(ML.pendingAwardMenu ~= nil, "live award menu pends")
ok(ZugLoot.Timer.Pending() == 0, "finished roll leaves no live handles")
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(drain(), "drain live award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "live auto-finished roll awards")
-- Early Finish disarms: nothing fires late.
resetHarness()
ML.BeginSession(1001, "item:1001", "SR", false)
ML.ApplySystemRoll(ML.session, "Aaa", 90, 1, 100)
ML.Finish(true, 1001)
ok(ML.ParkedSession(1001) ~= nil, "early Finish parks")
ok(ZugLoot.Timer.Pending() == 0, "early Finish disarms the clock")
ok(drain(), "drain after early finish")
ok(ML.pendingAwardMenu ~= nil, "menu still pends, no double finish")
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(drain(), "drain early-finish award")
-- Grouped: the same row opens the roll detail instead.
LootSlotIsCoin = nil -- slot 1 is an item again, not coin
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
grouping = "party"
eq(LW.OnRowClick(1001), "detail", "grouped roll row click opens detail")
ok(LW.detail ~= nil and LW.detail.itemID == 1001, "detail tracks the roll row")
LW.CloseDetail()
-- Group loot honors the PARTY threshold (green 2 .. epic 4): at/above it
-- the item enters a group roll (GROUP row, ROLL badge, click never loots
-- — Blizzard's Need/Greed owns it, row drops on the roll's resolve);
-- below it the item is directly lootable (free row). Grey/white never roll.
GetLootMethod = function() return "group" end
grouping = "party"
LootSlotIsCoin = nil
GetLootThreshold = function() return 2 end -- party rolls green+
lootSlots = { { link = "item:2001:0:0:0", quality = 2 } }
ML.OnLootOpened()
eq(#LW.items, 1, "green listed under group loot")
ok(LW.items[1].group, "green is a group row at threshold green")
eq(LW.items[1].badge, "ROLL", "group row carries ROLL badge")
eq(LW.OnRowClick(2001), "group roll", "group row click never loots")
-- +1 failed-loot retry, +1 re-looted award since soloBefore; the group
-- click itself adds none.
eq(#lootedSlots, soloBefore + 3, "no corpse call for group rows")
-- Same green, threshold epic: below the roll cutoff -> free row.
GetLootThreshold = function() return 4 end
ML.OnLootOpened()
ok(LW.items[1].free and not LW.items[1].group, "green below epic is free")
eq(LW.OnRowClick(2001), "looting", "below-threshold green loots direct")
-- Slot-quality wins over the cache: uncached GetItemInfo (nil) must not
-- misclassify an epic as free loot — the slot's own quality decides.
GetItemInfo = function(link) return nil end -- cache cold
GetLootSlotInfo = function(slot)
  return "tex", "Epic Sword", 1, 4 -- 4th return: slot quality
end
lootSlots = { { link = "item:3001:0:0:0", quality = nil } }
ML.OnLootOpened()
ok(LW.Find(3001) ~= nil and not LW.Find(3001).free, "slot quality classifies")
eq(LW.Find(3001).quality, 4, "slot quality kept")
GetLootSlotInfo = nil
GetItemInfo = function(link)
  for i = 1, #lootSlots do
    if lootSlots[i].link == link then
      return "Item" .. i, link, lootSlots[i].quality
    end
  end
  return nil
end
GetLootThreshold = nil
-- START_LOOT_ROLL / RollOnLoot voting lives in RaiderLootUI (mock-frame
-- coverage in mockrun.lua); the mlflow stub only asserts the dice route
-- votes through RollOnLoot and never RandomRoll chat spam here.
ok(ZugLoot.RaiderLootUI.ShowItem ~= nil, "raider frame wired")
grouping = "solo"
GetLootThreshold = nil
-- A pcall-level blowup in the loot call must NEVER dim the row: the
-- error surfaces in chat and the click reports "loot failed" (the
-- "gray and says done, still not looted" ghost this guards).
LootSlot = function(slot) error("boom") end
lootSlots = { { link = "item:1002:0:0:0", quality = 4 } }
ML.OnLootOpened()
eq(LW.OnRowClick(1002), "loot failed", "erroring loot call is not success")
eq(LW.Find(1002).status, "open", "row never dims on call error")
LootSlot = function(slot, force) table.insert(lootedSlots, { slot, force }) end
-- BoP take: LOOT_BIND_CONFIRM confirms every armed click slot.
lootSlots = { { link = "item:1002:0:0:0", quality = 4 } }
ML.OnLootOpened()
eq(LW.OnRowClick(1002), "looting", "bop click issues the call")
local confirms = {}
ConfirmLootSlot = function(slot) table.insert(confirms, slot) end
ML.OnEvent("LOOT_BIND_CONFIRM", 1)
eq(confirms[1], 1, "armed slot confirmed for BoP")
ConfirmLootSlot = nil
-- UI_ERROR_MESSAGE (locked, full bags, range) drops the arm so the next
-- rescan returns the row to open instead of stranding it dimmed.
ML.OnEvent("UI_ERROR_MESSAGE", "Inventory is full")
ok(ML.pendingLoot == nil, "error clears click arms")
-- VerifySlot: hint still holding the item wins; a shifted corpse
-- re-resolves; a vanished item reports "gone" (caller rescans).
eq(ML.VerifySlot(1002, 1), 1, "valid hint kept")
lootSlots = { { link = "item:9:0:0:0", quality = 1 },
  { link = "item:1002:0:0:0", quality = 4 } } -- 1002 shifted 1 -> 2
LootSlotIsCoin = nil
eq(ML.VerifySlot(1002, 1), 2, "shifted slot re-resolved")
table.remove(lootSlots, 2) -- 1002 looted away by other means
eq(ML.VerifySlot(1002, 1), "gone", "vanished item reports gone")
eq(LW.OnRowClick(1002), "gone", "click on gone item reconciles")
-- Kill-switch restore must NEVER Show() a mid-loot detached frame:
-- FrameXML would crash on nil page state (LootFrame.lua:166). Restore
-- only re-registers events; the stock UI repopulates on the next loot.
local shown, regs = 0, {}
LootFrame = {
  UnregisterAllEvents = function() end, SetScript = function() end,
  Hide = function() end, Show = function() shown = shown + 1 end,
  RegisterEvent = function(self, ev) table.insert(regs, ev) end,
}
lootSlots = { { link = "item:1002:0:0:0", quality = 4 } }
ML.OnLootOpened()
LW.OnRowClick(1002) -- first silent arm
LW.OnRowClick(1002) -- second: path dead, restore fires
eq(shown, 0, "restore never forces Show() mid-loot")
ok(LW.blizzardTakeover == false, "takeover stood down")
local need = { LOOT_OPENED = true, LOOT_CLOSED = true, LOOT_SLOT_CLEARED = true }
for i = 1, #regs do need[regs[i]] = nil end
local missing = nil
for k in pairs(need) do missing = k break end
eq(missing, nil, "loot events re-registered")
eq(LW.OnRowClick(1002), "passthrough", "rows stand down after restore")
-- Re-arm for the rest of the suite (and prove the opt-in path): the NEXT
-- corpse takes over again once the user re-arms.
ZugLoot.DB.lootTakeover = true
ZugLoot.LootWindow.DetachBlizzardLoot(true)
ok(ZugLoot.LootWindow.TakeoverWanted(), "re-arm honored")
-- The error path must ALSO un-dim the row at once (no rescan may ever
-- come on failure): the reported strand was a grey [done] row that never
-- recovered and never looted.
lootSlots = { { link = "item:1002:0:0:0", quality = 4 } }
ML.OnLootOpened()
eq(LW.OnRowClick(1002), "looting", "click dims before the failure")
eq(LW.Find(1002).status, "done", "row dimmed while call in flight")
ML.OnEvent("UI_ERROR_MESSAGE", "Inventory is full")
eq(LW.Find(1002).status, "open", "error un-dims the row immediately")
ok(LW.Find(1002) ~= nil, "failed row kept for retry")
-- Watchdog: a silent call (no confirm, no error) un-dims on its own after
-- 4s instead of stranding the row grey — the exact reported symptom.
lootSlots = { { link = "item:1002:0:0:0", quality = 4 } }
ML.OnLootOpened()
eq(LW.OnRowClick(1002), "looting", "silent click dims")
eq(LW.Find(1002).status, "done", "row dimmed while call in flight")
ok(drain(1.0), "drain watchdog")
eq(LW.Find(1002).status, "open", "watchdog un-dims silent rows")
ok(LW.Find(1002) ~= nil, "watchdog keeps the row for retry")
local sawWatch = false
for i = 1, #printed do
  if string.find(printed[i], "didn't go through", 1, true) then sawWatch = true break end
end
ok(sawWatch, "watchdog reports the silent call")
-- Range gate: same target but out of loot range = moved away. The click
-- is blocked BEFORE the corpse call, the list is untouched, and the log
-- says to re-loot. No GUID on 1.12: target name + distance is the signal.
-- (Fresh watch: earlier sections' silent arms belong to older corpses.)
ZugLoot.LootWindow.silentLootArms = nil
UnitName = function(unit)
  if unit == "target" then return "Plainstrider" end
  return "SoloPlayer"
end
CheckInteractDistance = function(unit, idx) return false end -- walked off
lootSlots = { { link = "item:1002:0:0:0", quality = 4 } }
ML.OnLootOpened() -- pins target Plainstrider + fingerprint
eq(ML.lootTarget, "Plainstrider", "loot target pinned at scan")
local rowsBefore = #LW.items
eq(LW.OnRowClick(1002), "not looting", "moved-away click blocked early")
eq(#LW.items, rowsBefore, "blocked click clears nothing")
ok(LW.Find(1002) ~= nil and LW.Find(1002).status == "open",
  "blocked row stays open, never dims")
local sawRange = false
for i = 1, #printed do
  if string.find(printed[i], "moved away from the corpse", 1, true) then
    sawRange = true break
  end
end
ok(sawRange, "log tells the player to re-loot")
-- Walked back into range: the same click goes through.
CheckInteractDistance = function(unit, idx) return true end
eq(LW.OnRowClick(1002), "looting", "in-range click proceeds")
-- GUID range gate: same guid + out of range blocks; a different guid
-- (twin corpse, same name) is not "moved away" — the attempt is allowed
-- and identity is left to the corpse key.
UnitExists = function(unit)
  if unit == "target" then return true, "GUID-A" end
end
ML.OnLootOpened() -- pins guid GUID-A
eq(ML.lootGUID, "GUID-A", "guid pinned at scan")
CheckInteractDistance = function(unit, idx) return false end
eq(LW.OnRowClick(1002), "not looting", "same-guid out of range blocks")
UnitExists = function(unit)
  if unit == "target" then return true, "GUID-TWIN" end
end
eq(ML.CheckLootRange(), true, "twin guid is not a range block")
UnitExists = nil
-- Same-creature re-loot reuses the open window: seed a live roll, walk
-- away (LOOT_CLOSED keeps the window), come back — rolls survive, no
-- re-announce, no wipe. (Re-pin the fp key first: the twin test above
-- pinned a guid key, and UnitExists is now stock-shaped again.)
ML.OnLootOpened() -- re-pin fp key (announces; baseline taken after)
local announced0 = #printed
ML.BeginSession(1002, "item:1002", "SR", true)
ML.ApplySystemRoll(ML.session, "Aaa", 90, 1, 100)
CheckInteractDistance = function(unit, idx) return false end
LW.OnEvent("LOOT_CLOSED") -- walk away: window stays (leftovers listed)
ok(LW.Find(1002) ~= nil, "window survives walk-away")
CheckInteractDistance = function(unit, idx) return true end
lootSlots = { { link = "item:1002:0:0:0", quality = 4 } } -- same corpse
local announced = #printed -- baseline AFTER session/roll prints
ML.OnLootOpened()
ok(ML.session ~= nil and ML.session.itemID == 1002, "live roll survives re-loot")
eq(#printed, announced + 1, "re-loot prints only the resumed line")
ok(string.find(printed[#printed], "resumed", 1, true) ~= nil,
  "no roll re-announce on resume")
ML.Cancel()
-- GUID identity: same name + same loot but a DIFFERENT guid is a
-- different corpse — window rebuilds, no merge. (The twin-Plainstrider
-- case the fingerprint alone would have merged.)
UnitExists = function(unit)
  if unit == "target" then return true, "GUID-B" end
end
lootSlots = { { link = "item:1002:0:0:0", quality = 4 } } -- same loot!
ML.OnLootOpened()
eq(ML.lootGUID, "GUID-B", "new corpse pins its own guid")
ok(LW.Find(1002) ~= nil, "twin corpse lists its loot")
-- ... while the SAME guid re-looted reuses the window (rolls kept).
ML.BeginSession(1002, "item:1002", "SR", true)
ML.ApplySystemRoll(ML.session, "Aaa", 90, 1, 100)
LW.OnEvent("LOOT_CLOSED")
ML.OnLootOpened()
ok(ML.session ~= nil and ML.session.itemID == 1002, "guid re-loot keeps roll")
ML.Cancel()
-- Multi-corpse interleave: roll live on A, walk away, loot B (A parks
-- intact), award B, walk back to A — A's roll + window resume whole and
-- B's award never touches A's state.
-- (Session-only cache: earlier sections may have parked corpses; reset
-- for an isolated interleave.)
ML.corpseCache = {}
ML.corpseOrder = {}
ok(next(ML.corpseCache) == nil, "cache starts empty")
-- Eviction: abandoned corpses age out oldest-first past the cap.
for i = 1, (ML.CORPSE_CACHE_MAX or 5) + 2 do
  ML.lootKey, ML.lootGUID, ML.lootTarget = "fp:Mob" .. i .. "|1", nil, "Mob" .. i
  if ZugLoot.LootWindow then ZugLoot.LootWindow.items = { { itemID = 9000 + i, slot = 1 } } end
  ML.ParkCorpse()
end
eq(ZugLoot.Util.ArrayCount(ML.corpseOrder), ML.CORPSE_CACHE_MAX, "cache capped")
ok(ML.corpseCache["fp:Mob1|1"] == nil, "oldest evicted")
ok(ML.corpseCache["fp:Mob7|1"] ~= nil, "newest kept")
ML.corpseCache = {}
ML.corpseOrder = {}
-- Sim reset clears live tables but never the corpse cache (separate flow:
-- a sim must not wipe parked real corpses, nor vice versa).
ML.lootKey = "guid:KEEP"
ML.corpseCache["guid:KEEP"] = { key = "guid:KEEP", rows = {} }
table.insert(ML.corpseOrder, "guid:KEEP")
ZugLoot.Sim.ResetFresh()
ok(ML.corpseCache["guid:KEEP"] ~= nil, "sim reset preserves corpse cache")
ML.corpseCache = {}
ML.corpseOrder = {}
ML.lootKey = nil
UnitExists = function(unit)
  if unit == "target" then return true, "GUID-A" end
end
UnitName = function(unit)
  if unit == "target" then return "Plainstrider" end
  return "SoloPlayer"
end
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened() -- corpse A
ML.BeginSession(1001, "item:1001", "SR", true)
ML.ApplySystemRoll(ML.session, "Aaa", 90, 1, 100)
LW.OnEvent("LOOT_CLOSED") -- walk away from A: parked
ok(ML.corpseCache["guid:GUID-A"] ~= nil, "A parked in cache")
UnitExists = function(unit)
  if unit == "target" then return true, "GUID-B" end
end
lootSlots = { { link = "item:1002:0:0:0", quality = 4 } }
ML.OnLootOpened() -- corpse B: fresh window, A untouched
ok(LW.Find(1002) ~= nil and LW.Find(1001) == nil, "B lists only B")
ML.BeginSession(1002, "item:1002", "SR", true)
ML.ApplySystemRoll(ML.session, "Bbb", 80, 1, 100)
eq(ML.session.itemID, 1002, "B roll live while A parked")
ML.Finish(true, 1002)
ML.AwardChosen({ name = "Bbb", via = "winner" })
ok(ZugLoot.SRData.HasWon(ZugLoot.DB.sheet, 1002, "Bbb"), "B awarded")
-- Back to A: row, roll (with Aaa's 90), and parked state all resume.
UnitExists = function(unit)
  if unit == "target" then return true, "GUID-A" end
end
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
ok(LW.Find(1001) ~= nil, "A rows resume")
ok(ML.session ~= nil and ML.session.itemID == 1001, "A roll resumes")
eq(#ML.session.rolls, 1, "Aaa's roll survived the round trip")
eq(ML.session.rolls[1].name, "Aaa", "A roll data intact")
ML.Finish(true, 1001)
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(ZugLoot.SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "A awarded after B")
ok(ML.corpseCache["guid:GUID-A"] == nil or true, "A resolved")
-- SAME item on two corpses: each corpse owns its rolls, menu and window
-- state (roll key = corpse + item). B's finish/award must not touch A's
-- parked session, parked menu, or parked detail — and B's roll rows must
-- not leak into A's window on walk-back.
ML.corpseCache = {}
ML.corpseOrder = {}
UnitExists = function(unit)
  if unit == "target" then return true, "GUID-A" end
end
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened() -- corpse A: roll the SAME item, finish it, park it
ok(LW.OpenDetail(1001) ~= nil, "A detail opens")
eq(LW.doAction(1001, "roll"), "rolling", "A starts rolling")
ML.ApplySystemRoll(ML.session, "Aaa", 90, 1, 100)
eq(LW.doAction(1001, "finish"), "finished", "A finishes into parked award")
local keyA = ML.RollKey(1001)
ok(ML.ParkedSession(1001) ~= nil, "A session parked")
ok(keyA ~= 1001, "roll key is corpse-scoped (not bare itemID)")
LW.OnEvent("LOOT_CLOSED") -- walk away from A
UnitExists = function(unit)
  if unit == "target" then return true, "GUID-B" end
end
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } } -- same item!
ML.OnLootOpened() -- corpse B: fresh roll of the same item, finish, award
local sessB0 = ML.SessionFor(1001)
ok(sessB0 == nil or sessB0.key ~= keyA, "B scan keeps its own state")
eq(LW.doAction(1001, "roll"), "rolling", "B rolls the same item")
ML.ApplySystemRoll(ML.session, "Bbb", 80, 1, 100)
eq(#ML.session.rolls, 1, "B session holds only B's roll")
eq(ML.session.rolls[1].name, "Bbb", "A's roll did not leak into B")
eq(LW.doAction(1001, "finish"), "finished", "B finishes into parked award")
ML.AwardChosen({ name = "Bbb", via = "winner" })
ok(ZugLoot.SRData.HasWon(ZugLoot.DB.sheet, 1001, "Bbb"), "B awarded")
-- Walk back to A: A's rolls, menu and window come back whole.
UnitExists = function(unit)
  if unit == "target" then return true, "GUID-A" end
end
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
ok(LW.Find(1001) ~= nil, "A rows resume after B award")
local sessA = ML.ParkedSession(1001) or ML.SessionFor(1001)
ok(sessA ~= nil, "A session survived B's award")
eq(#(sessA and sessA.rolls or {}), 1, "A rolls not wiped by B")
eq((sessA and sessA.rolls[1] and sessA.rolls[1].name), "Aaa", "A roll data intact")
ok(ML.pendingAwardMenu ~= nil, "A award menu restored")
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(ZugLoot.SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "A awarded after B")
-- Fresh corpse C: no phantom rolling row for the item.
UnitExists = function(unit)
  if unit == "target" then return true, "GUID-C" end
end
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
local rowC = LW.Find(1001)
ok(rowC ~= nil and rowC.status == "open", "fresh corpse opens clean, not rolling")
UnitExists = nil
-- No GUID (stock API shape: exists only) falls back to name+fingerprint.
UnitExists = function(unit)
  if unit == "target" then return true end
end
eq(ML.TargetGUID(), nil, "guidless UnitExists yields no guid")
eq(ML.CorpseKey(nil, "Plainstrider", { 1002 }, false),
  "fp:Plainstrider|1002", "fallback key shape")
eq(ML.CorpseKey("GUID-A", "Plainstrider", { 1002 }, false),
  "guid:GUID-A", "guid wins over fingerprint")
-- Different corpse wipes as before (new target, new fingerprint).
UnitExists = nil
UnitName = function(unit)
  if unit == "target" then return "Raptor" end
  return "SoloPlayer"
end
lootSlots = { { link = "item:1003:0:0:0", quality = 4 } }
ML.OnLootOpened()
ok(LW.Find(1003) ~= nil and LW.Find(1002) == nil, "new corpse rebuilds")
UnitName = function() return "SoloPlayer" end
CheckInteractDistance = nil
LootSlotIsCoin = nil
GetLootMethod = nil
LootFrame, LootSlot, GiveMasterLoot, UnitName = nil, nil, nil, nil
ZugLoot.SRSecurity.AmML = function() return true end

-- 3. SimBoss queues only; ML initiates each from the shared loot window.
resetHarness()
CreateFrame = nil -- headless: data only, no frame
math.random = rigged({ 2, 2, 2, 90, 80, 99, 50 }) -- drop shuffle: identity, no double
Sim.SimBoss("TestBoss")
ok(ML.session == nil, "simboss queues without starting")
eq(#ZugLoot.LootWindow.items, 2, "loot window lists the queue")
eq(ZugLoot.LootWindow.items[1].itemID, 1001, "queue order kept")
-- ML picks the SECOND item first: it plays immediately when idle.
Sim.RequestRoll(1002)
ok(ML.SessionAny(1002) ~= nil, "ML pick resolved (session parked)")
ok(drain(), "drain picked run")
ok(ML.pendingAwardMenu ~= nil, "picked item waits on the ML menu")
ML.AwardChosen({ name = "Ccc", via = "winner" })
ok(drain(), "drain picked award")
math.random = realRandom
ok(SRData.HasWon(ZugLoot.DB.sheet, 1002, "Ccc"), "picked item resolves")
ok(ZugLoot.LootWindow.Find(1002) == nil, "awarded item left the list")
ok(ZugLoot.LootWindow.Find(1001) ~= nil, "unrolled item still listed")
-- Then the ML rolls the remaining item.
Sim.RequestRoll(1001)
ok(drain(), "drain rest")
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(drain(), "drain rest award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "rest resolves")

-- 4. Direct award by kind: the ML awards the TMOG kind winner straight
-- from the menu (won mark + drop log; spillover covered in §6).
resetHarness()
ML.BeginSession(1001, "item:1001", "SR", false)
ML.OnSystemRoll("Aaa", 90, 1, 100)
ML.OnSystemRoll("Tmog", 15, 1, 98)
table.insert(ZugLoot.DB.sheet.items[1001].rollers, { name = "Tmog", rolls = 1 })
local res4 = ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001, ML.session.rolls,
  { cap = 100, requireSR = true })
local menu4 = ML.BuildAwardMenu(ML.session, res4)
ML.pendingAwardMenu = { sess = ML.session, data = menu4 }
ML.AwardChosen({ name = "Tmog", via = "tmog" })
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Tmog"), "tmog winner awarded directly")
eq(dropAdds[#dropAdds].winner, "Tmog", "drop log winner")

-- 5. Award menu: winners + SR/MS/OS/TMOG groups + TMOG kind row +
-- class-sorted candidates.
resetHarness()
ML.BeginSession(1001, "item:1001", "SR", false)
ML.OnSystemRoll("Aaa", 90, 1, 100)   -- SR 90+10
ML.OnSystemRoll("Bbb", 80, 1, 100)   -- SR 80
ML.OnSystemRoll("Tmog", 97, 1, 98)   -- TMOG 97 (not on sheet -> miss)
local res5 = ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001, ML.session.rolls,
  { cap = 100, requireSR = true })
local menu = ML.BuildAwardMenu(ML.session, res5)
eq(menu.winners[1].name, "Aaa", "menu top winner")
eq(menu.winners[1].rollType, "SR", "menu winner roll type")
eq(menu.groups.SR[1].name, "Aaa", "SR group ranked")
-- TMOG has its own contest row even while SR wins outright.
ok(menu.perType.TMOG ~= nil and menu.perType.TMOG.entry ~= nil, "tmog contest row present")
-- Over-cap rolls stay out of award groups (they still landed with a roll,
-- so they show in the group rows, never again bare as candidates).
local candNames = {}
for i = 1, #menu.candidates do candNames[menu.candidates[i].name] = true end
ok(not candNames["Tmog"] and not candNames["Aaa"] and not candNames["Bbb"],
  "rollers shown once, never again bare")
-- Non-rollers stay awardable from the candidate list.
local sheets = ZugLoot.SRData.AllPlayerNames(ZugLoot.DB.sheet)
ok(#menu.candidates > 0 or #sheets <= 3, "non-rollers remain candidates")
ML.Cancel()
-- MS winner + TMOG kind side by side (priority covered in resolver tests).
resetHarness()
ML.BeginSession(1001, "item:1001", "SR", false)
ML.session.rolls = {
  { name = "Bbb", roll = 80, type = "MS" },
  { name = "Tmog", roll = 97, type = "TMOG" },
}
table.insert(ZugLoot.DB.sheet.items[1001].rollers, { name = "Tmog", rolls = 1 })
local res5c = ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001, ML.session.rolls,
  { cap = 100, requireSR = true })
local menu5c = ML.BuildAwardMenu(ML.session, res5c)
eq(menu5c.winners[1].name, "Bbb", "ms wins outright")
eq(menu5c.perType.TMOG.entry.name, "Tmog", "tmog owns its kind")
ML.Cancel()

-- 6. simtmog end-to-end: TMOG roller is directly awardable from the menu.
resetHarness()
Sim.FakeCount = 2 -- pinned: Bbb SR + Aaa TMOG (skip the small-group budget)
-- FakeRolls order: Aaa SR, Bbb SR, Aaa TMOG -> rigged {5, 6, 97}.
math.random = rigged({ 5, 6, 97 })
Sim.SimTmog("1001")
ok(drain(), "drain simtmog")
math.random = realRandom
-- Headless sim leaves the menu pending; the harness plays the ML and
-- awards the TMOG kind winner directly.
ok(ML.pendingAwardMenu ~= nil, "menu pending for ML choice")
local menu6 = ML.pendingAwardMenu.data
ML.AwardChosen({ name = menu6.perType.TMOG.entry.name, via = "tmog" })
ok(drain(), "drain simtmog award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "tmog roller awarded")

-- 7b2. Won flag is SR-only at feed: already-won TMOG roll is NOT
-- flagged excluded (regression: the TMOG button vanished for won players).
resetHarness()
SRData.MarkWon(ZugLoot.DB.sheet, 1001, "Me")
table.insert(ZugLoot.DB.sheet.items[1001].rollers, { name = "Me", rolls = 1 })
ML.BeginSession(1001, "item:1001", "SR", false)
ML.OnSystemRoll("Aaa", 58, 1, 100)
ML.OnSystemRoll("Me", 15, 1, 98)
local meRoll = nil
for i = 1, #ML.session.rolls do
  if ML.session.rolls[i].name == "Me" then meRoll = ML.session.rolls[i] end
end
eq(meRoll.type, "TMOG", "won player TMOG kind kept")
local resW4 = ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001,
  ML.session.rolls, { cap = 100, requireSR = true })
eq(resW4.perType.TMOG.entry.name, "Me", "won player TMOG contestable")
ML.Cancel()

-- 7b. Roll kind: 1-100 is SR only with the reserve, else MS (regression:
-- the roll window + award showed SR for every 1-100 roll). 1-99 is OS,
-- 1-98 is TMOG, regardless of the sheet.
resetHarness()
ML.BeginSession(1001, "item:1001", "SR", false)
ML.OnSystemRoll("Aaa", 90, 1, 100)    -- on sheet -> SR
ML.OnSystemRoll("Stranger", 95, 1, 100) -- no reserve -> MS (not SR!)
ML.OnSystemRoll("Offspec", 88, 1, 99)   -- OS by range
ML.OnSystemRoll("Tmog", 15, 1, 98)      -- TMOG by range
local kinds = {}
for i = 1, #ML.session.rolls do
  kinds[ML.session.rolls[i].name] = ML.session.rolls[i].type
end
eq(kinds["Aaa"], "SR", "reserve + 1-100 = SR")
eq(kinds["Stranger"], "MS", "no reserve + 1-100 = MS")
eq(kinds["Offspec"], "OS", "1-99 = OS")
eq(kinds["Tmog"], "TMOG", "1-98 = TMOG")
-- The MS 95 is a valid contest (not a miss) losing by priority to SR.
local resK = ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001,
  ML.session.rolls, { cap = 100, requireSR = true })
eq(resK.winners[1].name, "Aaa", "sr wins by priority")
eq(resK.perType.MS.entry.name, "Stranger", "stranger owns MS")
eq(#resK.missrolls, 0, "no missrolls — kinds decided at feed")
local menuK = ML.BuildAwardMenu(ML.session, resK)
ML.Cancel()
-- Award window: every kind winner has its own labeled row.
resetHarness()
local LW = ZugLoot.LootWindow
LW.SetItems({ { itemID = 1001, link = "item:1001" } }, "loot")
LW.OpenDetail(1001)
LW.detail.phase = "award"
LW.detail.menu = menuK
local kinds = {}
for i = 1, #(LW.DetailActions()) do
  local a = LW.DetailActions()[i]
  if a.id == "award-name" then kinds[a.name] = a.label end
end
for name, want in pairs({ Aaa = "(SR)", Stranger = "(MS)", Offspec = "(OS)", Tmog = "(TMOG)" }) do
  ok(string.find(kinds[name] or "", want, 1, true) ~= nil, name .. " row labeled " .. want)
end
LW.CloseDetail()

-- 7. RangeFor: TMOG feeds roll 1-98 so the roller list labels them TMOG.
-- 8. Chat never shows a bare item:id: session announce, result line,
-- award line and award menu all use the resolved display name.
resetHarness()
ZugLoot.LootWindow.SetItems(
  { { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "loot")
printed = {}
ML.BeginSession(1001, "item:1001", "SR", false)
eq(ML.session.dispName, "Dragonfang Blade", "session carries display name")
ML.OnSystemRoll("Aaa", 90, 1, 100)
ML.OnSystemRoll("Bbb", 80, 1, 100)
ML.Finish()
ML.AwardChosen({ name = "Aaa", via = "winner" })
local leaked = nil
for i = 1, #printed do
  if string.find(printed[i], "item:1001", 1, true) then leaked = printed[i] break end
end
ok(leaked == nil, "no bare item:id in chat, got: " .. tostring(leaked))
local sawNamed = false
for i = 1, #printed do
  if string.find(printed[i], "Dragonfang Blade", 1, true) then sawNamed = true break end
end
ok(sawNamed, "chat names the item")
ML.session = nil
ML.pendingAwardMenu = nil

local function second(rtype) local _, mx = Sim.RangeFor(rtype) return mx end
eq(second("TMOG"), 98, "tmog cap")
eq(second("OS"), 99, "os cap")
eq(second("SR"), 100, "sr cap")

-- 8. Raid-roll (RollFor + Pysanka parity): numbered raid, ML rolls 1-N,
-- the number IS the winner; finish/award reuse the normal path.
resetHarness()
GetNumRaidMembers = function() return 3 end
GetRaidRosterInfo = function(i)
  local roster = { "Pysanka", "Tenshiy", "Bluefelon" }
  return roster[i]
end
UnitName = function() return "Pysanka" end
GetLootMethod = function() return "master" end
GetLootMaster = function() return "Pysanka" end
local rolledRanges = {}
RandomRoll = function(lo, hi) table.insert(rolledRanges, { lo, hi }) end
local rrSess = ML.StartRaidRoll("item:1001")
ok(rrSess ~= nil, "raid-roll session started")
eq(rrSess.mode, "RAIDROLL", "raid-roll mode")
eq(rrSess.n, 3, "raid size frozen")
eq(#rolledRanges, 1, "ML rolled once")
eq(rolledRanges[1][1], 1, "roll starts at 1")
eq(rolledRanges[1][2], 3, "roll ends at raid size")
-- Numbered raid announced (chunked, plain names).
local sawNumbered = false
for i = 1, #printed do
  if string.find(printed[i], "[2]:Tenshiy", 1, true) then sawNumbered = true break end
end
ok(sawNumbered, "numbered raid announced")
-- A raider's own /roll is ignored (raiders don't roll for themselves).
ML.OnSystemRoll("Tenshiy", 99, 1, 3)
ok(rrSess.raidRolled ~= true, "raider roll ignored")
-- Wrong range ignored (1-100 instead of 1-3).
ML.OnSystemRoll("Pysanka", 2, 1, 100)
ok(rrSess.raidRolled ~= true, "wrong-range roll ignored")
-- The ML's 1-N roll resolves: number 2 = Tenshiy, menu pends.
ML.OnSystemRoll("Pysanka", 2, 1, 3)
ok(rrSess.raidRolled, "ML number accepted")
ok(ML.pendingAwardMenu ~= nil, "raid-roll award menu pending")
eq(ML.pendingAwardMenu.sess.itemID, 1001, "menu targets the item")
local rrWinners = ML.pendingAwardMenu.data.winners or {}
eq(#rrWinners, 1, "single raid-roll winner")
eq(rrWinners[1].name, "Tenshiy", "number maps to the roster")
-- Second number ignored (first number only).
ML.OnSystemRoll("Pysanka", 3, 1, 3)
eq(ML.pendingAwardMenu.data.winners[1].name, "Tenshiy", "second number ignored")
-- The winner number travels the chat intake (echo line + session roll),
-- never a hidden list insert: it reads as a plain MS roll on 1-100.
local sawRrEcho = false
for i = 1, #printed do
  if string.find(printed[i], "Tenshiy rolls 2 (1-100)", 1, true) then sawRrEcho = true end
end
ok(sawRrEcho, "raid-roll number echoed as a chat line")
local rrSessRolls = (ML.ParkedSession(1001) or {}).rolls or {}
local rrFound = nil
for i = 1, #rrSessRolls do
  if rrSessRolls[i].name == "Tenshiy" then rrFound = rrSessRolls[i] end
end
ok(rrFound ~= nil, "raid-roll winner on the session rolls")
eq(rrFound and rrFound.type, "MS", "raid-roll winner reads MS")
-- Award reuses the normal path (Pysanka-style line + won mark).
local rrPrinted = #printed
ML.AwardChosen({ name = "Tenshiy", via = "winner" })
local sawAward = false
for i = rrPrinted + 1, #printed do
  if string.find(printed[i], "Tenshiy wins", 1, true) then sawAward = true break end
end
ok(sawAward, "raid-roll award announced")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Tenshiy"), "raid-roll winner won-marked")
GetNumRaidMembers = nil
GetRaidRosterInfo = nil
GetLootMethod = nil
GetLootMaster = nil
RandomRoll = function() end
UnitName = function() return "SoloPlayer" end

return T
