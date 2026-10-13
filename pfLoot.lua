-- ZugLoot/pfLoot.lua
-- pfQuest loot lookup for /zl simboss: resolve a boss name to its pfDB
-- unit entry, then roll random drops from its FULL loot table.
--
-- Data path (pfQuest/Rarescanner): an item drops from a unit either
-- directly (pfDB.items.data[itemId].U[unitId] = chance%) or via a
-- reference-loot table (item.data.R[refId] -> pfDB.refloot.data[refId].U).
-- Many real boss drops live in refloot tables with chance 0 (unknown), so
-- the INDEX keeps every drop and PickDrops floors the weight: chance-0
-- items stay pickable but rarer than measured chances. Quality (epic+)
-- gates the final pool; unknown (uncached) quality is kept, not dropped.
-- All pfDB access is nil-guarded: without pfQuest loaded every lookup
-- returns nil/{} and simboss falls back to BossData.lua (never errors).
-- Pure logic (index build, weighted pick) is headless-testable by passing
-- a fake db table; only the default arg reads the live pfDB global.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.pfLoot = M

-- Weight floor for drop chances of 0/unknown (pfQuest lists many real
-- boss drops in refloot tables with chance 0). These must stay pickable
-- in a sim, just rarer than the items with a measured chance.
M.MIN_CHANCE = 0.4
-- Sim drops per boss (a real boss drops a handful of roll-worthy items).
M.DROP_COUNT = 4
-- Only epic+ loot is simulated (quality >= 4; legendary 5 included).
-- Unknown/uncached quality (nil) is treated as loot-worthy rather than
-- silently dropped, so Turtle custom epics survive.
M.WANT_QUALITY = 4
M.MAX_DUPES = 2

-- Item quality via the client cache (GetItemInfo). Mirrors Rarescanner:
-- set a tooltip hyperlink first so the client cache knows the item, then
-- read quality. Injectable: tests pass a stub. Nil-safe: unknown/uncached
-- -> nil (callers decide).
function M.QualityOf(itemId, qualityFn)
  local fn = qualityFn or (GetItemInfo and function(id)
    if GameTooltip and GameTooltip.SetHyperlink then
      pcall(GameTooltip.SetHyperlink, GameTooltip,
        "item:" .. tostring(id) .. ":0:0:0:0:0:0:0")
      if GameTooltip.Hide then GameTooltip:Hide() end
    end
    local ok, _, _, q = pcall(GetItemInfo, id)
    if ok then return q end
    return nil
  end)
  if not fn then return nil end
  local ok, q = pcall(fn, itemId)
  if ok then return q end
  return nil
end

function M.Db()
  return pfDB -- nil when pfQuest is not loaded; every fn below tolerates that
end

-- Boss name -> unit entry id. Searches ALL units (not just rares — bosses
-- are rarely flagged rare), matching pfDB.units.loc (localized name).
-- Returns entry id or nil.
function M.EntryIdByName(name, db)
  db = db or M.Db()
  if not db or not db.units or not db.units.loc then return nil end
  if not name or name == "" then return nil end
  local want = string.lower(tostring(name))
  for entry, loc in pairs(db.units.loc) do
    if loc and string.lower(loc) == want then
      return entry
    end
  end
  return nil
end

-- Localized display name for an entry ("Unknown" fallback, Rarescanner §9a).
function M.NameOf(entry, db)
  db = db or M.Db()
  if db and db.units and db.units.loc and db.units.loc[entry] then
    return db.units.loc[entry]
  end
  return "Unknown"
end

-- Inverted index: unit entry id -> {itemId = chance}. Built once and cached
-- on the module (M.index); pass reset=true in tests to rebuild.
-- Includes EVERY drop (direct + refloot) regardless of chance: bosses like
-- Ragnaros list most of their real epics in refloot tables with chance 0
-- (unknown), and a noise floor here would shrink the sim pool to a handful
-- of items. The floor lives in PickDrops as a WEIGHT floor instead, so
-- chance-0 items are still pickable but rare.
function M.BuildIndex(db)
  db = db or M.Db()
  local index = {}
  if not db or not db.items or not db.items.data
      or not db.refloot or not db.refloot.data then
    return index
  end
  for itemId, d in pairs(db.items.data) do
    if type(d) == "table" then
      if d.U then
        for unitId, chance in pairs(d.U) do
          if chance ~= nil then
            index[unitId] = index[unitId] or {}
            local cur = index[unitId][itemId]
            if not cur or chance > cur then
              index[unitId][itemId] = chance
            end
          end
        end
      end
      if d.R then
        for refId, chance in pairs(d.R) do
          if chance ~= nil then
            local ref = db.refloot.data[refId]
            if ref and ref.U then
              for unitId in pairs(ref.U) do
                index[unitId] = index[unitId] or {}
                local cur = index[unitId][itemId]
                if not cur or chance > cur then
                  index[unitId][itemId] = chance
                end
              end
            end
          end
        end
      end
    end
  end
  return index
