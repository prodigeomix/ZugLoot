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
ZugLoot.BossData = { TestBoss = { 1001, 1002 } }
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
  Sim.doneRows = {}
  Sim.pendingAward = nil
  ML.session = nil
  ML.pendingAwardMenu = nil
  ZugLoot.LootWindow.Clear()
  printed, dropAdds, chatSent, shownItems = {}, {}, {}, {}
  grouping = "solo"
  lootSlots = {}
  ZugLoot.DB = { sheet = makeSheet(), rollTime = rollTime or 2 }
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
local cclass = {}
for i = 1, #menu2b.candidates do cclass[menu2b.candidates[i].name] = menu2b.candidates[i].class end
eq(cclass["Aaa"], "Paladin", "sheet fallback class on candidate")
eq(cclass["Bbb"], "Mage", "sheet fallback class on candidate")
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
eq(#ZugLoot.LootWindow.items, 2, "loot window lists both drops")
eq(ZugLoot.LootWindow.items[1].status, "open", "first drop open")
eq(ZugLoot.LootWindow.items[1].badge, "SR:2", "SR count badge")
local sawLoot = false
for i = 1, #printed do
  if string.find(printed[i], "ZugLoot loot: item:1002") then sawLoot = true end
end
ok(sawLoot, "second item announced")
-- ML initiates from the window; unknown items are refused.
ML.StartItemRoll(1001)
ok(ML.session ~= nil, "ML-initiated session live")
eq(ML.session.itemID, 1001, "correct item rolling")
ML.Cancel()
ML.StartItemRoll(4242)
ok(ML.session == nil, "unknown item refused")

-- 2. Non-ML never starts sessions from corpse loot.
resetHarness()
ZugLoot.SRSecurity.AmML = function() return false end
lootSlots = { { link = "item:1001:0:0:0", quality = 4 } }
ML.OnLootOpened()
ok(ML.session == nil, "raider ignores corpse loot")
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
ok(ML.session ~= nil and ML.session.itemID == 1002, "ML pick plays now")
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
-- Over-cap rolls stay out of award groups but remain candidates.
local candNames = {}
for i = 1, #menu.candidates do candNames[menu.candidates[i].name] = true end
ok(candNames["Tmog"] and candNames["Aaa"] and candNames["Bbb"], "candidates cover rollers")
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
-- rollers: Aaa(SR), Bbb(MS-converted); Aaa rolls TMOG high.
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

return T
