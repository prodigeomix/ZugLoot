-- tests/test_lootwindow.lua
-- Raider-style loot window: icon/name/SR-HR rows (no numbers), and the
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
-- Headless corpse session: rows imply an open corpse (the detail Award
-- button only exists on scanned rows). Closed-loot blocking is covered
-- in test_mlflow; here the session stays open unless a test closes it.
ML.lootOpen = true

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
eq(LW.RowText(LW.items[1]), "item:4242", "unknown falls back to item:id")

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
-- BuildLink: real clickable link from parts (RollFor parity) — used when
-- the cache has no full link but the name is known (uncached sheet items).
local builtHex = string.match(LW.BuildLink(17063, "Thunderfury", 5) or "", "^(|c%x+)")
ok(builtHex ~= nil, "built link has color prefix")
eq(LW.BuildLink(17063, "Thunderfury", 5), builtHex .. "|Hitem:17063:0:0:0|h[Thunderfury]|h|r", "built link shape")
eq(LW.BuildLink(8, nil, 4), nil, "no name, no link")
-- ResolveItemInfo upgrades bare ids to full links when the name is known.
-- (Cache cold: stub misses 17063, so no full link comes from GetItemInfo.)
local bn, bl = LW.ResolveItemInfo(17063, "item:17063:0:0:0", 5, nil, "Thunderfury")
ok(bl and string.find(bl, "|Hitem:17063", 1, true) ~= nil, "bare id upgraded to full link, got: " .. tostring(bl))

