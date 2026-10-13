-- tests/test_lootwindow.lua
-- RollFor-style loot window: numbered rows (icon/name/SR-HR badge),
-- row detail (direct Award on single SR/HR, "..." choices, Close).
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
time = time or os.time
CreateFrame = nil -- headless: data layer only

local awarded = {}
ZugLoot.SRSecurity = { AmML = function() return true end,
  IsInRaid = function() return false end, IsInGroup = function() return false end,
  IsSolo = function() return true end }
ZugLoot.DropLog = { Add = function() end }
ZugLoot.Comm = { BroadcastAward = function() end,
  WarnGroup = function(m) table.insert(printed, m) end,
  SayGroup = function(m) table.insert(printed, m) end }

dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")
local LW = ZugLoot.LootWindow
local ML = ZugLoot.MasterLootUI
local SRData = ZugLoot.SRData

local function makeSheet()
  local s = SRData.NewSheet()
  s.items[1001] = { quality = 4, rollers = {
    { name = "Aaa", rolls = 1, sr_plus = 10 },
    { name = "Bbb", rolls = 2, sr_plus = nil },
  } }
  s.items[1002] = { quality = 4, rollers = {
    { name = "Solo", rolls = 1, sr_plus = nil },
  } }
  s.hardres[1003] = { quality = 5 }
  return s
end

-- 0. Client-like GetItemInfo: sheet-style name/link/quality/texture.
-- Sim rows carry bare "1001" links — resolution must still yield the
-- sheet-style presentation (regression: rows showed "item:<id>", no icon).
GetItemInfo = function(id)
  local db = { [1001] = { "Dragonfang Blade", "|cffa335ee|Hitem:1001:0:0:0|h[Dragonfang Blade]|h|r", 4, "Interface\\Icons\\INV_Sword_01" },
    [1002] = { "Healing Potion", "|cff1eff00|Hitem:1002:0:0:0|h[Healing Potion]|h|r", 2, "Interface\\Icons\\INV_Potion_01" } }
  local e = db[tonumber(id)]
  if not e then return nil end
  return e[1], e[2], e[3], 1, 1, "", "", "", e[4]
end
local rn, rl, rq, rt = LW.ResolveItemInfo(1001, "1001", 0, nil, nil)
eq(rn, "Dragonfang Blade", "name resolved from itemID")
eq(rl, "|cffa335ee|Hitem:1001:0:0:0|h[Dragonfang Blade]|h|r", "full link resolved")
eq(rq, 4, "quality resolved")
eq(rt, "Interface\\Icons\\INV_Sword_01", "texture resolved")
LW.SetItems({ { itemID = 1001, link = "1001" } }, "sim")
eq(LW.items[1].name, "Dragonfang Blade", "sim row named via GetItemInfo")
eq(LW.items[1].texture, "Interface\\Icons\\INV_Sword_01", "sim row icon via GetItemInfo")
local tRes = LW.RowText(LW.items[1])
ok(string.find(tRes, "Dragonfang", 1, true) ~= nil, "resolved row text named")
ok(string.find(tRes, "item:1001", 1, true) == nil, "no bare item:id text")
-- Unknown item (no cache): graceful fallback, question-mark icon path.
LW.SetItems({ { itemID = 4242, link = "item:4242" } }, "sim")
eq(LW.items[1].name, nil, "unknown keeps no name")
eq(LW.RowText(LW.items[1]), "1. item:4242", "unknown falls back to item:id")
-- Done-row re-append keeps the resolved presentation.
LW.SetItems({ { itemID = 1001, link = "1001" } }, "sim")
ZugLoot.Sim = ZugLoot.Sim or {}
ZugLoot.Sim.doneRows = { [1001] = { itemID = 1001,
  link = "|cffa335ee|Hitem:1001:0:0:0|h[Dragonfang Blade]|h|r",
  name = "Dragonfang Blade", texture = "Interface\\Icons\\INV_Sword_01",
  quality = 4, badge = "SR", status = "done", source = "sim" } }
