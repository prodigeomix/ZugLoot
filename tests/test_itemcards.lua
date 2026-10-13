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
}, { cap = 100, requireSR = true })
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
ok(string.find(exclSum, "Prev 99") ~= nil, "summary shows excluded roll")
ok(string.find(exclSum, "already won") ~= nil, "summary tags already won")

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

return T
