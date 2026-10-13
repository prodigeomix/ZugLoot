-- tests/test_pfloot.lua
-- pfQuest loot lookup (Rarescanner pattern): name -> entry -> weighted
-- random drops. Runs against a fake db; the no-pfQuest path is covered by
-- every other test file (pfDB global absent).
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
ZugLoot.Util = ZugLoot.Util or dofile("Util.lua")
dofile("pfLoot.lua")
local P = ZugLoot.pfLoot

-- Fake pfDB slice: two units, direct + refloot drops, one junk drop.
local fakeDb = {
  units = { loc = { [101] = "Test Boss", [102] = "Trash Mob" } },
  items = { data = {
    [5001] = { U = { [101] = 20 } },          -- direct 20%
    [5002] = { U = { [101] = 2 } },           -- direct 2%
    [5003] = { R = { [7] = 50 } },            -- refloot 50%
    [5004] = { U = { [102] = 30 } },          -- other mob only
    [5005] = { U = { [101] = 0.1 } },         -- below the noise floor
  } },
  refloot = { data = { [7] = { U = { [101] = 1 } } } },
}

-- 1. Name -> entry (case-insensitive, all units, not just rares).
eq(P.EntryIdByName("Test Boss", fakeDb), 101, "entry by name")
eq(P.EntryIdByName("test boss", fakeDb), 101, "case-insensitive")
eq(P.EntryIdByName("Nobody", fakeDb), nil, "unknown name nil")
eq(P.EntryIdByName("Test Boss", nil), nil, "no db nil")
eq(P.NameOf(101, fakeDb), "Test Boss", "display name")
eq(P.NameOf(999, fakeDb), "Unknown", "unknown entry fallback")

-- 2. Index: direct + refloot merged, ALL chances indexed (no noise floor
-- in the index — the floor is a weight in PickDrops), other mobs excluded.
local drops = P.DropsFor(101, fakeDb, true)
local byId = {}
for i = 1, #drops do byId[drops[i].item] = drops[i].chance end
for id, want in pairs({ [5001] = 20, [5003] = 50, [5002] = 2 }) do
  eq(byId[id], want, "drop chance " .. id)
