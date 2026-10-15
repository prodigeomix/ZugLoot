-- tests/test_atlasloot.lua
-- Atlas-CFM live loot source: drops are read from the GAME's AtlasCFM
-- tables (injected fake here), never copied. Independent per-entry chance
-- rolls off dropRate — a re-roll of the same boss varies by design.
-- No AtlasCFM global = empty results, never errors.
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
ZugLoot.Util = ZugLoot.Util or dofile("Util.lua")

-- Fake AtlasCFM slice: bosses (explicit + inherited + rateless rates),
-- a trash table, a set-menu link, a holey table.
AtlasCFM = {
  InstanceData = {
    MoltenCore = { Name = "Molten Core", Acronym = "MC", MaxPlayers = 40,
      Bosses = {
        { id = "Ragnaros", name = "Ragnaros", defaults = { dropRate = 20 },
          items = {
            { id = 5001 },                       -- inherits 20
            { id = 5002, dropRate = 8 },
            { id = 5003, dropRate = 100 },       -- always
            { id = 5004, dropRate = 0 },         -- never
            { name = "Tier 1 Sets" },            -- header: no id, skipped
          } },
        { id = "Lucifron", name = "Lucifron",
          items = { { id = 5005 }, { id = 5006, dropRate = 50 } } },
        { id = "MCTrash", name = "Trash Mobs-Molten Core",
          defaults = { dropRate = 0.3 },
          items = { { id = 5007 }, { id = 5008, dropRate = 100 } } },
        { name = "Tier 1 Sets", items = "AtlasCFMLootT1SetMenu" },
      } },
    Deadmines = { Name = "The Deadmines MaxPlayers = 5",
      Bosses = { { id = "VanCleef", name = "Edwin VanCleef",
        items = { { id = 6001, dropRate = 100 } } } } },
  },
}
-- Fix the Deadmines typo above (deliberate: keep the fixture literal).
AtlasCFM.InstanceData.Deadmines.Name = "The Deadmines"
AtlasCFM.InstanceData.Deadmines.MaxPlayers = 5

GetItemInfo = function() return "n", "l", 4 end -- all epic
dofile("AtlasLoot.lua")
local A = ZugLoot.AtlasLoot

