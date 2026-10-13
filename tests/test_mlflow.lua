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
    return values[((i - 1) % #values) + 1]
  end
end
local realRandom = math.random

local function resetHarness(rollTime)
  ZugLoot.Timer.CancelAll()
  Sim.pending = {}
  Sim.running = false
  Sim.auto = false
  Sim.lastEntries = {}
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
math.random = rigged({ 90, 80, 99, 50 })
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
eq(ZugLoot.LootWindow.Find(1002).status, "done", "loot row marked done")
-- Then the ML rolls the remaining item.
Sim.RequestRoll(1001)
ok(drain(), "drain rest")
ML.AwardChosen({ name = "Aaa", via = "winner" })
ok(drain(), "drain rest award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "rest resolves")

-- 4. Direct award by kind: the ML awards the TMOG kind winner straight
-- from the menu (no trade leg — out of scope).
resetHarness()
ML.BeginSession(1001, "item:1001", "SR", false)
ML.OnSystemRoll("Aaa", 90, 1, 100)
ML.OnSystemRoll("Tmog", 15, 1, 98)
table.insert(ZugLoot.DB.sheet.items[1001].rollers, { name = "Tmog", rolls = 1 })
local res4 = ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001, ML.session.rolls,
  { cap = 100, requireSR = true })
local menu4 = ML.BuildAwardMenu(ML.session, res4)
eq(menu4.perType.TMOG.entry.name, "Tmog", "tmog kind winner")
ML.pendingAwardMenu = { sess = ML.session, data = menu4 }
ML.AwardChosen({ name = "Tmog", via = "tmog" })
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Tmog"), "tmog winner awarded directly")
ok(not SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "no spillover mark")
eq(dropAdds[#dropAdds].outcome, "award", "drop log outcome award")
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
-- TMOG has its own contest row even while SR wins outright (directly
-- awardable — no pass-through machinery).
ok(menu.perType.TMOG ~= nil and menu.perType.TMOG.entry ~= nil, "tmog contest row present")
eq(menu.perType.TMOG.entry.name, "Tmog", "tmog contest names the roller")
-- Over-cap rolls (above the TYPE range) stay out of award groups...
local inGroups = false
for _, gt in ipairs({ "SR", "MS", "OS", "TMOG" }) do
  for j = 1, #menu.groups[gt] do
    if menu.groups[gt][j].overCap then inGroups = true end
  end
end
ok(not inGroups, "over-cap rolls stay out of award groups")
-- ...but IS in the class-sorted candidate list (awardable by the ML).
local candNames = {}
for i = 1, #menu.candidates do candNames[menu.candidates[i].name] = true end
ok(candNames["Tmog"] and candNames["Aaa"] and candNames["Bbb"], "candidates cover rollers")
ML.Cancel()
-- TMOG kind winner alongside the MS winner.
resetHarness()
ML.BeginSession(1001, "item:1001", "SR", false)
ML.OnSystemRoll("Aaa", 5, 1, 100)
ML.OnSystemRoll("Bbb", 80, 1, 98) -- feeds as TMOG... use direct rolls instead
ML.session.rolls = {
  { name = "Bbb", roll = 80, type = "MS" },
  { name = "Tmog", roll = 97, type = "TMOG" },
}
-- Tmog is not on the sheet: allow the open shape for this unit check.
local res5b = ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001, ML.session.rolls,
  { cap = 100, requireSR = false })
table.insert(ZugLoot.DB.sheet.items[1001].rollers, { name = "Tmog", rolls = 1 })
local res5c = ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001, ML.session.rolls,
  { cap = 100, requireSR = true })
local menu5c = ML.BuildAwardMenu(ML.session, res5c)
-- Per-type: Bbb wins MS outright (priority), Tmog owns TMOG directly.
eq(menu5c.winners[1].name, "Bbb", "ms wins outright by priority")
eq(menu5c.winners[1].rollType, "MS", "winner kind MS")
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
ok(menu6.perType.TMOG ~= nil and menu6.perType.TMOG.entry ~= nil, "tmog contest present")
ML.AwardChosen({ name = menu6.perType.TMOG.entry.name, via = "tmog" })
ok(drain(), "drain simtmog award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "tmog roller awarded")
ok(not SRData.HasWon(ZugLoot.DB.sheet, 1001, "Bbb"), "no spillover mark")

-- 7. RangeFor: TMOG feeds roll 1-98 so the roller list labels them TMOG.
local function second(rtype) local _, mx = Sim.RangeFor(rtype) return mx end
eq(second("TMOG"), 98, "tmog cap")
eq(second("OS"), 99, "os cap")
eq(second("SR"), 100, "sr cap")

return T
