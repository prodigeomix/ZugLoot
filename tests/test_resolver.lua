-- tests/test_resolver.lua
-- Resolver tests: SR winner incl SR+, ties, miss-rolls, one-win, 2x, open rolls.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else T.pass = T.pass + 1 end
end
local function ok(v, msg)
  if not v then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else T.pass = T.pass + 1 end
end

ZugLoot = ZugLoot or {}
dofile("Util.lua")
dofile("ClassColors.lua")
dofile("SRData.lua")
dofile("Resolver.lua")
local SRData = ZugLoot.SRData
local R = ZugLoot.Resolver

local function sheetWith(itemID, rollers)
  local s = SRData.NewSheet()
  s.items[itemID] = { quality = 4, rollers = rollers }
  return s
end

-- 1. SR+ decides: low base + big bonus beats high base.
local s = sheetWith(17063, {
  { name = "A", rolls = 1, sr_plus = 60 },
  { name = "B", rolls = 1, sr_plus = nil },
})
local res = R.ResolveItem(s, 17063, {
  { name = "A", roll = 40, type = "SR" },
  { name = "B", roll = 95, type = "SR" },
}, { cap = 100, requireSR = true })
eq(res.winners[1].name, "A", "sr+ winner")
eq(res.winners[1].effective, 100, "effective = 40+60")
eq(res.ranked[2].effective, 95, "runner up")

-- 2a. Priority: off-sheet MS 100 is a valid MS contest but loses to
-- SR 1 by kind priority (each type judged by itself, SR first).
local res2 = R.ResolveItem(s, 17063, {
  { name = "A", roll = 1, type = "SR" },
  { name = "Ninja", roll = 100, type = "MS" },
}, { cap = 100, requireSR = true })
eq(res2.winners[1].name, "A", "sr 1 outranks ms 100")
eq(res2.perType.MS.entry.name, "Ninja", "ms contest still recorded")

-- 2b. Miss-roll: SR-range roll WITHOUT the reserve is ignored.
local res2b = R.ResolveItem(s, 17063, {
  { name = "A", roll = 1, type = "SR" },
  { name = "Ninja", roll = 100, type = "SR" },
}, { cap = 100, requireSR = true })
eq(res2b.winners[1].name, "A", "fake-sr missroll ignored")
eq(res2b.missrolls[1].name, "Ninja", "missroll flagged")

