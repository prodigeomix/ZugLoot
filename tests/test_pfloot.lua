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

-- 2. Index: direct + refloot merged, noise floored, other mobs excluded.
local drops = P.DropsFor(101, fakeDb, true)
local byId = {}
for i = 1, #drops do byId[drops[i].item] = drops[i].chance end
for id, want in pairs({ [5001] = 20, [5003] = 50, [5002] = 2 }) do
  eq(byId[id], want, "drop chance " .. id)
end
ok(byId[5004] == nil and byId[5005] == nil, "other mob + sub-floor excluded")
eq(drops[1].item, 5003, "sorted best first")
ok(#P.DropsFor(999, fakeDb, true) == 0, "unknown entry empty")

-- 3. Weighted picks, EPICS ONLY: rigged rng takes 20%+ hits, skips 2%.
-- Quality stub: 5003/5001 epic, 5002 blue (filtered even on a hit).
local function rigged(values)
  local i = 0
  return function(lo, hi) i = i + 1 return values[((i - 1) % #values) + 1] end
end
local qualities = { [5003] = 4, [5001] = 4, [5002] = 3 }
local function qual(id) return qualities[id] end
-- distinct first: r=100 -> 5003; r=600 over the live total (200, 5003
-- picked) is unmapped -> only 5003 distinct. Double draw over {5003}:
-- r=10 hits -> dupe. Sorted: 5003,5003.
local picks = P.PickDrops(drops, 4, rigged({ 100, 600, 10 }), qual)
eq(#picks, 2, "distinct pick plus one double")
eq(picks[1], 5003, "sorted best first")
eq(picks[2], 5003, "dupe adjacent")
-- full house: r=100 -> 5003; r=150 -> 5001; pool exhausted; double draw
-- r=10 over both -> 5003 dupes (5003's weight first).
local full = P.PickDrops(drops, 4, rigged({ 100, 150, 10 }), qual)
eq(#full, 3, "two distinct plus one double")
eq(full[1], 5003, "best first")
eq(full[3], 5001, "second kind present")
-- count cap respected.
local many = P.PickDrops(drops, 1, rigged({ 1 }), qual)
eq(#many, 1, "count cap")
-- blues never picked even when their roll hits.
local blueOnly = P.PickDrops(
  { { item = 5002, chance = 100 } }, 4, rigged({ 1 }), qual)
eq(#blueOnly, 0, "non-epic filtered")
-- duplicates: single-item pool -> one distinct + one double, never more.
local dupes = P.PickDrops(
  { { item = 5001, chance = 100 } }, 4,
  rigged({ 1, 1, 1, 1, 1, 1, 1, 1 }), qual)
eq(#dupes, 2, "up to two of the same item")
-- double-draw miss: distinct only, run still varies.
local nodup = P.PickDrops(
  { { item = 5001, chance = 50 }, { item = 5003, chance = 50 } }, 4,
  rigged({ 100, 100, 99999 }), qual)
eq(#nodup, 2, "distinct pair, double missed")

-- 4. BossDrops end-to-end (fake db injected, no pfDB global needed).
local boss = P.BossDrops("Test Boss", 4, rigged({ 100, 150, 10 }), fakeDb, qual)
eq(#boss, 3, "boss epic drops picked (incl. double)")
eq(boss[1], 5003, "best drop first")
-- fresh loot every call: r=600 -> 5001 (600<=700); r=150 over {5003} ->
-- 5003; double draw r=900 over {5001,5003} total 700: unmapped, no double.
-- Result 5003,5001: varies run to run.
local boss2 = P.BossDrops("Test Boss", 4,
  rigged({ 600, 150, 900 }), fakeDb, qual)
eq(#boss2, 2, "re-rolled loot differs")
eq(boss2[1], 5003, "sorted best first")
eq(boss2[2], 5001, "second kind, no forced double")
ok(#P.BossDrops("Nobody", 4, rigged({ 1 }), fakeDb) == 0, "unknown boss empty")

-- 5. No pfQuest at all: everything degrades to nil/empty (simboss falls
-- back to BossData.lua, never errors).
pfDB = nil
P.index = nil
ok(P.EntryIdByName("Test Boss") == nil, "no pfDB: no entry")
ok(#P.DropsFor(101) == 0, "no pfDB: no drops")
ok(#P.BossDrops("Test Boss") == 0, "no pfDB: no boss drops")

return T
