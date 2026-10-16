-- tests/test_itemcards.lua
-- SRData roll history + ItemCards aggregation (pure, no WoW API).
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
dofile("ClassColors.lua")
dofile("SRData.lua")
dofile("Resolver.lua")
dofile("ItemCards.lua")
local SRData = ZugLoot.SRData
local Cards = ZugLoot.ItemCards

local sheet = SRData.NewSheet()
sheet.items[17063] = { quality = 4, rollers = {
  { name = "Blackfang", rolls = 2, sr_plus = 20 },
  { name = "Carbon", rolls = 1, sr_plus = 130 },
} }
sheet.hardres[17782] = { quality = 5 }

-- 1. RecordRolls stores sessions per item, GetRolls reads back.
local n = SRData.RecordRolls(sheet, 17063, {
  t = 1000, mode = "SR", winners = { "Carbon" },
  entries = {
    { name = "Carbon", base = 95, sr_plus = 130, effective = 225 },
    { name = "Blackfang", base = 40, sr_plus = 20, effective = 60 },
  },
})
eq(n, 1, "first session recorded")
eq(SRData.RollCount(sheet, 17063), 1, "roll count")
eq(SRData.RollCount(sheet, 99999), 0, "no rolls unknown item")

-- 2. Multiple sessions accumulate; missrolls preserved.
SRData.RecordRolls(sheet, 17063, {
  t = 2000, mode = "SR", winners = { "Blackfang" },
  entries = {
    { name = "Blackfang", base = 90, sr_plus = 20, effective = 110 },
    { name = "Ninja", base = 100, sr_plus = 0, effective = 100, missroll = true },
  },
})
eq(SRData.RollCount(sheet, 17063), 2, "two sessions")

