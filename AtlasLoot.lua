-- ZugLoot/AtlasLoot.lua
-- Live Atlas-CFM loot source for /zl simboss and /zl simraid.
-- Drop chances are read STRAIGHT from the game (AtlasCFM.InstanceData,
-- the same tables the Atlas-CFM loot browser shows, with their dropRate
-- percents) — nothing is copied into this project. Atlas-CFM is an
-- OPTIONAL dependency: without it loaded every lookup returns empty and
-- the sim commands refuse with a pointer (never errors).
--
-- Atlas-CFM data shape (post-init, what we read):
--   AtlasCFM.InstanceData[raidKey] = { Name, Acronym, MaxPlayers, Bosses = {
--     { id = "Ragnaros", name = "Ragnaros", defaults = { dropRate = 20 },
--       items = { { id = 17063 }, { id = 17076, dropRate = 8 }, ... } }, ...
--     { id = "MCTrash", name = "Trash Mobs-Molten Core", ... },  -- trash mobs
--     { name = "Tier 1 Sets", items = "AtlasCFMLootT1SetMenu" }, -- menu link, skipped
--   } }
-- Bosses without an explicit dropRate inherit their boss defaults; items
-- with no usable rate anywhere get a small floor so every listed drop
-- stays possible. Each entry is an INDEPENDENT chance roll per run (a
-- 13% tier piece drops ~1 run in 8, a 100% quest item always) — this is a
-- drop simulation, not a pick-N raffle.
-- Pure logic is headless-testable by injecting a fake AtlasCFM global;
-- only M.Data() reads the live addon table.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.AtlasLoot = M