-- 2. Rows: icon/name/badge (no numbers), RowText mirrors the paint.
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
ok(string.find(t1, "^1%.") == nil, "row text unnumbered (raider style)")
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
-- direct award: won mark + row GONE + detail closed, no session.
eq(LW.doAction(1002, "award"), "awarded Solo", "direct award returns")
ok(SRData.HasWon(sheet, 1002, "Solo"), "direct award won-marks")
ok(LW.Find(1002) == nil, "awarded row left the list")
ok(LW.Find(1001) ~= nil, "unawarded row still listed")
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
-- roll + raid-roll + two reserve awards + the class-grouped REST of the
-- roster (Solo, reserved on 1002) for direct pre-roll awards.
eq(#choices, 5, "roll + raid-roll + two awards + class group")
eq(choices[1].id, "roll", "first choice is SR roll")
eq(choices[2].id, "raidroll", "second choice is raid-roll")
eq(choices[4].name, "Bbb", "award row carries the name")
eq(choices[5].id, "class", "rest of roster groups by class")
eq(choices[5].members[1].name, "Solo", "group member awards directly")
-- Class groups never duplicate the labeled top-level rows.
local topSeen = {}
for i = 1, #choices do
  local c = choices[i]
  if c.id == "award-name" then topSeen[c.name] = true end
end
local grpDup = nil
for i = 1, #choices do
  local c = choices[i]
  if c.id == "class" then
    for m = 1, #c.members do
      if topSeen[c.members[m].name] then grpDup = c.members[m].name end
    end
  end
end
eq(grpDup, nil, "class groups add nobody twice")
-- A grouped member awards directly (no roll): same path as a bare name.
local soloWonBefore = SRData.HasWon(ZugLoot.DB.sheet, 1001, "Solo")
eq(LW.doAction(1001, "award-name", "Solo"), "awarded Solo", "grouped member direct award")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Solo") and not soloWonBefore, "grouped award won-marks")
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
ok(LW.DETAIL_WIDTH == 220, "raider-style detail width")
-- Detail auto-height: frame grows one line per roll, never shrinks
-- below the old fixed 250, capped for huge raids.
eq(LW.DetailHeight(0, 1), 250, "empty window keeps old height")
eq(LW.DetailHeight(7, 1), 250, "small rolls keep old height")
ok(LW.DetailHeight(10, 1) > 250, "10 rolls grow the window")
eq(LW.DetailHeight(10, 1) - LW.DetailHeight(9, 1), 12, "one line per roll")
ok(LW.DetailHeight(40, 1) <= LW.DETAIL_MAX_H, "40-man list capped")

-- 6. Persistent roll window: pick -> rolling -> award in ONE window.
-- Roll from the detail: it stays open and tracks the session.
ZugLoot.DB = { sheet = makeSheet() }
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
local liveSessions = {}
ML.StartItemRoll = function(id)
  table.insert(liveSessions, id)
  ML.sessions = ML.sessions or {}
  ML.sessions[id] = { id = 7, itemID = id, itemLink = "item:" .. id, mode = "SR",
    rolls = {}, itemCount = 1 }
  ML.session = ML.sessions[id]
end
ML.FinishEarly = function(itemID)
  ML.Finish(true, itemID)
end
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
-- Each roll shows the max of the /roll command used (56/98 TMOG style).
local rlRange = LW.DetailLines()
local sawR, sawT = false, false
for i = 1, #rlRange do
  if string.find(rlRange[i], "SR: Aaa 90/100", 1, true) then sawR = true end
  if string.find(rlRange[i], "TMOG: Oz 97", 1, true)
      and string.find(rlRange[i], "/98", 1, true) then sawT = true end
end
ok(sawR and sawT, "rolls show with max of command used")
eq(LW.RollRangeText({ roll = 56, rollType = "TMOG", max = 98 }), "56/98", "tmog range")
eq(LW.RollRangeText({ roll = 90, rollType = "SR", max = 100, effective = 100 }),
  "90/100 (=100)", "sr bonus past base kept")
eq(LW.RollRangeText({ roll = 90, rollType = "SR" }), "90/100", "kind cap fallback")
-- Sorted SR > MS > OS > TMOG regardless of feed order.
local sorted = LW.SortedDetailRolls()
eq(sorted[1].rollType, "SR", "SR first")
eq(sorted[#sorted].rollType, "TMOG", "TMOG last")
-- Detail actions while rolling: Finish / Cancel / Close (no Award/...).
local racts = LW.DetailActions()
eq(racts[1].id, "finish", "rolling offers Finish")
eq(racts[2].id, "cancel", "rolling offers Cancel")
-- A second roll of the SAME item while its session is live is refused.
ML.sessions = { [1001] = { id = 7, itemID = 1001 } }
ML.session = ML.sessions[1001]
eq(LW.doAction(1001, "roll"), "roll failed", "same-item reroll refused")
eq(LW.detail.phase, "rolling", "phase untouched by refused roll")
eq(LW.ParkedDetail(1001), nil, "refused reroll parks nothing new")
-- 6a. SEQUENTIAL HOLDS: while A's roll runs, B's roll is refused.
-- Roll A, then hold it (Finish parks it for award), then roll B.
LW.SetItems({
  { itemID = 1001, link = "item:1001", badge = "SR:2" },
  { itemID = 1002, link = "item:1002", badge = "SR" },
}, "loot")
ML.sessions = {}
ML.parkedSessions = nil
ML.session = nil
LW.OpenDetail(1001)
eq(LW.doAction(1001, "roll"), "rolling", "A starts its own session")
LW.OpenDetail(1002)
ok(LW.ParkedDetail(1001) ~= nil, "A parked when B opened")
eq(LW.doAction(1002, "roll"), "roll failed", "B refused while A runs")
-- Hold A (Finish parks it for award), then B rolls.
LW.OpenDetail(1001)
eq(LW.doAction(1001, "finish"), "finished", "A finished, parked for award")
ok(ML.sessions[1001] == nil, "A session parked out of live table")
ok(ML.ParkedSession(1001) ~= nil, "A session kept for award/continue")
LW.OpenDetail(1002)
eq(LW.doAction(1002, "roll"), "rolling", "B rolls while A parked")
ok(ML.sessions[1002] ~= nil, "B session tracked")
-- Rolls still land on the right item (open vs parked).
ok(LW.DetailOnRoll(1002, 7, "Solo", 70, "SR", 70), "B roll lands open")
ok(LW.ParkedDetail(1001) ~= nil, "A detail parked on switch")
-- Award B: list + parked A intact.
ML.session = ML.sessions[1002]
LW.RemoveItem(1002)
ML.sessions[1002] = nil
ML.session = nil
ok(LW.Find(1002) == nil, "B awarded and gone")
ok(ML.ParkedSession(1001) ~= nil, "A session untouched by B award")
-- Back to item 1: reopen shows A's parked award rows (preaward phase).
local rBack = LW.OpenDetail(1001)
ok(rBack ~= nil and rBack.phase == "preaward", "A reopens parked for award")
ML.sessions = {}
ML.session = nil
-- Finish: the same window becomes the award window (menu handed over).
local menu6 = ML.BuildAwardMenu(
  { itemID = 1001, itemLink = "item:1001", id = 7 },
  ZugLoot.Resolver.ResolveItem(ZugLoot.DB.sheet, 1001,
    { { name = "Aaa", roll = 90, type = "SR" },
      { name = "Bbb", roll = 80, type = "MS" } },
    { cap = 100 }))
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
-- Award ... lists each roller once (with their roll above): no bare
-- duplicate of a name already shown with a roll.
local seenNames, dupName = {}, nil
for i = 1, #LW.MoreChoices() do
  local c = LW.MoreChoices()[i]
  if c.name then
    if seenNames[c.name] then dupName = c.name end
    seenNames[c.name] = true
  end
end
eq(dupName, nil, "award ... shows nobody twice")
local rolledNames = {}
for i = 1, #LW.detail.rolls do rolledNames[LW.detail.rolls[i].name] = true end
local bareDup = nil
for i = 1, #LW.MoreChoices() do
  local c = LW.MoreChoices()[i]
  if c.name and rolledNames[c.name] then
    local listed = false
    for j = 1, #menu6.winners do
      if menu6.winners[j].name == c.name then listed = true end
    end
    if not listed then bareDup = c.name end
  end
end
eq(bareDup, nil, "rollers show with their roll, never again bare")
-- 6d. Continue: reopen a parked roll for more rolls on the SAME list.
-- Parked session re-attaches (same id), phase flips to rolling, the
-- primary button offers Continue while parked for award.
LW.SetItems({
  { itemID = 1001, link = "item:1001", badge = "SR:2" },
}, "loot")
LW.OpenDetail(1001)
ZugLoot.DB = { sheet = makeSheet() }
ML.sessions = { [1001] = { id = 31, itemID = 1001, itemLink = "item:1001",
  mode = "SR", silent = false, rolls = {}, t = 0, itemCount = 1,
  dispName = "item:1001" } }
ML.session = ML.sessions[1001]
LW.detail.phase = "rolling"
LW.detail.sessionID = 31
table.insert(LW.detail.rolls, { name = "Aaa", roll = 90, rollType = "SR", effective = 100 })
eq(LW.doAction(1001, "close"), "closed", "rolling close finishes+parks")
ok(LW.ParkedDetail(1001) ~= nil, "parked after close")
eq(LW.ParkedDetail(1001).phase, "preaward", "close finished into award rows")
ok(LW.ParkedDetail(1001).menu ~= nil, "award menu built on close")
-- Simulate an early finish while closed: the finished window parks for
-- award (preaward rows + menu), the session parks for continue.
ML.ParkSession(ML.sessions[1001])
ok(ML.sessions[1001] == nil, "session parked out of live table")
ok(ML.ParkedSession(1001) ~= nil, "session kept for continue")
local parkedMenu = { winners = { { name = "Aaa", rollType = "SR", effective = 100 } },
  groups = { SR = {}, MS = {}, OS = {}, TMOG = {} }, perType = {},
  candidates = {}, none = false, itemID = 1001 }
ML.pendingAwardMenus = { [1001] = { sess = ML.ParkedSession(1001), data = parkedMenu } }
ML.pendingAwardMenu = ML.pendingAwardMenus[1001]
local savedDetail = LW.ParkedDetail(1001)
savedDetail.phase = "preaward"
savedDetail.menu = parkedMenu
LW.OpenDetail(1001)
eq(LW.detail.phase, "preaward", "reopen shows preaward rows")
local pacts = LW.DetailActions()
eq(pacts[1].id, "award-name", "preaward offers the top winner first")
eq(pacts[1].name, "Aaa", "preaward winner named")
local hasContinue = false
for i = 1, #pacts do
  if pacts[i].id == "continue" then hasContinue = true end
end
ok(hasContinue, "preaward also offers Continue")
-- Preaward award rows use the ROLLED path (menu confirm), not the direct
-- no-roll shortcut: stub AwardChosen like the award window does and award
-- straight from the parked view.
local gotPre, gotVia = nil, nil
local realChosen = ML.AwardChosen
ML.AwardChosen = function(choice, itemID)
  gotPre, gotVia = choice.name, choice.via
  eq(itemID, 1001, "preaward award pins its item")
end
eq(LW.doAction(1001, "award-name", { name = "Aaa", via = "winner" }),
  "awarded Aaa", "preaward award uses rolled path")
eq(gotPre, "Aaa", "preaward recipient forwarded")
eq(gotVia, "winner", "preaward via forwarded")
ML.AwardChosen = realChosen
eq(LW.doAction(1001, "continue"), "continuing", "Continue re-attaches")
eq(LW.detail.phase, "rolling", "rolling again after Continue")
eq(ML.sessions[1001].id, 31, "same session id continued")
eq(LW.detail.sessionID, 31, "detail tracks the continued session")
ok(LW.DetailOnRoll(1001, 31, "Late", 42, "MS", 42), "late roll appends")
ok(not LW.DetailOnRoll(1001, 31, "Late", 10, "MS", 10), "first-roll-only kept")
-- Continuing twice is refused; finishing twice resolves again cleanly.
eq(LW.doAction(1001, "continue"), "already rolling", "no double continue")
-- Award from the window: the rolled-award path (menu confirm). The real
-- AwardChosen marks done + closes; emulate the harness playing the ML.
local pickName = aacts[1].name
ML.pendingAwardMenu = { sess = { itemID = 1001, itemLink = "item:1001",
    id = 7, silent = false, itemCount = 1 }, data = menu6 }
ML.AwardChosen = function(choice)
  SRData.MarkWon(ZugLoot.DB.sheet, 1001, choice.name)
  LW.RemoveItem(1001)
  ML.pendingAwardMenu = nil
  ML.session = nil
  LW.CloseDetail()
end
eq(LW.doAction(1001, "award-name", pickName), "awarded Aaa", "award in window")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "window award won-marks")
ok(LW.Find(1001) == nil, "awarded row left the list")
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
    { cap = 100 }))
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
  LW.RemoveItem(1001)
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