local function rigged(values)
  local i = 0
  return function(lo, hi)
    i = i + 1
    local v = values[((i - 1) % #values) + 1]
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
  end
end
local function epicQ() return 4 end

ok(A.Available(), "fake AtlasCFM detected")

-- 1. Raids: raid-first ordering; find by key/name/acronym/partial.
local raids = A.ListRaids()
eq(#raids, 2, "two instances listed")
eq(raids[1].key, "MoltenCore", "raid first")
eq(raids[2].key, "Deadmines", "dungeon last")
local k = A.FindRaid("MoltenCore")
eq(k, "MoltenCore", "raid by key")
local k2 = A.FindRaid("molten core")
eq(k2, "MoltenCore", "raid by name, case-insensitive")
local k3 = A.FindRaid("mc")
eq(k3, "MoltenCore", "raid by acronym")
local k4 = A.FindRaid("deadmine")
eq(k4, "Deadmines", "raid by partial")
eq(A.FindRaid("Nope"), nil, "unknown raid nil")
eq(A.FindRaid(""), nil, "empty raid nil")

-- 2. Boss names: trash + menu links skipped, order kept.
local names = A.BossNames("MoltenCore")
eq(#names, 2, "two real bosses")
eq(names[1], "Ragnaros", "first boss")
eq(names[2], "Lucifron", "second boss")
eq(#A.BossNames("Nope"), 0, "unknown raid no bosses")

-- 3. FindBoss: exact across raids, substring fallback.
local fk, fb = A.FindBoss("Ragnaros")
eq(fk, "MoltenCore", "exact boss raid")
eq(fb.id, "Ragnaros", "exact boss entry")
local fk2, fb2 = A.FindBoss("edwin vancleef")
eq(fk2, "Deadmines", "case-insensitive cross-raid")
eq(fb2.id, "VanCleef", "cross-raid entry")
local fk3 = A.FindBoss("ragna")
eq(fk3, "MoltenCore", "substring fallback")
eq(A.FindBoss("Nobody"), nil, "unknown boss nil")

-- 4. Rates: explicit -> defaults -> floor, clamped.
local rag = A.FindRaidBoss("MoltenCore", "Ragnaros")
eq(A.RateOf({ dropRate = 8 }, rag), 8, "explicit rate")
eq(A.RateOf({}, rag), 20, "boss defaults inherited")
local luc = A.FindRaidBoss("MoltenCore", "Lucifron")
eq(A.RateOf({ id = 5005 }, luc), A.FLOOR_RATE, "rateless gets the floor")
eq(A.RateOf({ dropRate = 500 }, rag), 100, "rate clamped high")
eq(A.RateOf({ dropRate = -5 }, rag), 0, "rate clamped low")

-- 5. RollTable: independent rolls (rng <= rate*100 in basis points).
-- Order sorted: 5002 (8%: 8000 > 800) misses, 5001 (20%) + 5003 (100%) hit.
local rolled = A.RollTable(A.BossItems(rag), rag, 8, rigged({ 2000, 8000, 1, 1 }), epicQ)
eq(#rolled, 2, "two hits")
eq(rolled[1], 5001, "sorted first")
eq(rolled[2], 5003, "sorted second")
-- 0% never drops; floor rate hits on a 1.
local floored = A.RollTable({ { id = 5005 } }, luc, 8, rigged({ 1 }), epicQ)
eq(#floored, 1, "floor rate possible")
eq(floored[1], 5005, "floor item")
local zero = A.RollTable({ { id = 5004, dropRate = 0 } }, rag, 8, rigged({ 1 }), epicQ)
eq(#zero, 0, "zero rate never drops")
-- Quality gate: blues skipped, nil quality kept (cold cache customs).
local gated = A.RollTable({ { id = 5001, dropRate = 100 }, { id = 5002, dropRate = 100 } }, rag, 8,
  rigged({ 1, 1 }), function(id) if id == 5001 then return 3 end return 4 end)
eq(#gated, 1, "blue filtered")
eq(gated[1], 5002, "epic kept")
local cold = A.RollTable({ { id = 5001, dropRate = 100 } }, rag, 8, rigged({ 1 }),
  function() return nil end)
eq(#cold, 1, "nil quality kept")
-- Cap respected.
local capped = A.RollTable(A.BossItems(rag), rag, 1, rigged({ 1, 1, 1 }), epicQ)
eq(#capped, 1, "cap respected")
eq(capped[1], 5001, "cap keeps lowest id")

-- 6. BossDrops / TrashDrops end-to-end (rng(1,10000) per entry).
local bd = A.BossDrops("MoltenCore", "Ragnaros", { rng = rigged({ 2000, 8000, 1, 1 }), qualityFn = epicQ })
eq(#bd, 2, "boss drops rolled")
eq(bd[1], 5001, "boss drop sorted")
local td = A.TrashDrops("MoltenCore", { rng = rigged({ 10001, 1 }), qualityFn = epicQ })
eq(#td, 1, " Trash 0.3% missed, 100% hit")
eq(td[1], 5008, "trash 100% item")
eq(#A.TrashDrops("Deadmines", { rng = rigged({ 1 }), qualityFn = epicQ }), 0, "no trash table empty")
eq(#A.BossDrops("MoltenCore", "Nobody", {}), 0, "unknown boss empty")

-- 7. RaidDrops: boss order, trash between bosses, empties skipped.
-- Ragnaros hits 5001+5003, trash hits 5008, Lucifron all-miss.
local groups = A.RaidDrops("MoltenCore", { rng = rigged({ 1, 10001, 1, 10001, 1, 10001, 10001 }), qualityFn = epicQ })
eq(#groups, 2, "hitting groups only")
eq(groups[1].boss, "Ragnaros", "boss order")
eq(#groups[1].drops, 2, "ragnaros drops")
ok(groups[2].trash, "trash flagged")
eq(groups[2].drops[1], 5008, "trash drop")
-- Near-miss raid: everything but the guaranteed (100%) drops misses —
-- the 100% entries still land (a value above the range would clamp to a
-- hit, so rig 9999: misses every real chance, hits only 100% entries).
local none = A.RaidDrops("MoltenCore", { rng = rigged({ 9999 }), qualityFn = epicQ })
eq(#none, 2, "near-miss keeps guaranteed groups")
eq(none[1].drops[1], 5003, "boss 100% item survives")
eq(none[2].drops[1], 5008, "trash 100% item survives")

-- 8. No Atlas-CFM: everything degrades to empty, never errors.
AtlasCFM = nil
A = ZugLoot.AtlasLoot
ok(not A.Available(), "absent addon detected")
eq(#A.ListRaids(), 0, "no raids")
eq(A.FindRaid("mc"), nil, "no raid find")
eq(#A.BossNames("MoltenCore"), 0, "no boss names")
eq(A.FindBoss("Ragnaros"), nil, "no boss")
eq(#A.BossDrops("MoltenCore", "Ragnaros", {}), 0, "no boss drops")
eq(#A.TrashDrops("MoltenCore", {}), 0, "no trash")
eq(#A.RaidDrops("MoltenCore", {}), 0, "no raid drops")

return T