-- 3. Tie at top => tied list, winner holds cutoff members.
local s3 = sheetWith(1, { { name = "A", rolls = 1 }, { name = "B", rolls = 1 } })
local res3 = R.ResolveItem(s3, 1, {
  { name = "A", roll = 50, type = "SR" },
  { name = "B", roll = 50, type = "SR" },
}, { cap = 100, requireSR = true })
eq(#res3.tied, 2, "tie needs reroll")

-- 4. One-win-per-item: previous winner excluded but still shown.
local s4 = sheetWith(5, { { name = "A", rolls = 1 }, { name = "B", rolls = 1 } })
SRData.MarkWon(s4, 5, "A")
local res4 = R.ResolveItem(s4, 5, {
  { name = "A", roll = 100, type = "SR" },
  { name = "B", roll = 2, type = "SR" },
}, { cap = 100, requireSR = true })
eq(res4.winners[1].name, "B", "won player excluded")
-- excluded rolls are visible, not dropped:
eq(#res4.excluded, 1, "excluded list has the won roller")
eq(res4.excluded[1].name, "A", "excluded roller named")
eq(res4.excluded[1].base, 100, "excluded roll value kept")
-- excluded entries also appear in res.entries with the flag:
local foundExcl = false
for i = 1, #res4.entries do
  if res4.entries[i].name == "A" and res4.entries[i].excludedWon then foundExcl = true end
end
ok(foundExcl, "excluded roller present in entries with flag")
-- history entry carries excluded through:
local h4 = R.ToHistoryEntry(res4, "SR", 999)
eq(#h4.excluded, 1, "history carries excluded")
eq(h4.excluded[1].name, "A", "history excluded name")

-- 5. Two-top-win: two distinct winners.
local res5 = R.ResolveItem(s3, 1, {
  { name = "A", roll = 90, type = "SR" },
  { name = "B", roll = 80, type = "SR" },
}, { cap = 100, requireSR = true, itemCount = 2 })
eq(#res5.winners, 2, "two winners")
eq(res5.winners[1].name, "A", "first winner")
eq(res5.winners[2].name, "B", "second winner")

-- 6. Open roll (no sheet): highest base wins, no missrolls.
local res6 = R.ResolveItem(SRData.NewSheet(), 999, {
  { name = "X", roll = 10, type = "MS" },
  { name = "Y", roll = 99, type = "OS" },
}, { cap = 100, requireSR = false })
eq(res6.winners[1].name, "Y", "open roll highest wins")
eq(#res6.missrolls, 0, "no missrolls in open")

-- 7. Out-of-range rolls dropped.
local res7 = R.ResolveItem(s3, 1, {
  { name = "A", roll = 0, type = "SR" },
  { name = "B", roll = 101, type = "SR" },
  { name = "A", roll = 10, type = "SR" },
}, { cap = 100, requireSR = true })
-- A has two entries (0 invalid dropped, 10 kept); best-per-player keeps 10.
eq(res7.winners[1].name, "A", "invalid rolls dropped")

-- 8b. Per-type contests: TMOG 15 vs SR 58 — SR wins outright, TMOG
-- still owns its kind (directly awardable, never the overall winner).
local sT = sheetWith(77, { { name = "SRGuy", rolls = 1 }, { name = "TMog", rolls = 1 } })
local resT = R.ResolveItem(sT, 77, {
  { name = "SRGuy", roll = 58, type = "SR" },
  { name = "TMog", roll = 15, type = "TMOG" },
}, { cap = 100, requireSR = true })
eq(resT.winners[1].name, "SRGuy", "sr wins outright")
eq(resT.perType.TMOG.entry.name, "TMog", "tmog owns its kind at 15")
eq(resT.perType.TMOG.entry.effective, 15, "tmog effective is raw")
ok(resT.winners[1].name ~= "TMog", "tmog never takes the winner slot")

-- 8c. Priority SR > MS > OS: a low SR beats a high MS; MS beats OS.
local sP = sheetWith(78, { { name = "S", rolls = 1 } })
local resP = R.ResolveItem(sP, 78, {
  { name = "S", roll = 5, type = "SR" },
  { name = "M", roll = 99, type = "MS" },
  { name = "O", roll = 98, type = "OS" },
}, { cap = 100, requireSR = true })
eq(resP.winners[1].name, "S", "sr 5 outranks ms/os 99")
eq(resP.perType.MS.entry.name, "M", "ms owns its kind")
eq(resP.perType.OS.entry.name, "O", "os owns its kind")
-- MS with no SR contest wins outright (open shape for non-sheet M/O).
local resP2 = R.ResolveItem(sP, 78, {
  { name = "M", roll = 99, type = "MS" },
  { name = "O", roll = 98, type = "OS" },
}, { cap = 100, requireSR = true })
eq(resP2.winners[1].name, "M", "ms wins with no sr contest")

-- 8d. Ranges per type: OS cap 99, TMOG cap 98 — over-cap never wins.
local resC = R.ResolveItem(sP, 78, {
  { name = "O", roll = 100, type = "OS" },
  { name = "M", roll = 60, type = "MS" },
}, { cap = 100, requireSR = true })
eq(resC.winners[1].name, "M", "os 100 is over-cap, ms wins")
eq(resC.perType.OS.entry, nil, "no os contest on over-cap")
local resC2 = R.ResolveItem(sP, 78, {
  { name = "T", roll = 99, type = "TMOG" },
}, { cap = 100, requireSR = false })
eq(#resC2.winners, 0, "lone tmog 99 (over 98) wins nothing")
ok(resC2.perType.TMOG.entry == nil, "no tmog contest on over-cap")

-- 8e. No SR bonus outside SR: sheet roller rolling MS gets raw value.
local sB = sheetWith(79, { { name = "S", rolls = 1, sr_plus = 50 } })
local resB = R.ResolveItem(sB, 79, {
  { name = "S", roll = 40, type = "MS" },
}, { cap = 100, requireSR = false })
eq(resB.perType.MS.entry.effective, 40, "ms takes no sr bonus")

-- 8f. Ties re-roll WITHIN the kind (SR tie + clean MS: tie, no winner).
local sTie = sheetWith(80, { { name = "A", rolls = 1 }, { name = "B", rolls = 1 } })
local resTie = R.ResolveItem(sTie, 80, {
  { name = "A", roll = 50, type = "SR" },
  { name = "B", roll = 50, type = "SR" },
  { name = "M", roll = 99, type = "MS" },
}, { cap = 100, requireSR = true })
eq(#resTie.tied, 2, "sr tie needs reroll despite ms 99")
eq(resTie.perType.SR.tied[1].name, "B", "tie recorded in kind")

-- 8g. One-win blocks SR ONLY: already-won player still contests
-- MS/OS/TMOG (e.g. transmog after a mainspec win).
local sW = sheetWith(81, { { name = "A", rolls = 1 }, { name = "Me", rolls = 1 } })
SRData.MarkWon(sW, 81, "Me")
local resW = R.ResolveItem(sW, 81, {
  { name = "A", roll = 58, type = "SR" },
  { name = "Me", roll = 90, type = "SR" },
  { name = "Me2", roll = 15, type = "TMOG" },
}, { cap = 100, requireSR = true })
eq(resW.winners[1].name, "A", "sr winner unaffected")
eq(resW.perType.TMOG.entry.name, "Me2", "tmog contest stands")
-- same player, won, rolls TMOG: still contestable.
local resW2 = R.ResolveItem(sW, 81, {
  { name = "A", roll = 58, type = "SR" },
  { name = "Me", roll = 15, type = "TMOG" },
}, { cap = 100, requireSR = true })
eq(resW2.perType.TMOG.entry.name, "Me", "won player contests TMOG")
eq(resW2.winners[1].name, "A", "overall still SR")
-- ...but their SR roll stays excluded.
local resW3 = R.ResolveItem(sW, 81, {
  { name = "Me", roll = 99, type = "SR" },
  { name = "A", roll = 10, type = "SR" },
}, { cap = 100, requireSR = true })
eq(resW3.winners[1].name, "A", "won SR roll excluded")

-- 8. FakeRolls + full SR resolution path incl. fillers as missrolls.
math.randomseed(1234)
local rolls = R.FakeRolls(s, 17063, { cap = 100, fillers = 2 })
local res8 = R.ResolveItem(s, 17063, rolls, { cap = 100, requireSR = true })
ok(res8.winners[1].name == "A" or res8.winners[1].name == "B", "sim resolves to SR roller")
ok(res8.perType.MS.entry ~= nil, "fillers contest MS (valid kind)")

return T