-- 7b. Close parks, reopen restores: roll -> close -> other rows -> reopen.
-- The exact scenario: item A rolled, closed, item B rolled AND awarded,
-- then A reopened with its rolls/menu intact and awarded with them.
LW.SetItems({
  { itemID = 1001, link = "item:1001", badge = "SR:2" },
  { itemID = 1002, link = "item:1002", badge = "SR" },
}, "loot")
LW.OpenDetail(1001)
ML.sessions = ML.sessions or {}
ML.sessions[1001] = { id = 21, itemID = 1001, silent = false }
ML.session = ML.sessions[1001]
LW.detail.phase = "rolling"
LW.detail.sessionID = 21
ok(LW.DetailOnRoll(1001, 21, "Aaa", 90, "SR", 100), "Aaa lands on A")
ok(LW.DetailOnRoll(1001, 21, "Bbb", 80, "SR", 80), "Bbb lands on A")
-- Close A mid-roll: FINISHES the roll into parked award rows (Close =
-- Finish then close). Session parks for award, rolls + menu saved.
eq(LW.doAction(1001, "close"), "closed", "A closed mid-roll")
ok(LW.detail == nil, "no open detail after close")
ok(LW.ParkedDetail(1001) ~= nil, "A parked")
eq(LW.ParkedDetail(1001).phase, "preaward", "A parked for award")
ok(LW.ParkedDetail(1001).menu ~= nil, "A award menu built on close")
ok(ML.ParkedSession(1001) ~= nil, "A session parked for award/continue")
-- B rolls and is awarded while A is parked.
LW.OpenDetail(1002)
ML.sessions[1002] = { id = 22, itemID = 1002, silent = false }
ML.session = ML.sessions[1002]
LW.detail.phase = "rolling"
LW.detail.sessionID = 22
ok(LW.DetailOnRoll(1002, 22, "Solo", 70, "SR", 70), "Solo lands on B")
ML.sessions[1002] = nil
ML.session = ML.sessions[1001]
LW.RemoveItem(1002)
ok(LW.Find(1002) == nil, "B awarded and gone")
ok(LW.ParkedDetail(1001) ~= nil, "A still parked after B award")
-- Reopen A: award rows intact (rolls shown via Continue), then award.
local rA = LW.OpenDetail(1001)
ok(rA ~= nil and rA.phase == "preaward", "A reopens parked for award")
eq(LW.doAction(1001, "continue"), "continuing", "A continues for more rolls")
ok(LW.detail.phase == "rolling", "A rolling again after Continue")
ok(LW.DetailOnRoll(1001, 21, "Late", 42, "MS", 42), "late roll appends")
ok(LW.ParkedDetail(1001) == nil, "reopen consumes the snapshot")
lwAwards = lwAwards or {}
local realDirect = ML.AwardDirect
ML.AwardDirect = function(id, who, src) table.insert(lwAwards, who) end
eq(LW.doAction(1001, "award-name", "Aaa"), "awarded Aaa", "A awarded off saved state")
eq(lwAwards[1], "Aaa", "A recipient from saved rolls")
ML.AwardDirect = realDirect
LW.RemoveItem(1001)
ok(LW.Find(1001) == nil and LW.ParkedDetail(1001) == nil,
  "A distributed: list and parked state both gone")
