-- ZugLoot/pfLoot.lua
-- pfQuest loot lookup for /zl simboss (Rarescanner pattern): resolve a boss
-- name to its pfDB unit entry, then roll random drops from its loot table.
--
-- Data path (mirrors Rarescanner §§6/9a): an item drops from a unit either
-- directly (pfDB.items.data[itemId].U[unitId] = chance%) or via a
-- reference-loot table (item.data.R[refId] -> pfDB.refloot.data[refId].U).
-- All pfDB access is nil-guarded: without pfQuest loaded every lookup
-- returns nil/{} and simboss falls back to BossData.lua (never errors).
-- Pure logic (index build, weighted pick) is headless-testable by passing
-- a fake db table; only the default arg reads the live pfDB global.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.pfLoot = M

-- Noise floor like Rarescanner's LOOT_MIN_CHANCE: ultra-rare epics drop at
-- ~0.5% and must still be pickable.
M.MIN_CHANCE = 0.4
-- Sim drops per boss (a real boss drops a handful of roll-worthy items).
M.DROP_COUNT = 4
-- Only epics are simulated (quality 4). Duplicates allowed, up to two of
-- the same item (double drops happen).
M.WANT_QUALITY = 4
M.MAX_DUPES = 2

-- Item quality via the client cache (GetItemInfo). Injectable: tests pass
-- a stub, live uses the real API. Nil-safe: unknown/uncached -> nil.
function M.QualityOf(itemId, qualityFn)
  local fn = qualityFn or (GetItemInfo and function(id)
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
          if chance and chance >= M.MIN_CHANCE then
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
          if chance and chance >= M.MIN_CHANCE then
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

-- Weighted picks from a drop list: roulette draws over the eligible
-- EPIC pool (weights = chance%), DISTINCT first — a real kill drops
-- different items; then a single extra draw may double ONE of them
-- (double drops happen, but rarely dominate). Nothing is guaranteed —
-- even a 100% table entry can miss a run — so consecutive simboss runs
-- vary instead of repeating the same set. rng(lo,hi) injectable (tests
-- rig it); qualityFn injectable (tests stub it). Final order is
-- best-chance-first (dupes adjacent) for a stable loot-window display.
-- Returns up to `count` itemIds.
function M.PickDrops(drops, count, rng, qualityFn)
  rng = rng or function(lo, hi) return math.random(lo, hi) end
  count = count or M.DROP_COUNT
  -- Eligible pool: epics only.
  local pool = {}
  local n = Z.Util.ArrayCount(drops or {})
  for i = 1, n do
    local d = drops[i]
    if d and (d.chance or 0) >= M.MIN_CHANCE
        and M.QualityOf(d.item, qualityFn) == M.WANT_QUALITY then
      -- weight in 0.1% units (integers for rng): the 0.4% floor stays whole.
      table.insert(pool, { item = d.item, w = (d.chance or 0) * 10 })
    end
  end
  local m = Z.Util.ArrayCount(pool)
  if m == 0 or count <= 0 then return {} end
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
  while Z.Util.ArrayCount(out) < count do
    local id = draw(picked)
    if not id then break end
    table.insert(out, id)
    picked[id] = true
  end
  -- Then ONE double-drop draw over what dropped (rare, like live).
  if Z.Util.ArrayCount(out) > 0 and Z.Util.ArrayCount(out) < count + 1 then
    local again = {}
    for _, id in ipairs(out) do again[id] = true end
    -- re-roll the table once: only already-dropped items eligible.
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
            if Z.Util.ArrayCount(out) < count
                and (M.CountOf(out, pool[i].item) or 0) < M.MAX_DUPES then
              table.insert(out, pool[i].item)
            end
            break
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

-- Occurrences of v in an array-part table (5.0-safe).
function M.CountOf(t, v)
  local c = 0
  for i = 1, Z.Util.ArrayCount(t or {}) do
    if t[i] == v then c = c + 1 end
  end
  return c
end

-- Boss name -> random drop itemIds (the simboss source). Empty when pfQuest
-- is absent, the name is unknown, or nothing in the table rolls.
-- qualityFn threads through for tests (live: client GetItemInfo).
function M.BossDrops(name, count, rng, db, qualityFn)
  local entry = M.EntryIdByName(name, db)
  if not entry then return {} end
  local drops = M.DropsFor(entry, db)
  if Z.Util.ArrayCount(drops) == 0 then return {} end
  return M.PickDrops(drops, count or M.DROP_COUNT, rng, qualityFn)
end
