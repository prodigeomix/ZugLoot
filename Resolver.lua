-- ZugLoot/Resolver.lua
-- PURE roll resolution. No WoW API. Shared by live sessions, /zl sim, tests.
local M = {}

local function count(t)
  local n = 0
  if type(t) == "table" then while t[n + 1] ~= nil do n = n + 1 end end
  return n
end

-- effective = base + sr_plus
function M.Effective(base, srPlus)
  return (tonumber(base) or 0) + (tonumber(srPlus) or 0)
end

-- Build eligible entries for an item from the sheet.
-- sheetLike: { items = { [id] = { rollers = { {name, rolls, sr_plus} } } }, won = {...} }
-- rolls: { {name=..., roll=1..cap, type="SR"|...} } (chat rolls observed)
-- opts: { cap=100, requireSR=true, srPlusByName={name=bonus} }
-- Returns entries = { {name, base, sr_plus, effective, missroll=bool, excludedWon=bool} }
function M.BuildEntries(sheetLike, itemID, rolls, opts)
  opts = opts or {}
  local cap = opts.cap or 100
  local requireSR = opts.requireSR
  if requireSR == nil then requireSR = true end
  local srMap = {}
  local rollers = {}
  if sheetLike and sheetLike.items and sheetLike.items[itemID] then
    rollers = sheetLike.items[itemID].rollers or {}
  end
  local i = 1
  while rollers[i] ~= nil do
    local r = rollers[i]
    srMap[r.name] = { bonus = r.sr_plus or 0, rolls = r.rolls or 1 }
    i = i + 1
  end
  if opts.srPlusByName then
    for n, b in pairs(opts.srPlusByName) do
      srMap[n] = srMap[n] or { bonus = 0, rolls = 1 }
      srMap[n].bonus = b or 0
    end
  end
  local wonMap = {}
  if sheetLike and sheetLike.won and sheetLike.won[itemID] then wonMap = sheetLike.won[itemID] end
  local entries = {}
  local j = 1
  while rolls and rolls[j] ~= nil do
    local rv = rolls[j]
    local base = tonumber(rv.roll) or 0
    if base >= 1 and base <= cap then
      local info = srMap[rv.name]
      local isSR = info ~= nil
      local excluded = wonMap[rv.name] == true
      local miss = requireSR and not isSR
      table.insert(entries, {
        name = rv.name,
        base = base,
        sr_plus = isSR and info.bonus or 0,
        effective = M.Effective(base, isSR and info.bonus or 0),
        missroll = miss,
        excludedWon = excluded,
        rollType = rv.type or "SR",
      })
    end
    j = j + 1
  end
  return entries
end

-- Rank entries: winners first. Ignores missrolls + won-excluded for winning,
-- but keeps won-excluded rolls visible in `excluded` so later sessions show
-- who rolled while ineligible.
-- opts: { itemCount=1 }
-- Returns ranked (sorted desc by effective), winners (top itemCount distinct names),
--   tied (players tied at cutoff needing re-roll), missrolls + excluded (flagged lists).
function M.Resolve(entries, opts)
  opts = opts or {}
  local itemCount = opts.itemCount or 1
  local cand = {}
  local miss = {}
  local excluded = {}
  local k = 1
  while entries[k] ~= nil do
    local e = entries[k]
    if e.missroll then table.insert(miss, e)
    elseif e.excludedWon then table.insert(excluded, e)
    else table.insert(cand, e) end
    k = k + 1
  end
  -- keep best roll per player
  local best = {}
  for x = 1, count(cand) do
    local e = cand[x]
    if not best[e.name] or e.effective > best[e.name].effective then best[e.name] = e end
  end
  local ranked = {}
  for _, e in pairs(best) do table.insert(ranked, e) end
  table.sort(ranked, function(a, b)
    if a.effective ~= b.effective then return a.effective > b.effective end
    return (a.name or "") < (b.name or "")
  end)
  local winners = {}
  local tied = {}
  local n = count(ranked)
  if n > 0 and itemCount >= 1 then
    local c = 1
    while c <= itemCount and c <= n do winners[c] = ranked[c] c = c + 1 end
    -- tie at cutoff?
    local cutoff = winners[count(winners)].effective
    local t = itemCount + 1
    while t <= n and ranked[t].effective == cutoff do
      table.insert(tied, ranked[t])
      t = t + 1
    end
    if count(tied) > 0 then
      -- everyone at cutoff (winners sharing cutoff + overflow) must re-roll
      local c2 = itemCount
      while c2 >= 1 and winners[c2].effective == cutoff do
        table.insert(tied, winners[c2])
        c2 = c2 - 1
      end
    end
  end
  return { ranked = ranked, winners = winners, tied = tied, missrolls = miss, excluded = excluded }
