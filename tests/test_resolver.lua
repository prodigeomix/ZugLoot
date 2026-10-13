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

-- 2. Miss-roll ignored: non-SR roller with 100 loses to SR roller with 1.
local res2 = R.ResolveItem(s, 17063, {
  { name = "A", roll = 1, type = "SR" },
  { name = "Ninja", roll = 100, type = "MS" },
}, { cap = 100, requireSR = true })
eq(res2.winners[1].name, "A", "missroll ignored")
eq(res2.missrolls[1].name, "Ninja", "missroll flagged")

-- 3. Tie at top => tied list, winner holds cutoff members.
local s3 = sheetWith(1, { { name = "A", rolls = 1 }, { name = "B", rolls = 1 } })
local res3 = R.ResolveItem(s3, 1, {
  { name = "A", roll = 50, type = "SR" },
  { name = "B", roll = 50, type = "SR" },
}, { cap = 100, requireSR = true })
eq(#res3.tied, 2, "tie needs reroll")

-- 4. One-win-per-item: previous winner excluded.
local s4 = sheetWith(5, { { name = "A", rolls = 1 }, { name = "B", rolls = 1 } })
SRData.MarkWon(s4, 5, "A")
local res4 = R.ResolveItem(s4, 5, {
  { name = "A", roll = 100, type = "SR" },
  { name = "B", roll = 2, type = "SR" },
}, { cap = 100, requireSR = true })
eq(res4.winners[1].name, "B", "won player excluded")

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

-- 8. FakeRolls + full SR resolution path incl. fillers as missrolls.
math.randomseed(1234)
local rolls = R.FakeRolls(s, 17063, { cap = 100, fillers = 2 })
local res8 = R.ResolveItem(s, 17063, rolls, { cap = 100, requireSR = true })
ok(res8.winners[1].name == "A" or res8.winners[1].name == "B", "sim resolves to SR roller")
eq(#res8.missrolls, 2, "fillers flagged as missrolls")

return T
