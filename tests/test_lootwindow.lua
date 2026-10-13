-- tests/test_lootwindow.lua
-- RollFor-style loot window: numbered rows (icon/name/SR-HR badge), and the
-- row detail that STAYS OPEN as the roll window (pick -> rolling -> award):
-- live roll list with kinds, finish-early, award-in-window.
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
-- Bare "1001" links resolve sheet-style; unknown ids fall back cleanly.
local rn, rl, rq, rt = LW.ResolveItemInfo(1001, "1001", 0, nil, nil)
eq(rn .. "|" .. rq .. "|" .. rt, "Dragonfang Blade|4|Interface\\Icons\\INV_Sword_01",
  "name/quality/texture resolved from itemID")
ok(string.find(rl, "Hitem:1001", 1, true) ~= nil, "full link resolved")
LW.SetItems({ { itemID = 1001, link = "1001" } }, "sim")
eq(LW.items[1].name .. "|" .. LW.items[1].texture,
  "Dragonfang Blade|Interface\\Icons\\INV_Sword_01", "sim row resolved")
local tRes = LW.RowText(LW.items[1])
ok(string.find(tRes, "Dragonfang", 1, true) ~= nil
  and string.find(tRes, "item:1001", 1, true) == nil, "row text named, no bare id")
LW.SetItems({ { itemID = 4242, link = "item:4242" } }, "sim")
eq(LW.RowText(LW.items[1]), "1. item:4242", "unknown falls back to item:id")

-- 1. ReserveBadge: HR wins, SR / SR:n, "" when unreserved.
local sheet = makeSheet()
for id, want in pairs({ [1003] = "HR", [1001] = "SR:2", [1002] = "SR", [9999] = "" }) do
  eq(SRData.ReserveBadge(sheet, id), want, "badge " .. id)
end
ok(SRData.IsHardres(sheet, 1003) and not SRData.IsHardres(sheet, 1001)
  and not SRData.IsHardres(nil, 1001), "IsHardres")
eq(table.concat(SRData.SRNames(sheet, 1001), ","), "Aaa,Bbb", "SR names sorted")

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
for i, want in ipairs({ "SR:2", "HR", "" }) do
  eq(LW.items[i].badge, want, "row " .. i .. " badge")
end
local t1 = LW.RowText(LW.items[1])
ok(string.find(t1, "^1%.", 1) ~= nil or string.find(t1, "1.", 1, true) == 1, "row text numbered")
ok(string.find(t1, "SR:2", 1, true) ~= nil, "row text shows badge")
-- legacy sr= input still derives the badge.
for _, tc in ipairs({ { 2, "SR:2" }, { 1, "SR" } }) do
  LW.SetItems({ { itemID = 1001, link = "item:1001", sr = tc[1] } }, "loot")
  eq(LW.items[1].badge, tc[2], "legacy sr=" .. tc[1])
end
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