-- A plain pick window never parks (nothing to save).
ML.sessions = {}
ML.parkedSessions = nil
ML.session = nil
LW.parked = {}
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
eq(LW.doAction(1001, "close"), "closed", "pick close")
ok(LW.ParkedDetail(1001) == nil, "pick close parks nothing")
-- 7b. X button == Close action on a rolling window: finishes into parked
-- award rows and clears the session alias (regression: bare CloseDetail
-- stranded the live session, so the next item's roll failed and all
-- rolls — fakes and /roll alike — landed on the dead item).
ML.sessions = {}
ML.parkedSessions = nil
ML.session = nil
LW.parked = {}
LW.SetItems({
  { itemID = 1001, link = "item:1001", badge = "SR:2" },
  { itemID = 1002, link = "item:1002", badge = "SR" },
}, "loot")
LW.OpenDetail(1001)
ML.sessions[1001] = { id = 41, itemID = 1001, itemLink = "item:1001",
  mode = "SR", silent = false, rolls = {}, t = 0, itemCount = 1,
  dispName = "item:1001" }
ML.session = ML.sessions[1001]
LW.detail.phase = "rolling"
LW.detail.sessionID = 41
-- The frame X button routes through the Close ACTION (finish+park),
-- never a bare dismiss: emulate the handler via its named entry.
LW.OnCloseButton()
ok(ML.session == nil, "X close clears the session alias")
ok(LW.ParkedDetail(1001) ~= nil, "X close parks award rows")
eq(LW.ParkedDetail(1001).phase, "preaward", "X close finished first")
ok(ML.ParkedSession(1001) ~= nil, "X close parks the session")
-- Next item rolls clean on a fresh session; intake follows the alias.
LW.OpenDetail(1002)
ML.sessions[1002] = { id = 42, itemID = 1002, itemLink = "item:1002",
  mode = "SR", silent = false, rolls = {}, t = 0, itemCount = 1,
  dispName = "item:1002" }
