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
-- EPIC pool (weights = chance%). A RANDOM distinct count first — a real
-- kill drops 2-4 items, not every eligible epic; then a single extra draw
-- may double ONE of them (double drops happen, but rarely dominate). The
-- random count is what keeps consecutive runs varied even when the epic
-- pool is small (e.g. exactly four Ragnaros epics: always filling to the
-- cap would return the same set every time). rng(lo,hi) injectable (tests
-- rig it, honoring [lo,hi]); qualityFn injectable (tests stub it). Final
-- order is best-chance-first (dupes adjacent) for a stable display.
-- Returns a random-count subset of the epic pool (+ maybe one double).
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