end

-- One-call: build + resolve. Returns same as Resolve plus entries.
function M.ResolveItem(sheetLike, itemID, rolls, opts)
  local entries = M.BuildEntries(sheetLike, itemID, rolls, opts)
  local res = M.Resolve(entries, opts)
  res.entries = entries
  return res
end

-- Build a sheet.rolls history entry from a resolve result.
-- Shared by live sessions (MasterLootUI) and simulation (Sim) so both write
-- the same shape. Entries sorted by effective desc for top-down display.
function M.ToHistoryEntry(res, mode, t)
  local winNames = {}
  local winners = res.winners or {}
  local i = 1
  while winners[i] ~= nil do table.insert(winNames, winners[i].name) i = i + 1 end
  local src = res.entries or res.ranked or {}
  local entries = {}
  local j = 1
  while src[j] ~= nil do
    local e = src[j]
    table.insert(entries, { name = e.name, base = e.base, sr_plus = e.sr_plus or 0,
      effective = e.effective or e.base, missroll = e.missroll, excludedWon = e.excludedWon })
    j = j + 1
  end
  table.sort(entries, function(a, b)
    if (a.effective or 0) ~= (b.effective or 0) then return (a.effective or 0) > (b.effective or 0) end
    return tostring(a.name) < tostring(b.name)
  end)
  local miss = res.missrolls or {}
  local excl = res.excluded or {}
  -- Fallback: older results predate `excluded`; derive from entry flags.
  if count(excl) == 0 and count(src) > 0 then
    local j2 = 1
    while src[j2] ~= nil do
      if src[j2].excludedWon and not src[j2].missroll then table.insert(excl, src[j2]) end
      j2 = j2 + 1
    end
  end
  return { t = t or 0, mode = mode, winners = winNames, entries = entries,
    missrolls = count(miss), excluded = excl }
end

-- Simulate rolls for testing/sim: rollers roll 1..cap, extras are miss-rolls.
-- rng: function(lo,hi) default math.random. Returns rolls list.
-- opts.tmog = {names}: extra TMOG-typed entries (cap 98) for pass-along demos.
function M.FakeRolls(sheetLike, itemID, opts, rng)
  opts = opts or {}
  local cap = opts.cap or 100
  -- sheetOnly: roll just the sheet's own players (used by /zl sim so boss
  -- sims use players from the loaded sheet, no fake Filler/Missroller names).
  local fillers = opts.sheetOnly and 0 or (opts.fillers or 0)
  local missCount = opts.sheetOnly and 0 or (opts.missrolls or 1)
  rng = rng or function(lo, hi) return math.random(lo, hi) end
  local rolls = {}
  local rollers = {}
  if sheetLike and sheetLike.items and sheetLike.items[itemID] then
    rollers = sheetLike.items[itemID].rollers or {}
  end
  local i = 1
  while rollers[i] ~= nil do
    table.insert(rolls, { name = rollers[i].name, roll = rng(1, cap), type = "SR" })
    i = i + 1
  end
  for f = 1, fillers do
    table.insert(rolls, { name = "Filler" .. f, roll = rng(1, cap), type = "MS" })
  end
  -- miss-rollers: people without SR rolling on the SR item.
  for mm = 1, (fillers > 0 and 0 or missCount) do
    table.insert(rolls, { name = "Missroller" .. mm, roll = rng(1, cap), type = "MS" })
  end
  -- transmog rollers (cap 98): may win and pass the item along.
  if type(opts.tmog) == "table" then
    for t = 1, count(opts.tmog) do
      table.insert(rolls, { name = opts.tmog[t], roll = rng(1, 98), type = "TMOG" })
    end
  end
  return rolls
end

if ZugLoot then ZugLoot.Resolver = M end
return M