-- 3. Cards aggregate: sorted, SR list, HR flag, rolled flag, history lines.
local cards = Cards.BuildCards(sheet)
eq(cards[1].itemID, 17063, "cards sorted by item")
eq(cards[1].hardres, false, "not hardres")
eq(cards[2], nil, "only sheet items become cards (HR-only id not a card)")
ok(cards[1].rolled, "rolled flag set")
eq(cards[1].winnerNames[1], "Blackfang", "latest winner = last session")
eq(cards[1].rollers[1].name, "Blackfang", "roller order kept")
eq(cards[1].rollers[1].rolls, 2, "rolls x2 kept")
eq(cards[1].rollers[2].sr_plus, 130, "sr+ kept")
eq(#cards[1].rollSessions, 2, "both sessions on card")
eq(cards[1].rollSessions[1].lines[1].effective, 225, "session 1 top line")
eq(cards[1].rollSessions[2].lines[2].missroll, true, "missroll flag kept")

-- 4. WON marks flow into cards.
SRData.MarkWon(sheet, 17063, "Carbon")
local cards2 = Cards.BuildCards(sheet)
eq(cards2[1].rollers[2].won, true, "won on card")
eq(cards2[1].rollers[1].won, false, "other not won")

-- 5. CardSummary mentions SR, SR+, rolls and winner.
local sum = Cards.CardSummary(cards2[1])
ok(string.find(sum, "Carbon x1") ~= nil, "summary has roller")
ok(string.find(sum, "+130") ~= nil, "summary has sr+")
ok(string.find(sum, "rolls#1") ~= nil, "summary has session 1")
ok(string.find(sum, "rolls#2") ~= nil, "summary has session 2")
ok(string.find(sum, "Blackfang") ~= nil, "summary has winner")

-- 5b. Excluded (already-won) rollers show in session lines + summary.
local exclSheet = SRData.NewSheet()
exclSheet.items[77] = { quality = 4, rollers = {
  { name = "Prev", rolls = 1, sr_plus = 5 },
  { name = "Next", rolls = 1, sr_plus = nil },
} }
SRData.MarkWon(exclSheet, 77, "Prev")
local exclRes = ZugLoot.Resolver.ResolveItem(exclSheet, 77, {
  { name = "Prev", roll = 99, type = "SR" },
  { name = "Next", roll = 10, type = "SR" },
}, { cap = 100 })
eq(exclRes.winners[1].name, "Next", "subsequent roll won by eligible")
SRData.RecordRolls(exclSheet, 77, ZugLoot.Resolver.ToHistoryEntry(exclRes, "SR", 5))
local exclCards = Cards.BuildCards(exclSheet)
local exclLines = exclCards[1].rollSessions[1].lines
local exclShown = false
for i = 1, #exclLines do
  if exclLines[i].name == "Prev" and exclLines[i].excludedWon then exclShown = true end
end
ok(exclShown, "excluded roller shown in card session lines")
local exclSum = Cards.CardSummary(exclCards[1])
ok(string.find(exclSum, "Prev 99/100") ~= nil, "summary shows excluded roll with range")
ok(string.find(exclSum, "already won") ~= nil, "summary tags already won")

-- 5c. Roll kinds render their range: OS rolls show base/cap (13/99).
-- rollType flows through ToHistoryEntry -> card lines -> summary.
local rangeSheet = SRData.NewSheet()
rangeSheet.items[99] = { quality = 4, rollers = { { name = "Ranger", rolls = 1 } } }
local rangeRes = ZugLoot.Resolver.ResolveItem(rangeSheet, 99, {
  { name = "Ranger", roll = 13, type = "OS" },
}, { cap = 100 })
SRData.RecordRolls(rangeSheet, 99, ZugLoot.Resolver.ToHistoryEntry(rangeRes, "RAID", 9))
local rangeCards = Cards.BuildCards(rangeSheet)
eq(rangeCards[1].rollSessions[1].lines[1].rollType, "OS", "card line keeps roll kind")
local rangeSum = Cards.CardSummary(rangeCards[1])
ok(string.find(rangeSum, "Ranger 13/99", 1, true) ~= nil, "summary shows OS range 13/99, got: " .. rangeSum)

-- 6. Empty sheet -> no cards; nil sheet -> no cards.
eq(#Cards.BuildCards(SRData.NewSheet()), 0, "empty sheet, no cards")
eq(#Cards.BuildCards(nil), 0, "nil sheet, no cards")

-- 7. History cap: ROLLS_PER_ITEM_MAX enforced.
for i = 1, 30 do
  SRData.RecordRolls(sheet, 555, { t = i, mode = "SR", winners = {}, entries = {} })
end
eq(SRData.RollCount(sheet, 555), SRData.ROLLS_PER_ITEM_MAX, "history capped")

-- 8. Unreserved stub: added at the bottom, flagged, never clobbers SR data.
local unSheet = SRData.NewSheet()
unSheet.items[200] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
ok(SRData.EnsureUnreserved(unSheet, 50, 3), "stub added for missing item")
eq(unSheet.items[50].quality, 3, "stub keeps quality")
eq(unSheet.items[50].unsr, true, "stub flagged unsr")
ok(not SRData.EnsureUnreserved(unSheet, 200, 3), "existing SR item untouched")
eq(#unSheet.items[200].rollers, 1, "SR rollers not clobbered")
ok(SRData.IsUnreserved(unSheet, 50), "IsUnreserved true for stub")
ok(not SRData.IsUnreserved(unSheet, 200), "IsUnreserved false for SR item")
local unCards = Cards.BuildCards(unSheet)
eq(#unCards, 2, "stub becomes a card")
eq(unCards[1].itemID, 200, "SR item first")
eq(unCards[2].itemID, 50, "unreserved card at the bottom")
eq(unCards[2].unsr, true, "card carries unsr flag")
local unSum = Cards.CardSummary(unCards[2])
ok(string.find(unSum, "not SR'd") ~= nil, "summary flags not SR'd")
-- prune removes stubs only:
eq(SRData.PruneUnreserved(unSheet), 1, "one stub pruned")
ok(unSheet.items[50] == nil, "stub gone")
ok(unSheet.items[200] ~= nil, "SR item kept")

-- 8b. Sheet log floor (rare 3+ only): below rare never enters the sheet.
ok(SRData.LoggableQuality(3), "rare loggable")
ok(SRData.LoggableQuality(4), "epic loggable")
ok(SRData.LoggableQuality(5), "legendary loggable")
ok(not SRData.LoggableQuality(2), "uncommon not logged")
ok(not SRData.LoggableQuality(1), "common not logged")
ok(not SRData.LoggableQuality(0), "poor not logged")
ok(SRData.LoggableQuality(nil), "unknown quality proceeds")
local floorSheet = SRData.NewSheet()
ok(not SRData.EnsureUnreserved(floorSheet, 51, 2), "green stub refused")
ok(floorSheet.items[51] == nil, "green never stubbed")
ok(not SRData.EnsureUnreserved(floorSheet, 52, 0), "grey stub refused")
ok(SRData.EnsureUnreserved(floorSheet, 53, 3), "rare stub added")
ok(SRData.EnsureUnreserved(floorSheet, 54, nil), "unknown-quality stub added")
ok(SRData.MarkWon(floorSheet, 53, "Aaa", 4), "epic won marks")
ok(SRData.HasWon(floorSheet, 53, "Aaa"), "epic won kept")
ok(not SRData.MarkWon(floorSheet, 55, "Bbb", 2), "green won refused")
ok(not SRData.HasWon(floorSheet, 55, "Bbb"), "green won never lands")
ok(SRData.MarkWon(floorSheet, 56, "Ccc"), "unknown-quality won marks")
-- Direct MarkWon with explicit 0 refuses (callers normalize the
-- list-default 0 to nil before calling).
eq(SRData.MarkWon(floorSheet, 58, "Eee", 0), false, "explicit poor won refused")

-- 9. Cards sort alphabetically by item name (client cache or sheet
-- name), numeric ids only as tie-break; stubs still trail at bottom.
GetItemInfo = function(id)
  local names = { [300] = "Zebra Blade", [100] = "Apple Staff", [200] = "Mango Axe" }
  return names[tonumber(id)]
end
local alphaSheet = SRData.NewSheet()
alphaSheet.items[300] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
alphaSheet.items[100] = { quality = 4, rollers = { { name = "Bbb", rolls = 1 } } }
alphaSheet.items[200] = { quality = 4, rollers = { { name = "Ccc", rolls = 1 } } }
local alphaCards = Cards.BuildCards(alphaSheet)
eq(#alphaCards, 3, "three cards")
eq(alphaCards[1].itemID, 100, "Apple Staff first")
eq(alphaCards[2].itemID, 200, "Mango Axe second")
eq(alphaCards[3].itemID, 300, "Zebra Blade last")
-- Sheet-stored names work with no client cache either.
GetItemInfo = nil
local namedSheet = SRData.NewSheet()
namedSheet.items[9] = { quality = 4, name = "Zulu", rollers = { { name = "Aaa", rolls = 1 } } }
namedSheet.items[3] = { quality = 4, name = "Alpha", rollers = { { name = "Bbb", rolls = 1 } } }
local namedCards = Cards.BuildCards(namedSheet)
eq(namedCards[1].itemID, 3, "sheet name Alpha first")
eq(namedCards[2].itemID, 9, "sheet name Zulu last")
-- Uncached ids fall back to item:<id> (deterministic, still sorted).
local bareSheet = SRData.NewSheet()
bareSheet.items[50] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
bareSheet.items[5] = { quality = 4, rollers = { { name = "Bbb", rolls = 1 } } }
local bareCards = Cards.BuildCards(bareSheet)
eq(bareCards[1].itemID, 5, "item:5 before item:50")
-- Wire order stays numeric regardless of names.
local wireIDs = SRData.SortedCardIDs(alphaSheet, { keepNumeric = true })
eq(table.concat(wireIDs, ","), "100,200,300", "broadcast order numeric")
GetItemInfo = nil

return T