end

function M.Index(db, reset)
  if reset or not M.index then
    M.index = M.BuildIndex(db)
  end
  return M.index
end

-- Grouped drops for a unit entry: the boss's loot TABLES, each with its
-- members. A boss doesn't drop "the top 4 by chance%" — it drops a few
-- items from each of its loot tables (weapon table, armor table, tier
-- table, ...). Each group is one refloot table covering this unit
-- (R members) or the direct-U remainder (chance > 0 items that belong to
-- no table covering this unit). Returns
-- { { items={ {item, chance}... }, ref=<refId or 0> }... }.
-- An item shared by several tables for the same unit (e.g. tier pants in
-- both 30547 and 30484) lives in EACH of them — it is a real member of
-- both, never deduplicated away. `chance` is informational only; the
-- per-run per-table hit decides how many of a table's members drop, so
-- individual chances never need to be "real" percentages.
function M.DropGroups(entry, db, reset)
  if not entry then return {} end
  db = db or M.Db()
  if not db or not db.items or not db.items.data
      or not db.refloot or not db.refloot.data then
    return {} end
  if reset or not M.index then
    M.index = M.BuildIndex(db)
  end
  local items, refloot = db.items.data, db.refloot.data
  local groups = {}   -- [refKey] = { ref=refKey, items={...} }, refKey 0 = direct
  -- ref membership first: an item lives in EVERY table covering this unit
  for itemId, d in pairs(items) do
    if type(d) == "table" and d.R then
      for refId in pairs(d.R) do
        local ref = refloot[refId]
        if ref and type(ref) == "table" and ref.U and ref.U[entry] then
          groups[refId] = groups[refId] or { ref = refId, items = {} }
          table.insert(groups[refId].items, itemId)
        end
      end
    end
  end
  -- Direct-U remainder: only items in NO covering table. Chance 0 members
  -- of the junk group (ref 30171 belongs to nobody's real table) would
  -- double-count everything, so the remainder is chance-0-excluded.
  local inTable = {}
  for _, g in pairs(groups) do
    for i = 1, Z.Util.ArrayCount(g.items) do inTable[g.items[i]] = true end
  end
  for itemId, d in pairs(items) do
    if type(d) == "table" and not inTable[itemId] then
      if d.U and d.U[entry] and (d.U[entry] or 0) > 0 then
        groups[0] = groups[0] or { ref = 0, items = {} }
        table.insert(groups[0].items, itemId)
      end
    end
  end
  local out = {}
  for _, g in pairs(groups) do
    table.sort(g.items)
    if Z.Util.ArrayCount(g.items) > 0 then table.insert(out, g) end
  end
  -- Deterministic order: direct-U group first, then ref tables ascending.
  table.sort(out, function(a, b) return (a.ref or 0) < (b.ref or 0) end)
  return out
end

-- All drops for a unit entry: sorted { {item=itemId, chance}... } best first.
function M.DropsFor(entry, db, reset)
  if not entry then return {} end
  local byItem = M.Index(db, reset)[entry]
  if not byItem then return {} end
  local list = {}
  for itemId, chance in pairs(byItem) do
    table.insert(list, { item = itemId, chance = chance })
  end
  table.sort(list, function(a, b) return a.chance > b.chance end)
  return list
end

-- Weighted picks from a unit's grouped loot TABLES: one roll per table
-- (each boss loot table contributes ~1 drop, so tier-2 pants show up as
-- often as weapons). The old routine rolled once over a single weighted
-- pool, which favored frequent table-mates and starved whole tables.
-- `groups` comes from DropGroups; rng(lo,hi) injectable (tests rig it,
-- honoring [lo,hi]); qualityFn injectable (tests stub it). Within a table
-- the member is a uniform pick of the loot-worthy (epic+/unknown-quality)
-- members — per-item chances in pfQuest are data-mixed (some tables carry
-- real %, some carry 0), so they must not gate membership. Caller caps the
-- total: draws while `Z.Util.ArrayCount(out) < count`, tables roll in
-- group order (direct-U first, then ref tables), so a big count still
-- reaches every table. Dupes: up to MAX_DUPES per item. Returns itemIds.
function M.PickGroupDrops(groups, count, rng, qualityFn)
  rng = rng or function(lo, hi) return math.random(lo, hi) end
  count = count or M.DROP_COUNT
  local ng = Z.Util.ArrayCount(groups or {})
  if ng == 0 or count <= 0 then return {} end
  -- Loot-worthy members per table (epic+; nil quality kept for Turtle
  -- customs). Junk table-mates (cached green/blue) never win their slot.
  -- The junk shared group (ref 30171 belongs to NOBODY's real loot table)
  -- is capped at one hit per kill: its epics stay possible, but the
  -- 76-strong green army can no longer flood the window.
  local tables = {}
  for gi = 1, ng do
    local g = groups[gi]
    local members = {}
    for mi = 1, Z.Util.ArrayCount(g.items or {}) do
      local id = g.items[mi]
      local q = M.QualityOf(id, qualityFn)
      if q == nil or q >= M.WANT_QUALITY then
        table.insert(members, id)
      end
    end
    if Z.Util.ArrayCount(members) > 0 then
      table.insert(tables, { members = members, junkShared = (g.ref == 30171) })
    end
  end
  local nt = Z.Util.ArrayCount(tables)
  if nt == 0 then return {} end
  -- Each table contributes up to two hits while room lasts: first pass one
  -- per table (every table shows up), second pass one more per table
  -- (multiple pairs of pants happen — that's a real Ragnaros), dupes of
  -- the same member capped at MAX_DUPES. The junk shared table is capped
  -- at ONE hit total.
  local out, hits, junkHits = {}, {}, 0
  for pass = 1, 2 do
    for ti = 1, nt do
      if Z.Util.ArrayCount(out) >= count then break end
      local t = tables[ti]
      if (hits[ti] or 0) < pass
          and not (t.junkShared and junkHits >= 1) then
        local members = t.members
        local nm = Z.Util.ArrayCount(members)
        local tries, pick = 0, nil
        while tries < nm do
          local cand = members[rng(1, nm)]
          tries = tries + 1
          if (M.CountOf(out, cand) or 0) < M.MAX_DUPES then
            pick = cand
            break
          end
        end
        if pick then
          table.insert(out, pick)
          hits[ti] = (hits[ti] or 0) + 1
          if t.junkShared then junkHits = junkHits + 1 end
        end
      end
    end
    if Z.Util.ArrayCount(out) >= count then break end
  end
  return out
end

-- Weighted picks from a drop list: roulette draws over the eligible
-- EPIC pool (weights = chance%). A RANDOM distinct count first — a real
-- kill drops 2-4 items, not every eligible epic; then a single extra draw
-- may double ONE of them (double drops happen, but rarely dominate). The
-- random count is what keeps consecutive runs varied even when the epic
-- pool is small (e.g. exactly four Ragnaros epics: always filling to the
-- cap would return the same set every time). rng(lo,hi) injectable (tests
-- rig it, honoring [lo,hi]); qualityFn injectable (tests stub it). Final
-- order is best-chance-first (dupes adjacent) for a stable display.
-- Returns a random-count subset of the epic pool (+ maybe one double).
-- Legacy path: kept for the no-table fallback (BossDrops callers that pass
-- a bare drop list); the boss sim itself uses PickGroupDrops + DropGroups.
function M.PickDrops(drops, count, rng, qualityFn)
  rng = rng or function(lo, hi) return math.random(lo, hi) end
  count = count or M.DROP_COUNT
  -- Eligible pool: epic+ loot. Unknown quality (nil) is kept — Turtle
  -- custom epics often aren't in the client cache yet. Weights floor at
  -- MIN_CHANCE so chance-0 refloot items (most real boss drops) are still
  -- pickable, just rarer than measured chances.
  local pool = {}
  local n = Z.Util.ArrayCount(drops or {})
  for i = 1, n do
    local d = drops[i]
    if d then
      local q = M.QualityOf(d.item, qualityFn)
      if q == nil or q >= M.WANT_QUALITY then
        local chance = d.chance or 0
        if chance < M.MIN_CHANCE then chance = M.MIN_CHANCE end
        -- weight in 0.1% units (integers for rng): the floor stays whole.
        table.insert(pool, { item = d.item, w = chance * 10 })
      end
    end
  end
  local m = Z.Util.ArrayCount(pool)
  if m == 0 or count <= 0 then return {} end
  -- Random distinct count: 2..min(count, m) for multi-item pools, 1 for a
  -- singleton. Clamped against a misbehaving rng.
  local maxK = math.min(count, m)
  local minK = math.min(2, maxK)
  local k = rng(minK, maxK)
  if k < minK then k = minK elseif k > maxK then k = maxK end
  -- One roulette draw over pool indexes in `skip` (already picked).
  local function draw(skip)
    local total = 0
    for i = 1, m do
      if not skip[pool[i].item] then total = total + pool[i].w end
    end
    if total <= 0 then return nil end
    local r, acc = rng(1, total), 0
    for i = 1, m do
      if not skip[pool[i].item] then
        acc = acc + pool[i].w
        if r <= acc then return pool[i].item end
      end
    end
    return nil
  end
  -- Distinct items first (a kill drops different loot).
  local out, picked = {}, {}
  while Z.Util.ArrayCount(out) < k do
    local id = draw(picked)
    if not id then break end
    table.insert(out, id)
    picked[id] = true
  end
  -- Then ONE possible double over what dropped (coin flip so doubles never
  -- dominate): only already-dropped items eligible, MAX_DUPES respected.
  if Z.Util.ArrayCount(out) > 0 and Z.Util.ArrayCount(out) < count then
    if rng(1, 2) == 1 then
      local total = 0
      for i = 1, m do
        if picked[pool[i].item] then total = total + pool[i].w end
      end
      if total > 0 then
        local r, acc = rng(1, total), 0
        for i = 1, m do
          if picked[pool[i].item] then
            acc = acc + pool[i].w
            if r <= acc then
              if (M.CountOf(out, pool[i].item) or 0) < M.MAX_DUPES then
                table.insert(out, pool[i].item)
              end
              break
            end
          end
        end
      end
    end
  end
  -- Stable display order: best chance first, dupes adjacent.
  local rank = {}
  for i = 1, m do rank[pool[i].item] = pool[i].w end
  table.sort(out, function(a, b)
    if rank[a] ~= rank[b] then return rank[a] > rank[b] end
    return a < b
  end)
  return out
end

-- Random draws from a STATIC boss table (BossData fallback, no chances):
-- shuffled distinct items, random count, then one possible double — the
-- same shape as PickDrops (distinct first like a real kill, doubles happen
-- but never dominate). Re-rolled every call so consecutive simboss runs
-- vary even without pfQuest (a fixed table would repeat the same list).
-- rng(lo,hi) must honor [lo,hi] (math.random does; test rigs must too).
-- Returns a random-count subset (2..cap for multi-item tables, the single
-- item for singletons), plus maybe one dupe (never more than MAX_DUPES).
function M.PickStaticDrops(list, count, rng)
  rng = rng or function(lo, hi) return math.random(lo, hi) end
  count = count or M.DROP_COUNT
  local n = Z.Util.ArrayCount(list or {})
  if n == 0 or count <= 0 then return {} end
  -- Fisher-Yates shuffle of positions (the input table is untouched).
  local idx = {}
  for i = 1, n do idx[i] = i end
  for i = n, 2, -1 do
    local j = rng(1, i)
    idx[i], idx[j] = idx[j], idx[i]
  end
  -- Random count: 2..cap when the table holds 2+ (a one-drop run wastes a
  -- manual test), else everything there is. Clamped so the contract holds
  -- even for a misbehaving rng.
  local maxk = math.min(count, n)
  local mink = math.min(2, maxk)
  local k = rng(mink, maxk)
  if k < mink then k = mink elseif k > maxk then k = maxk end
  local out = {}
  for i = 1, k do table.insert(out, list[idx[i]]) end
  -- One possible double of a picked item (room permitting): a coin flip
  -- keeps doubles from dominating, like the PickDrops re-roll that misses.
  if k < count and rng(1, 2) == 1 then
    table.insert(out, out[rng(1, k)])
  end
  return out
end

-- Occurrences of v in an array-part table (5.0-safe).
function M.CountOf(t, v)
  local c = 0
  for i = 1, Z.Util.ArrayCount(t or {}) do
    if t[i] == v then c = c + 1 end
  end
  return c
end

-- Boss name -> random drop itemIds (the simboss source). One hit per loot
-- table (tables are slots: weapon, armor, tier ...), so whole tables can't
-- starve. Empty when pfQuest is absent, the name is unknown, or every
-- table is empty of loot-worthy members. qualityFn threads through for
-- tests (live: client GetItemInfo, epic+/nil-kept).
function M.BossDrops(name, count, rng, db, qualityFn)
  local entry = M.EntryIdByName(name, db)
  if not entry then return {} end
  local groups = M.DropGroups(entry, db)
  if Z.Util.ArrayCount(groups) == 0 then return {} end
  return M.PickGroupDrops(groups, count or M.DROP_COUNT, rng, qualityFn)
end
