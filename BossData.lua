-- ZugLoot/BossData.lua
-- Minimal boss -> loot tables for /zl simboss. Extend per raid tier.
-- Fallback only (pfQuest rolls weighted drops when loaded): simboss draws a
-- RANDOM re-rolled subset per run (pfLoot.PickStaticDrops), so the tables
-- below are candidate pools, not fixed drop lists.
ZugLoot = ZugLoot or {}
ZugLoot.BossData = {
  -- Molten Core samples (itemIDs are examples; replace with real drops).
  ["Ragnaros"] = { 17063, 17076, 17102 },
  ["Onyxia"] = { 17063, 17204, 18290 },
  ["TestBoss"] = { 1001, 1002, 1003 },
}