LW.SetItems({}, "sim")
for id, prev in pairs(ZugLoot.Sim.doneRows) do
  if not LW.Find(id) then
    table.insert(LW.items, { itemID = id, link = prev.link, name = prev.name,
      texture = prev.texture, quality = prev.quality, badge = prev.badge,
      status = "done", source = "sim" })
  end
end
eq(LW.items[1].name, "Dragonfang Blade", "re-appended row keeps name")
eq(LW.items[1].texture, "Interface\\Icons\\INV_Sword_01", "re-appended row keeps icon")
ZugLoot.Sim.doneRows = nil

-- 1. ReserveBadge: HR wins, SR / SR:n, "" when unreserved.
local sheet = makeSheet()
eq(SRData.ReserveBadge(sheet, 1003), "HR", "hardres badge")
eq(SRData.ReserveBadge(sheet, 1001), "SR:2", "two holders")
eq(SRData.ReserveBadge(sheet, 1002), "SR", "single holder")
eq(SRData.ReserveBadge(sheet, 9999), "", "unreserved blank")
ok(SRData.IsHardres(sheet, 1003), "IsHardres true")
ok(not SRData.IsHardres(sheet, 1001), "IsHardres false")
ok(not SRData.IsHardres(nil, 1001), "IsHardres nil-safe")
local names = SRData.SRNames(sheet, 1001)
eq(#names, 2, "two SR names")
eq(names[1], "Aaa", "SR names sorted")

-- 1b. DisplayName / TooltipLink (RollFor ItemUtils parity): the row shows
-- the readable name, never the raw link; tooltips use the item: part.
eq(LW.DisplayName({ itemID = 17182, link = "|cffa335ee|Hitem:17182:0:0:0|h[Sulfuras]|h|r" }),
  "Sulfuras", "name parsed from link")
eq(LW.DisplayName({ itemID = 5, name = "Slot Name", link = "item:5" }),
  "Slot Name", "slot name preferred")
eq(LW.DisplayName({ itemID = 7 }), "item:7", "itemID fallback")
eq(LW.TooltipLink({ itemID = 17182, link = "|cffa335ee|Hitem:17182:0:0:0|h[Sulfuras]|h|r" }),
  "item:17182:0:0:0", "tooltip link extracted")
eq(LW.TooltipLink({ itemID = 8 }), "item:8:0:0:0", "tooltip link synthesized")

-- 2. Rows: numbered, badge from SetItems, RowText mirrors the paint.
ZugLoot.DB = { sheet = sheet }
LW.SetItems({
  { itemID = 1001, link = "item:1001", quality = 4, badge = SRData.ReserveBadge(sheet, 1001) },
  { itemID = 1003, link = "item:1003", quality = 5, badge = SRData.ReserveBadge(sheet, 1003) },
  { itemID = 9999, link = "item:9999", quality = 3, badge = SRData.ReserveBadge(sheet, 9999) },
}, "loot")
eq(#LW.items, 3, "three rows")
eq(LW.items[1].index, 1, "row 1 numbered")
eq(LW.items[3].index, 3, "row 3 numbered")
eq(LW.items[1].badge, "SR:2", "row 1 badge")
eq(LW.items[2].badge, "HR", "row 2 badge")
eq(LW.items[3].badge, "", "row 3 badge blank")
local t1 = LW.RowText(LW.items[1])
ok(string.find(t1, "^1%.", 1) ~= nil or string.find(t1, "1.", 1, true) == 1, "row text numbered")
ok(string.find(t1, "SR:2", 1, true) ~= nil, "row text shows badge")
-- legacy sr= input still derives the badge.
LW.SetItems({ { itemID = 1001, link = "item:1001", sr = 2 } }, "loot")
eq(LW.items[1].badge, "SR:2", "legacy sr count derives badge")
LW.SetItems({ { itemID = 1001, link = "item:1001", sr = 1 } }, "loot")
eq(LW.items[1].badge, "SR", "legacy single derives SR")
-- RowText shows the display name, not the raw link.
LW.SetItems({ { itemID = 17182,
  link = "|cffa335ee|Hitem:17182:0:0:0|h[Sulfuras]|h|r", badge = "SR" } }, "loot")
local tName = LW.RowText(LW.items[1])
ok(string.find(tName, "Sulfuras", 1, true) ~= nil, "row text shows item name")
ok(string.find(tName, "|Hitem:", 1, true) == nil, "row text hides the raw link")

-- 3. Row detail, single holder: Award direct, ... lists, Close dismisses.
LW.SetItems({
  { itemID = 1002, link = "item:1002", quality = 4, badge = "SR" },
  { itemID = 1001, link = "item:1001", quality = 4, badge = "SR:2" },
}, "loot")
local d = LW.OpenDetail(1002)
ok(d ~= nil, "detail opens")
eq(d.single, true, "single holder flagged")
eq(d.rollers[1], "Solo", "single holder named")
local acts = LW.DetailActions(d)
eq(acts[1].id, "award", "Award first on single")
eq(acts[2].id, "more", "... second")
eq(acts[3].id, "close", "Close last")
-- direct award: won mark + row done + detail closed, no session.
eq(LW.doAction(1002, "award"), "awarded Solo", "direct award returns")
ok(SRData.HasWon(sheet, 1002, "Solo"), "direct award won-marks")
eq(LW.Find(1002).status, "done", "awarded row done")
ok(LW.detail == nil, "detail closed after award")
ok(ML.session == nil, "direct award starts no session")
-- multi holder: no direct Award, ... offers the choice list.
local d2 = LW.OpenDetail(1001)
eq(d2.single, false, "multi holder not single")
local acts2 = LW.DetailActions(d2)
eq(acts2[1].id, "more", "multi starts at ...")
eq(LW.doAction(1001, "award"), "needs choice (...)", "multi award refused")
local more = LW.doAction(1001, "more")
ok(type(more) == "table" and #more >= 3, "... lists choices")
eq(LW.doAction(1001, "close"), "closed", "Close dismisses")
ok(LW.detail == nil, "detail closed, overview kept")
-- award-name from the More list awards a named raider directly.
LW.OpenDetail(1001)
eq(LW.doAction(1001, "award-name", "Aaa"), "awarded Aaa", "named award")
ok(SRData.HasWon(sheet, 1001, "Aaa"), "named award won-marks")
-- unknown item / action are safe.
ok(LW.OpenDetail(4242) == nil, "unknown item no detail")
eq(LW.doAction(4242, "award"), "unknown item", "unknown item safe")

-- 4. Roll initiation still flows from the detail (sim + live sources).
local rolled = {}
ZugLoot.Sim = { RequestRoll = function(id) table.insert(rolled, "sim:" .. id) end }
local started = {}
ML.StartItemRoll = function(id) table.insert(started, "live:" .. tostring(id)) end
LW.SetItems({ { itemID = 2001, link = "item:2001" } }, "sim")
eq(LW.doAction(2001, "roll"), "rolling", "sim roll from detail")
eq(rolled[1], "sim:2001", "sim RequestRoll called")
LW.SetItems({ { itemID = 2002, link = "item:2002" } }, "loot")
eq(LW.doAction(2002, "roll"), "rolling", "live roll from detail")
eq(started[1], "live:2002", "live StartItemRoll called")

-- 4b. MoreChoices: Roll + one Award row per reserver (the "..." menu).
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
local choices = LW.MoreChoices()
eq(#choices, 3, "roll + two awards")
eq(choices[1].id, "roll", "first choice rolls")
eq(choices[2].label, "Award Aaa", "award row labeled")
eq(choices[3].name, "Bbb", "award row carries the name")
-- Award button fits "Award ganghorde" on one line (regression: the name
-- wrapped onto its own line in a 260-wide detail).
ok(string.len("Award ganghorde") * 7 < LW.DETAIL_WIDTH - 60, "detail fits long award labels")
LW.CloseDetail()

-- 5. DetailLines render (headless parity with the client frame).
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
local lines = LW.DetailLines()
ok(#lines == 3, "three detail lines")
ok(string.find(lines[1], "SR:2", 1, true) ~= nil, "title carries badge")
ok(string.find(lines[2], "Aaa", 1, true) ~= nil, "rollers listed")

return T