ML.session = ML.sessions[1002]
LW.detail.phase = "rolling"
LW.detail.sessionID = 42
ok(LW.DetailOnRoll(1002, 42, "Solo", 70, "SR", 70), "roll lands on B")
ZugLoot.DB = ZugLoot.DB or {}
ML.OnSystemRoll("SoloPlayer", 55, 1, 100)
eq(#ML.sessions[1002].rolls, 1, "self-roll lands on the new session")
eq(ML.sessions[1002].rolls[1].name, "SoloPlayer", "self-roll named")
ML.sessions = {}
ML.parkedSessions = nil
ML.session = nil
LW.parked = {}
LW.CloseDetail()

-- 8. Master countdown: the rolling detail seeds the full window at
-- roll time (never one tick late), ticks down on the session clock,
-- survives park/restore, and clears on finish/cancel. Headless asserts
-- the data the client bar paints (paint itself is covered in mockrun).
-- Earlier blocks stubbed the ML starters: reload the pristine module so
-- this block drives the REAL timer path (BeginSession + BeginRollTimer).
dofile("MasterLootUI.lua")
ML = ZugLoot.MasterLootUI
ML.lootOpen = true
ZugLoot.DB = { sheet = makeSheet(), rollTime = 10 }
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
if ZugLoot.Timer then ZugLoot.Timer.CancelAll() end
-- Real roll through the window: live session, full-window seed.
local rr = LW.doAction(1001, "roll")
eq(rr, "rolling", "roll starts")
eq(LW.detail.countdown, 10, "countdown seeded at full window")
eq(LW.detail.countdownDur, 10, "bar denominator seeded")
local cdLines = LW.DetailLines()
ok(string.find(cdLines[1], "(10s)", 1, true) ~= nil,
  "headless head shows the clock, got: " .. tostring(cdLines[1]))
-- Seconds tick the paint down on the shared clock.
if ZugLoot.Timer then ZugLoot.Timer.Update(1) end
eq(LW.detail.countdown, 9, "tick paints 9s")
if ZugLoot.Timer then ZugLoot.Timer.Update(1) end
eq(LW.detail.countdown, 8, "tick paints 8s")
-- Park mid-roll, reopen: the saved clock restores.
LW.SetItems({
  { itemID = 1001, link = "item:1001", badge = "SR:2" },
  { itemID = 1002, link = "item:1002", badge = "SR" },
}, "loot")
LW.OpenDetail(1002) -- parks 1001's rolling state
local psnap = LW.ParkedDetail(1001)
ok(psnap ~= nil and psnap.phase == "rolling", "rolling state parked")
eq(psnap.countdown, 8, "parked snapshot keeps the clock")
eq(psnap.countdownDur, 10, "parked snapshot keeps the denominator")
LW.OpenDetail(1001) -- restores the snapshot
eq(LW.detail.countdown, 8, "reopen restores the clock")
-- The clock keeps ticking behind the parked copy: switch away, advance,
-- switch back. (Two ticks land: 8 -> 7 -> 6.)
LW.OpenDetail(1002)
if ZugLoot.Timer then ZugLoot.Timer.Update(1) end
if ZugLoot.Timer then ZugLoot.Timer.Update(1) end
LW.OpenDetail(1001)
eq(LW.detail.countdown, 6, "parked clock still ticks")
-- Cancel kills the clock: the rolling window closes, the parked copy
-- drops back to pick with no clock left to paint.
eq(LW.doAction(1001, "cancel"), "cancelled", "cancel from window")
ok(LW.detail == nil, "cancel closes the rolling window")
local cpark = LW.ParkedDetail(1001)
ok(cpark == nil or cpark.phase == "pick", "cancel parks nothing rolling")
ok(cpark == nil or cpark.countdown == nil, "cancel leaves no stale clock")
-- Finish clears it too: re-roll, feed one roll, finish -> award, no clock.
if ZugLoot.Timer then ZugLoot.Timer.CancelAll() end
ML.sessions = {}
ML.parkedSessions = nil
ML.session = nil
LW.parked = {}
LW.SetItems({ { itemID = 1001, link = "item:1001", badge = "SR:2" } }, "loot")
LW.OpenDetail(1001)
eq(LW.doAction(1001, "roll"), "rolling", "re-roll starts")
ok(LW.detail.countdown ~= nil, "re-roll seeds the clock")
ok(LW.DetailOnRoll(1001, ML.session.id, "Aaa", 90, "SR", 100), "roll lands")
ML.Finish(true, 1001)
eq(LW.detail.phase, "award", "finished into award")
eq(LW.detail.countdown, nil, "finish clears the clock")
eq(LW.detail.countdownDur, nil, "finish clears the denominator")
if ZugLoot.Timer then ZugLoot.Timer.CancelAll() end
ML.sessions = {}
ML.parkedSessions = nil
ML.session = nil
LW.parked = {}
LW.CloseDetail()

-- 9. Flow layout: one row when wide, wrap when narrow, justified.
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

-- 10. Modifier clicks never roll/loot: ctrl previews (dress-up),
-- shift links into chat, and neither opens the detail. Plain click
-- still opens the detail.
dofile("ItemIcon.lua")
local II = ZugLoot.ItemIcon
local FULL10 = "|cffa335ee|Hitem:1001:0:0:0|h[Test Sword]|h|r"
LW.blizzardTakeover = true -- rows active (headless default is detached-off)
LW.SetItems({ { itemID = 1001, link = FULL10 } }, "loot")
LW.CloseDetail()
local tried10, inserted10 = {}, {}
DressUpItemLink = function(l) table.insert(tried10, l) end
GetItemInfo = function(id) return "Test Sword", FULL10, 4 end
ChatFrameEditBox = { IsVisible = function() return false end,
  Insert = function(self, s) table.insert(inserted10, s) end }
-- ctrl: dress-up, no detail
IsControlKeyDown = function() return true end
IsShiftKeyDown = function() return false end
if LW.CloseDetail then LW.CloseDetail() end
local rCtrl = LW.OnRowClick(1001, 1)
eq(rCtrl, "dressup", "ctrl-click previews")
eq(#tried10, 1, "ctrl-click tries on once")
ok(LW.detail == nil, "ctrl-click opens no detail")
-- shift with chat open: link inserted, no detail
IsControlKeyDown = function() return false end
IsShiftKeyDown = function() return true end
ChatFrameEditBox = { IsVisible = function() return true end,
  Insert = function(self, s) table.insert(inserted10, s) end }
local rShift = LW.OnRowClick(1001, 1)
eq(rShift, "insert", "shift-click links")
eq(#inserted10, 1, "shift-click inserts once")
ok(LW.detail == nil, "shift-click opens no detail")
-- plain: detail as usual
IsShiftKeyDown = function() return false end
ChatFrameEditBox = { IsVisible = function() return false end }
ZugLoot.DB = ZugLoot.DB or {}
ZugLoot.DB.rehearse = true -- solo rows open the detail, not loot
local rPlain = LW.OnRowClick(1001, 1)
eq(rPlain, "detail", "plain click still opens")
ok(LW.detail and LW.detail.itemID == 1001, "plain click opens the detail")
IsControlKeyDown = nil; IsShiftKeyDown = nil
ChatFrameEditBox = nil; DressUpItemLink = nil; GetItemInfo = nil
return T