end
eq(byId[5005], 0.1, "sub-floor chance indexed (floor lives in PickDrops)")
ok(byId[5004] == nil, "other mob excluded")
eq(drops[1].item, 5003, "sorted best first")
ok(#P.DropsFor(999, fakeDb, true) == 0, "unknown entry empty")

-- 3. Weighted picks, EPICS ONLY: rigged rng takes 20%+ hits, skips 2%.
-- Quality stub: 5003/5001 epic, 5002 blue (filtered even on a hit).
local function rigged(values)
  local i = 0
  return function(lo, hi)
    i = i + 1
    local v = values[((i - 1) % #values) + 1]
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
  end
end
local qualities = { [5003] = 4, [5001] = 4, [5002] = 3, [5005] = 3 }
local function qual(id) return qualities[id] end
-- Random distinct count + coin-gated double (NOT "fill to cap": that was
-- the deterministic same-list bug for small epic pools).
-- Pool after epic filter: {5003 w=500, 5001 w=200} (m=2).
-- A: k=2 distinct, no double.
local picks = P.PickDrops(drops, 4, rigged({ 2, 100, 200, 2 }), qual)
eq(#picks, 2, "two distinct, no double")
eq(picks[1], 5003, "sorted best first")
eq(picks[2], 5001, "second kind present")
-- B: k=2 distinct + one double of the best item.
local full = P.PickDrops(drops, 4, rigged({ 2, 100, 200, 1, 100 }), qual)
eq(#full, 3, "two distinct plus one double")
eq(full[1], 5003, "best first")
eq(full[3], 5001, "second kind present")
-- C: count cap respected (k clamped to 1).
local many = P.PickDrops(drops, 1, rigged({ 1, 100 }), qual)
eq(#many, 1, "count cap")
eq(many[1], 5003, "best single")
-- D: blues never picked even when their roll hits.
local blueOnly = P.PickDrops(
  { { item = 5002, chance = 100 } }, 4, rigged({ 1 }), qual)
eq(#blueOnly, 0, "non-epic filtered")
-- E: single-item pool -> at most one distinct + one double (MAX_DUPES).
local dupes = P.PickDrops(
  { { item = 5001, chance = 100 } }, 4, rigged({ 1, 1, 1, 1 }), qual)
eq(#dupes, 2, "up to two of the same item")
local solo = P.PickDrops(
  { { item = 5001, chance = 100 } }, 4, rigged({ 1, 1, 2 }), qual)
eq(#solo, 1, "coin gate can skip the double")
-- F: a 3-epic pool now VARIES: k=2 vs k=3 pick different subsets.
local pool3 = { { item = 7001, chance = 50 }, { item = 7002, chance = 40 }, { item = 7003, chance = 30 } }
local function epicQual() return 4 end
local sub2 = P.PickDrops(pool3, 4, rigged({ 2, 100, 600, 2 }), epicQual)
eq(#sub2, 2, "3-epic pool rolls 2 this run")
local sub3 = P.PickDrops(pool3, 4, rigged({ 3, 100, 500, 200, 2 }), epicQual)
eq(#sub3, 3, "3-epic pool rolls 3 next run")
-- G: chance-0 real boss drops are pickable (floor weight), and unknown
-- (nil) quality is treated as loot-worthy (Turtle custom epics).
local zeroDrops = { { item = 7001, chance = 0 } }
local z1 = P.PickDrops(zeroDrops, 4, rigged({ 1, 1, 2 }), epicQual)
eq(#z1, 1, "chance-0 epic pickable")
eq(z1[1], 7001, "chance-0 epic included")
local z2 = P.PickDrops(zeroDrops, 4, rigged({ 1, 1, 2 }), function() return nil end)
eq(#z2, 1, "nil quality kept")

-- 4. BossDrops end-to-end (fake db injected, no pfDB global needed).
local boss = P.BossDrops("Test Boss", 4, rigged({ 2, 100, 200, 1, 100 }), fakeDb, qual)
eq(#boss, 3, "boss epic drops picked (incl. double)")
eq(boss[1], 5003, "best drop first")
-- fresh loot every call: same pool, but the coin gate skips the double this
-- run -> 2 items, not 3 (count varies run to run).
local boss2 = P.BossDrops("Test Boss", 4, rigged({ 2, 600, 500, 2 }), fakeDb, qual)
eq(#boss2, 2, "re-rolled loot count differs")
eq(boss2[1], 5003, "sorted best first")
eq(boss2[2], 5001, "second kind, no double")
ok(#P.BossDrops("Nobody", 4, rigged({ 1 }), fakeDb) == 0, "unknown boss empty")

-- 5. No pfQuest at all: everything degrades to nil/empty (simboss falls
-- back to BossData.lua, never errors).
pfDB = nil
P.index = nil
ok(P.EntryIdByName("Test Boss") == nil, "no pfDB: no entry")
ok(#P.DropsFor(101) == 0, "no pfDB: no drops")
ok(#P.BossDrops("Test Boss") == 0, "no pfDB: no boss drops")

-- 6. Static fallback: random re-rolled subsets so every simboss run varies
-- even without pfQuest (a fixed table would repeat the same list).
local static3 = { 17063, 17076, 17102 }
local function srigged(values)
  local i = 0
  return function(lo, hi)
    i = i + 1
    local v = values[((i - 1) % #values) + 1]
    -- clamp like a real rng would (contract: honor [lo,hi])
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
  end
end
-- j=1,1 shuffle of {1,2,3}: i=3: swap(3,1) -> {3,2,1}; i=2: swap(2,1)
-- -> {2,3,1}; order list[2],list[3],list[1] = 17076,17102,17063.
-- k=3 -> all three shuffled; coin=2 -> no double.
local s1 = P.PickStaticDrops(static3, 4, srigged({ 1, 1, 3, 2, 99 }))
eq(#s1, 3, "full shuffled set")
eq(s1[1], 17076, "shuffled first")
eq(s1[2], 17102, "shuffled second")
eq(s1[3], 17063, "shuffled third")
-- j=3,3: identity; k=2 -> partial pair; coin=2 -> no double.
local s2 = P.PickStaticDrops(static3, 4, srigged({ 3, 3, 2, 2 }))
eq(#s2, 2, "random partial count")
eq(s2[1], 17063, "identity order kept")
eq(s2[2], 17076, "identity order kept")
-- j=3,3: identity; k=2 -> pair; coin=1 -> one double of pick 2.
local s3p = P.PickStaticDrops(static3, 4, srigged({ 3, 3, 2, 1, 2 }))
eq(#s3p, 3, "pair plus one double")
eq(s3p[1], 17063, "pair first")
eq(s3p[2], 17076, "pair second")
eq(s3p[3], 17076, "doubled item")
-- count cap + edges: singleton never dupes past room, empties are safe.
local s4 = P.PickStaticDrops({ 17063 }, 4, srigged({ 1, 1, 1 }))
ok(#s4 >= 1 and #s4 <= 2, "singleton run")
eq(s4[1], 17063, "singleton item kept")
eq(#P.PickStaticDrops({}, 4, srigged({ 1 })), 0, "empty static empty")
eq(#P.PickStaticDrops(static3, 0, srigged({ 1 })), 0, "zero count empty")
-- input untouched: the static table must not be reordered in place.
eq(static3[1], 17063, "input table untouched")
-- two calls with live rng over 3+ epics vary (statistical, not rigged).
-- skipped: covered deterministically above; live variance is by design.

return T