-- Floor rate (%) for listed items with no usable rate (no dropRate and no
-- boss defaults). Keeps rateless-but-listed drops possible, just rare.
M.FLOOR_RATE = 0.5
-- Safety caps per roll (a 100%-heavy table can't flood the loot window).
M.MAX_BOSS_DROPS = 8
M.MAX_TRASH_DROPS = 12
-- Only epic+ loot is simulated (quality >= 4). Unknown/uncached quality
-- (nil) is treated as loot-worthy rather than silently dropped, so Turtle
-- custom epics survive a cold item cache.
M.WANT_QUALITY = 4

function M.Data()
  if AtlasCFM and AtlasCFM.InstanceData then
    return AtlasCFM.InstanceData
  end
  return nil -- Atlas-CFM not loaded: every lookup below degrades to empty
end

function M.Available()
  return M.Data() ~= nil
end

local function lower(s) return string.lower(tostring(s or "")) end

-- Server visibility: Atlas-CFM knows which entries exist on this server
-- (Turtle vs Vanilla+ item variants). Used when offered, else visible.
local function visible(entry)
  if AtlasCFM and AtlasCFM.Server and AtlasCFM.Server.IsVisible then
    local ok, v = pcall(AtlasCFM.Server.IsVisible, entry)
    if ok then return v end
  end
  return true
end

-- Quality gate via the live client cache (GetItemInfo). Injectable for
-- tests. Nil-safe: unknown/uncached -> worthy (callers decide nothing).
local function worthy(itemID, qualityFn)
  local q = nil
  if qualityFn then
    local ok, qq = pcall(qualityFn, itemID)
    if ok then q = qq end
  elseif GetItemInfo then
    local ok, _, _, qq = pcall(GetItemInfo, itemID)
    if ok then q = qq end
  end
  return q == nil or q >= M.WANT_QUALITY
end

-- Numeric-id loot entries of one boss table (post-init .items or raw
-- .loot — both are arrays of { id, dropRate, ... }). Skips separators,
-- menu links (items as string), and nil holes from empty {} rows.
function M.BossItems(boss)
  local out = {}
  if type(boss) ~= "table" then return out end
  local src = boss.items or boss.loot
  if type(src) ~= "table" then return out end
  for _, e in pairs(src) do
    if type(e) == "table" and type(e.id) == "number" then
      table.insert(out, e)
    end
  end
  return out
end

-- Trash-mob tables carry ids like MCTrash/BFDTrash/GNOutsideTrash.
function M.IsTrash(boss)
  if type(boss) ~= "table" then return false end
  return string.find(tostring(boss.id or ""), "Trash$") ~= nil
end

-- Effective drop rate (%): entry dropRate -> boss defaults -> floor,
-- clamped to 0..100. Quantities ({2,3}) don't change the roll: one entry
-- is one roll, win or miss.
function M.RateOf(entry, boss)
  local r = entry.dropRate
  if r == nil and type(boss) == "table" and type(boss.defaults) == "table" then
    r = boss.defaults.dropRate
  end
  if r == nil then r = M.FLOOR_RATE end
  r = tonumber(r) or 0
  if r < 0 then r = 0 elseif r > 100 then r = 100 end
  return r
end

-- Roll one loot table: every loot-worthy visible entry gets an independent
-- chance roll (rng(1,10000) <= rate*100). Sorted by itemID for a stable
-- display. rng(lo,hi) must honor [lo,hi] (math.random does; test rigs must
-- too). Returns itemIDs, capped.
function M.RollTable(entries, boss, cap, rng, qualityFn)
  rng = rng or function(lo, hi) return math.random(lo, hi) end
  cap = cap or M.MAX_BOSS_DROPS
  local sorted = {}
  for i = 1, Z.Util.ArrayCount(entries or {}) do sorted[i] = entries[i] end
  table.sort(sorted, function(a, b) return (a.id or 0) < (b.id or 0) end)
  local out = {}
  for i = 1, Z.Util.ArrayCount(sorted) do
    if Z.Util.ArrayCount(out) >= cap then break end
    local e = sorted[i]
    if e and visible(e) and worthy(e.id, qualityFn) then
      local rate = M.RateOf(e, boss)
      if rate > 0 and rng(1, 10000) <= rate * 100 then
        table.insert(out, e.id)
      end
    end
  end
  return out
end

-- Every instance with a boss list, raids (10/20/40) first, then by name.
function M.ListRaids()
  local data = M.Data()
  if not data then return {} end
  local out = {}
  for key, inst in pairs(data) do
    if type(inst) == "table" and inst.Name and inst.Bosses then
      local mp = tonumber(inst.MaxPlayers) or 0
      table.insert(out, { key = key, name = inst.Name,
        acronym = inst.Acronym, maxPlayers = mp,
        raid = (mp == 10 or mp == 20 or mp == 40) })
    end
  end
  table.sort(out, function(a, b)
    if a.raid ~= b.raid then return a.raid end
    return lower(a.name) < lower(b.name)
  end)
  return out
end

-- Match a raid by key, localized name, or acronym (exact first, then
-- substring). Returns key, instance or nil.
function M.FindRaid(text)
  local data = M.Data()
  if not data then return nil end
  text = Z.Util.Trim(text or "")
  if text == "" then return nil end
  local want = lower(text)
  local raids = M.ListRaids()
  for i = 1, Z.Util.ArrayCount(raids) do
    local r = raids[i]
    if lower(r.key) == want or lower(r.name) == want
        or lower(r.acronym) == want then
      return r.key, data[r.key]
    end
  end
  for i = 1, Z.Util.ArrayCount(raids) do
    local r = raids[i]
    if string.find(lower(r.key), want, 1, true)
        or string.find(lower(r.name), want, 1, true)
        or string.find(lower(r.acronym), want, 1, true) then
      return r.key, data[r.key]
    end
  end
  return nil
end

-- Boss display names of one raid, in table order. Skips trash-mob tables,
-- set-menu links, and entries with no rollable (numeric-id) drops.
function M.BossNames(raidKey)
  local data = M.Data()
  if not data then return {} end
  local inst = data[raidKey]
  if not inst or not inst.Bosses then return {} end
  local out = {}
  for i = 1, Z.Util.ArrayCount(inst.Bosses) do
    local b = inst.Bosses[i]
    if b and not M.IsTrash(b) and b.name
        and Z.Util.ArrayCount(M.BossItems(b)) > 0 then
      table.insert(out, b.name)
    end
  end
  return out
end

-- Find one boss table inside a raid by name or id (exact, then substring).
function M.FindRaidBoss(raidKey, text)
  local data = M.Data()
  if not data then return nil end
  local inst = data[raidKey]
  if not inst or not inst.Bosses then return nil end
  text = Z.Util.Trim(text or "")
  if text == "" then return nil end
  local want = lower(text)
  local bosses = inst.Bosses
  for i = 1, Z.Util.ArrayCount(bosses) do
    local b = bosses[i]
    if b and (lower(b.name) == want or lower(b.id) == want) then
      return b
    end
  end
  for i = 1, Z.Util.ArrayCount(bosses) do
    local b = bosses[i]
    if b and (string.find(lower(b.name or ""), want, 1, true)
        or string.find(lower(b.id or ""), want, 1, true)) then
      return b
    end
  end
  return nil
end

-- Find a boss across ALL raids (exact name/id first, then substring).
-- Returns raidKey, boss or nil. Deterministic: raids in ListRaids order.
function M.FindBoss(text)
  local data = M.Data()
  if not data then return nil end
  text = Z.Util.Trim(text or "")
  if text == "" then return nil end
  local raids = M.ListRaids()
  for i = 1, Z.Util.ArrayCount(raids) do
    local b = M.FindRaidBoss(raids[i].key, text)
    -- Exact-hit pass only: substring matches wait for the second pass so
    -- "Onyxia" never loses to an earlier raid's "Onyxia's Lair Trash".
    if b and (lower(b.name) == lower(text) or lower(b.id) == lower(text)) then
      return raids[i].key, b
    end
  end
  for i = 1, Z.Util.ArrayCount(raids) do
    local b = M.FindRaidBoss(raids[i].key, text)
    if b then return raids[i].key, b end
  end
  return nil
end

-- Roll one boss's drops (opts: count, rng, qualityFn).
function M.BossDrops(raidKey, bossName, opts)
  opts = opts or {}
  local boss = M.FindRaidBoss(raidKey, bossName)
  if not boss then return {} end
  return M.RollTable(M.BossItems(boss), boss,
    opts.count or M.MAX_BOSS_DROPS, opts.rng, opts.qualityFn)
end

-- The raid's trash-mob table (id *Trash), if any.
function M.TrashEntry(raidKey)
  local data = M.Data()
  if not data then return nil end
  local inst = data[raidKey]
  if not inst or not inst.Bosses then return nil end
  for i = 1, Z.Util.ArrayCount(inst.Bosses) do
    local b = inst.Bosses[i]
    if b and M.IsTrash(b)
        and Z.Util.ArrayCount(M.BossItems(b)) > 0 then
      return b
    end
  end
  return nil
end

-- Roll one trash batch (opts: count, rng, qualityFn).
function M.TrashDrops(raidKey, opts)
  opts = opts or {}
  local trash = M.TrashEntry(raidKey)
  if not trash then return {} end
  return M.RollTable(M.BossItems(trash), trash,
    opts.count or M.MAX_TRASH_DROPS, opts.rng, opts.qualityFn)
end

-- Trash-pack weights P(0..3 trash drops before a boss): almost always
-- exactly 1 (one mob's loot), sometimes 0/2/3.
M.TRASH_PACK_WEIGHTS = { 1, 7, 1, 1 }

-- How many trash drops precede a boss: weighted 0..3 (rng injectable).
function M.TrashPackCount(rng)
  rng = rng or function(lo, hi) return math.random(lo, hi) end
  local total = 0
  for k = 0, 3 do total = total + (M.TRASH_PACK_WEIGHTS[k + 1] or 0) end
  if total <= 0 then return 1 end
  local r, acc = rng(1, total), 0
  for k = 0, 3 do
    acc = acc + (M.TRASH_PACK_WEIGHTS[k + 1] or 0)
    if r <= acc then return k end
  end
  return 1
end

-- One trash pack: roll the trash table, keep up to the pack count (0-3,
-- almost always 1). Fewer rolled drops than the count simply yields
-- fewer — a pack is what the mobs dropped, not a quota.
function M.TrashPack(raidKey, opts)
  opts = opts or {}
  local k = M.TrashPackCount(opts.rng)
  if k <= 0 then return {} end
  local drops = M.TrashDrops(raidKey, opts)
  local out = {}
  local n = math.min(k, Z.Util.ArrayCount(drops))
  for i = 1, n do out[i] = drops[i] end
  return out
end