-- 5. DetailLines render + ... choices + label width (headless parity).
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
local lines = LW.DetailLines()
ok(#lines == 3, "three detail lines")
ok(string.find(lines[1], "SR:2", 1, true) ~= nil, "title carries badge")
ok(string.find(lines[2], "Aaa", 1, true) ~= nil, "rollers listed")
local choices = LW.MoreChoices()
eq(#choices, 3, "roll + two awards")
eq(choices[3].name, "Bbb", "award row carries the name")
ok(string.len("Award ganghorde") * 7 < LW.DETAIL_WIDTH - 60, "detail fits long award labels")

-- 6. Persistent roll window: pick -> rolling -> award in ONE window.
-- Roll from the detail: it stays open and tracks the session.
ZugLoot.DB = { sheet = makeSheet() }
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
local liveSessions = {}
ML.StartItemRoll = function(id)
  table.insert(liveSessions, id)
  ML.session = { id = 7, itemID = id, itemLink = "item:" .. id, mode = "SR",
    rolls = {}, itemCount = 1 }
end
ML.FinishEarly = function() ML.Finish(true) end
eq(LW.doAction(1001, "roll"), "rolling", "roll starts from detail")
ok(LW.detail ~= nil, "detail STAYS OPEN on roll (not closed)")
eq(LW.detail.phase, "rolling", "detail phase rolling")
eq(LW.detail.sessionID, 7, "detail tracks the session")
-- Rolls land with their kind; first-roll-only; foreign sessions ignored.
ok(LW.DetailOnRoll(1001, 7, "Aaa", 90, "SR", 100), "SR roll lands")
ok(LW.DetailOnRoll(1001, 7, "Bbb", 80, "MS", 80), "MS roll lands")
ok(LW.DetailOnRoll(1001, 7, "Oz", 97, "TMOG", 97), "TMOG roll lands")
ok(not LW.DetailOnRoll(1001, 7, "Aaa", 50, "SR", 60), "second roll ignored")
ok(not LW.DetailOnRoll(1001, 999, "Eve", 50, "SR", 50), "foreign session ignored")
ok(not LW.DetailOnRoll(1002, 7, "Eve", 50, "SR", 50), "other item ignored")
local rl = LW.DetailLines()
local sawSR, sawMS, sawTM = false, false, false
for i = 1, #rl do
  if string.find(rl[i], "SR: Aaa 90", 1, true) then sawSR = true end
  if string.find(rl[i], "MS: Bbb 80", 1, true) then sawMS = true end
  if string.find(rl[i], "TMOG: Oz 97", 1, true) then sawTM = true end
end
ok(sawSR and sawMS and sawTM, "roll list shows every roll with its kind")
-- Sorted SR > MS > OS > TMOG regardless of feed order.
local sorted = LW.SortedDetailRolls()
eq(sorted[1].rollType, "SR", "SR first")
eq(sorted[#sorted].rollType, "TMOG", "TMOG last")
-- Detail actions while rolling: Finish / Cancel / Close (no Award/...).
local racts = LW.DetailActions()
eq(racts[1].id, "finish", "rolling offers Finish")
eq(racts[2].id, "cancel", "rolling offers Cancel")
-- A second roll while one is live is refused, window untouched.
ML.session = { id = 7, itemID = 1001 }
eq(LW.doAction(1001, "roll"), "roll failed", "second roll refused")
eq(LW.detail.phase, "rolling", "phase untouched by refused roll")
ML.session = nil
-- Finish: the same window becomes the award window (menu handed over).
local menu6 = ML.BuildAwardMenu(
  { itemID = 1001, itemLink = "item:1001", id = 7 },
  ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001,
    { { name = "Aaa", roll = 90, type = "SR" },
      { name = "Bbb", roll = 80, type = "MS" } },
    { cap = 100, requireSR = true }))
ok(LW.DetailOnFinish(1001, menu6), "finish hands menu to detail")
eq(LW.detail.phase, "award", "detail phase award")
ok(LW.detail ~= nil, "same window awards (not a new one)")
local al = LW.DetailLines()
local sawWinner = false
for i = 1, #al do
  if string.find(al[i], "winner: Aaa", 1, true) then sawWinner = true end
end
ok(sawWinner, "award window names the winner with kind")
local aacts = LW.DetailActions()
eq(aacts[1].id, "award-name", "award offers winner rows")
eq(aacts[1].name, "Aaa", "top winner first")
-- Award from the window: the rolled-award path (menu confirm). The real
-- AwardChosen marks done + closes; emulate the harness playing the ML.
local pickName = aacts[1].name
ML.pendingAwardMenu = { sess = { itemID = 1001, itemLink = "item:1001",
    id = 7, silent = false, itemCount = 1 }, data = menu6 }
ML.AwardChosen = function(choice)
  SRData.MarkWon(ZugLoot.DB.sheet, 1001, choice.name)
  LW.MarkDone(1001)
  ML.pendingAwardMenu = nil
  ML.session = nil
  LW.CloseDetail()
end
eq(LW.doAction(1001, "award-name", pickName), "awarded Aaa", "award in window")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "window award won-marks")
eq(LW.Find(1001).status, "done", "row done after window award")
ok(LW.detail == nil, "window closed after award")

-- 6b. TMOG 15 vs SR 58: SR wins outright; the TMOG kind row awards the
-- TMOG roller directly (no trade leg — out of scope).
ZugLoot.DB = { sheet = makeSheet() }
table.insert(ZugLoot.DB.sheet.items[1001].rollers, { name = "Tmog", rolls = 1 })
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
local menuT = ML.BuildAwardMenu(
  { itemID = 1001, itemLink = "item:1001", id = 9 },
  ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001,
    { { name = "Aaa", roll = 58, type = "SR" },
      { name = "Tmog", roll = 15, type = "TMOG" } },
    { cap = 100, requireSR = true }))
eq(menuT.winners[1].name, "Aaa", "sr wins outright by priority")
eq(menuT.perType.TMOG.entry.name, "Tmog", "tmog owns its kind")
ok(LW.DetailOnFinish(1001, menuT), "tmog finish to detail")
local tmogRow = nil
for i = 1, #(LW.DetailActions()) do
  local a = LW.DetailActions()[i]
  if a.via == "tmog" then tmogRow = a break end
end
ok(tmogRow ~= nil and tmogRow.name == "Tmog", "TMOG kind row present")
-- TMOG kind award via the window: direct, no leg, window closes.
local gotTmog = nil
ML.pendingAwardMenu = { sess = { itemID = 1001, itemLink = "item:1001",
    id = 9, silent = false, itemCount = 1 }, data = menuT }
ML.AwardChosen = function(choice)
  gotTmog = choice
  SRData.MarkWon(ZugLoot.DB.sheet, 1001, choice.name)
  LW.MarkDone(1001)
  ML.pendingAwardMenu = nil
  LW.CloseDetail()
end
eq(LW.doAction(1001, "award-name", { name = tmogRow.name, via = tmogRow.via }),
  "awarded Tmog", "tmog kind award from window")
eq(gotTmog.via, "tmog", "tmog via forwarded")
eq(gotTmog.name, "Tmog", "tmog recipient forwarded")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Tmog"), "tmog winner marked")
ok(not SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "no spillover mark")
ok(LW.detail == nil, "window closed after tmog award")

-- 6c. Confirm popup shows the item NAME (regression: "Award item:<id>").
-- Restores the real AwardChosen afterwards (§6b stubbed it).
dofile("MasterLootUI.lua")
ML = ZugLoot.MasterLootUI
StaticPopupDialogs = {}
StaticPopup_Show = function(name) return name end
LW.SetItems({ { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "loot")
ML.pendingAwardMenu = { sess = { itemID = 1001, itemLink = "item:1001",
    id = 10, silent = false, itemCount = 1 },
  data = { winners = { { name = "Aaa" } },
    itemID = 1001, itemLink = "item:1001" } }
ML.AwardChosen({ name = "Aaa", via = "winner" })
local ctext = StaticPopupDialogs["ZUGLOOT_AWARD"].text
ok(string.find(ctext, "Dragonfang Blade", 1, true) ~= nil,
  "confirm shows item name, got: " .. tostring(ctext))
ok(not string.find(ctext, "item:1001", 1, true),
  "confirm hides item:id, got: " .. tostring(ctext))
StaticPopupDialogs = nil
StaticPopup_Show = nil

-- 7. Cancel drops a rolling detail back to pick (re-roll / choose / close).
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
ML.session = { id = 8, itemID = 1001, silent = false }
LW.detail.phase = "rolling"
LW.detail.sessionID = 8
LW.DetailOnRoll(1001, 8, "Aaa", 90, "SR", 100)
ML.Cancel = function()
  ML.session = nil
  LW.MarkOpen(1001)
  -- mirror of MasterLootUI.Cancel's detail reset (headless ML stub)
  if LW.detail and LW.detail.itemID == 1001 and LW.detail.sessionID == 8 then
    LW.detail.phase = "pick"
    LW.detail.sessionID = nil
    LW.detail.rolls = {}
    LW.detail.menu = nil
    LW.detail.status = "open"
    LW.RefreshDetail()
  end
end
eq(LW.doAction(1001, "cancel"), "cancelled", "cancel from window")
eq(LW.detail.phase, "pick", "detail back to pick after cancel")
eq(#LW.detail.rolls, 0, "rolls cleared after cancel")
ok(LW.detail ~= nil, "window stays for re-roll choice")

-- 8. Flow layout: one row when wide, wrap when narrow, justified.
-- Wide bar: all four share one justified row (even side margins).
local wide = LW.LayoutBarRows({
  { btn = "a", w = 80 }, { btn = "b", w = 80 },
  { btn = "c", w = 44 }, { btn = "d", w = 60 },
}, 300)
eq(#wide, 1, "wide bar: one row")
eq(#wide[1], 4, "wide bar: all four placed")
-- total 264, space (300-264)/5 = 7.2: first starts at 7.2, last ends 292.8
local first, last = wide[1][1], wide[1][4]
ok(math.abs(first.x - 7.2) < 0.01, "row justified left margin")
ok(math.abs((last.x + last.w) - 292.8) < 0.01, "row justified right margin")
-- Narrow bar (the 320 frame => 300 usable is wide; force narrow): TMOG
-- wraps above instead of overlapping .../Close.
local narrow = LW.LayoutBarRows({
  { btn = "a", w = 150 }, { btn = "b", w = 150 },
  { btn = "c", w = 44 }, { btn = "d", w = 60 },
}, 300)
eq(#narrow, 2, "narrow bar: wraps to two rows")
eq(#narrow[1], 1, "first row holds the wide primary alone")
eq(narrow[2][1].btn, "b", "TMOG floats to the next row, not over ...")
return T
