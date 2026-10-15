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

-- Roll-type rules: each type is judged by itself, in its own range.
-- SR 1-100 (sheet SR + sr_plus bonus), MS 1-100 (no bonus), OS 1-99,
-- TMOG 1-98. Priority order is SR > MS > OS; TMOG crowns its own kind
-- winner (directly awardable) but never takes an overall winner slot.
M.TYPE_ORDER = { "SR", "MS", "OS", "TMOG" }
M.TYPE_CAPS = { SR = 100, MS = 100, OS = 99, TMOG = 98 }

function M.TypeCap(rtype)
  return (M.TYPE_CAPS[rtype] or 100)
end

-- Build eligible entries for an item from the sheet.
-- sheetLike: { items = { [id] = { rollers = { {name, rolls, sr_plus} } } }, won = {...} }
-- rolls: { {name=..., roll=1..cap, type="SR"|...} } (chat rolls observed)
-- opts: { cap=100, srPlusByName={name=bonus} }
-- The sheet is INPUT, not a mode switch: it names who may claim SR and
-- carries the SR+ bonus. An empty/missing sheet just means nobody can
-- claim SR — MS/OS/TMOG still contest by kind priority.
-- Returns entries = { {name, base, sr_plus, effective, missroll=bool,
--   excludedWon=bool, rollType, overCap=bool} }.
-- Per-type rules: a roll only counts in its own range (15 on TMOG is a
-- valid TMOG roll even though it would lose an SR contest); anything above
-- its type cap is an over-roll (flagged, never wins). SR bonus applies to
-- SR rolls by sheet rollers only — MS/OS/TMOG never take sr_plus.
function M.BuildEntries(sheetLike, itemID, rolls, opts)
  opts = opts or {}
  local cap = opts.cap or 100
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
  -- One-win-per-item blocks the SR contest ONLY: an already-won player
  -- may still roll MS/OS/TMOG (e.g. rolling transmog after winning mainspec).
  -- Normalize a raw roll type to the four known kinds.
  local function normType(t)
    if t == "SR" or t == "MS" or t == "OS" or t == "TMOG" then return t end
    return "MS"
  end
  local entries = {}
  local j = 1
  while rolls and rolls[j] ~= nil do
    local rv = rolls[j]
    local base = tonumber(rv.roll) or 0
    local rtype = normType(rv.type)
    local typeCap = M.TYPE_CAPS[rtype] or cap
    if base >= 1 and base <= cap then
      local info = srMap[rv.name]
      local isSR = info ~= nil
      -- One-win-per-item blocks SR only: already-won flags the SR-kind
      -- entry as excluded; MS/OS/TMOG entries from the same player stay
      -- fully contestable (e.g. transmog after a mainspec win).
      local excluded = wonMap[rv.name] == true and rtype == "SR"
      -- Over-cap: above the TYPE range (e.g. 99 on a 1-98 TMOG roll).
      local over = base > typeCap
      -- Miss: an SR tag from someone WITHOUT the reserve is a fake SR
      -- claim (the live feed re-types those as MS in OnSystemRoll).
      -- MS/OS/TMOG rolls are valid kind contests from anyone (the
      -- sheet only holds SR rollers).
      local miss = false
      if not over and not excluded then
        if rtype == "SR" then miss = not isSR end
      end
      -- SR bonus: SR-kind rolls by sheet rollers only.
      local bonus = 0
      if rtype == "SR" and isSR then bonus = info.bonus or 0 end
      table.insert(entries, {
        name = rv.name,
        base = base,
        sr_plus = bonus,
        effective = M.Effective(base, bonus),
        missroll = miss,
        excludedWon = excluded,
        rollType = rtype,
        overCap = over,
      })
    end
    j = j + 1
  end
  return entries
end

-- Per-type contest: best eligible roll of each kind, ties kept per kind.
-- TMOG crowns its own kind winner (directly awardable); it never takes
-- an overall `winner` slot. Already-won blocks SR only (excludedWon is
-- set on SR-kind entries alone — MS/OS/TMOG stay contestable).
-- Returns { SR={entry,tied={}}, MS=..., OS=..., TMOG=... } (empty kinds
-- are empty tables).
function M.TypeWinners(entries)
  local out = { SR = {}, MS = {}, OS = {}, TMOG = {} }
  local best = {}
  local k = 1
  while entries[k] ~= nil do
    local e = entries[k]
    if not e.missroll and not e.excludedWon and not e.overCap
        and out[e.rollType] ~= nil then
      local b = best[e.rollType]
      if not b or (e.effective or 0) > (b.effective or 0) then
        best[e.rollType] = e
      end
    end
    k = k + 1
  end
  for _, t in ipairs(M.TYPE_ORDER) do
    local b = best[t]
    if b then
      local row = { entry = b, tied = {} }
      local m = 1
      while entries[m] ~= nil do
        local e = entries[m]
        if e ~= b and e.rollType == t and not e.missroll
            and not e.excludedWon and not e.overCap
            and (e.effective or 0) == (b.effective or 0) then
          table.insert(row.tied, e)
        end
        m = m + 1
      end
      out[t] = row
    end
  end
  return out
end

-- Overall winner by priority SR > MS > OS (TMOG excluded — optional only).
-- Returns the winning entry or nil.
function M.PriorityWinner(typeWinners)
  for _, t in ipairs({ "SR", "MS", "OS" }) do
    local row = typeWinners and typeWinners[t]
    if row and row.entry then return row.entry end
  end
  return nil
end

-- Rank entries: winners first. Ignores missrolls + won-excluded +
-- over-cap for winning, but keeps won-excluded rolls visible in `excluded`
-- so later sessions show who rolled while ineligible.
-- opts: { itemCount=1 }
-- Per-type contests (TypeWinners): each kind crowns its own best, ties
-- re-roll WITHIN the kind; the overall winner comes from priority
-- SR > MS > OS (TMOG never takes a winner slot) — ONE path for every
-- roll, sheet or off-sheet. Without SR holders the SR contest is empty
-- and the best MS wins; OS only wins with no MS contest.
-- Returns ranked (best-per-player, type order then effective), winners
-- (overall by priority, then itemCount-1 following SR/MS/OS kinds),
-- perType (the four contests), tied (cutoff ties needing re-roll),
-- missrolls + excluded (flagged lists).
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
  local perType = M.TypeWinners(entries)
  -- Overall winner: priority SR > MS > OS (TMOG never takes the
  -- overall slot). Single path — the sheet only feeds holder names
  -- into BuildEntries, never switches the rule.
  local winners = {}
  local tied = {}
  local prio = { "SR", "MS", "OS" }
  local first = M.PriorityWinner(perType)
  if first and itemCount >= 1 then
    winners[1] = first
    -- A tie INSIDE the winning kind forces a re-roll of that kind.
    local wrow = perType[first.rollType]
    if wrow and count(wrow.tied) > 0 then
      table.insert(tied, first)
      for t = 1, count(wrow.tied) do table.insert(tied, wrow.tied[t]) end
    end
    -- itemCount > 1 (2x): runners-up: next-best within the winning
    -- kind first, then the best of the other kinds in priority order.
    if count(tied) == 0 and itemCount > 1 then
      local wtype = first.rollType
      local same = {}
      local m = 1
      while entries[m] ~= nil do
        local e = entries[m]
        if e.rollType == wtype and not e.missroll and not e.excludedWon
            and not e.overCap and e.name ~= first.name then
          table.insert(same, e)
        end
        m = m + 1
      end
      table.sort(same, function(a, b)
        if (a.effective or 0) ~= (b.effective or 0) then
          return (a.effective or 0) > (b.effective or 0)
        end
        return (a.name or "") < (b.name or "")
      end)
      -- best roll per player within the kind
      local seenSame, si = {}, 1
      while same[si] ~= nil and count(winners) < itemCount do
        if not seenSame[same[si].name] then
          seenSame[same[si].name] = true
          table.insert(winners, same[si])
        end
        si = si + 1
      end
      for _, t in ipairs(prio) do
        if count(winners) >= itemCount then break end
        local row = perType[t]
        if row and row.entry and row.entry.name ~= first.name
            and count(row.tied) == 0 then
          -- skip names already holding a slot
          local dup = false
          for w = 1, count(winners) do
            if winners[w].name == row.entry.name then dup = true break end
          end
          if not dup then table.insert(winners, row.entry) end
        end
      end
    end
  end
  -- Legacy ranked view: best-per-player, type order then effective desc.
  local best = {}
  for x = 1, count(cand) do
    local e = cand[x]
    if not e.overCap then
      if not best[e.name] or e.effective > best[e.name].effective then
        best[e.name] = e
      end
    end
  end
  local typeRank = { SR = 1, MS = 2, OS = 3, TMOG = 4 }
  local ranked = {}
  for _, e in pairs(best) do table.insert(ranked, e) end
  table.sort(ranked, function(a, b)
    local ra, rb = typeRank[a.rollType] or 9, typeRank[b.rollType] or 9
    if ra ~= rb then return ra < rb end
    if a.effective ~= b.effective then return a.effective > b.effective end
    return (a.name or "") < (b.name or "")
  end)
  return { ranked = ranked, winners = winners, tied = tied, missrolls = miss,
    excluded = excluded, perType = perType }
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
      effective = e.effective or e.base, missroll = e.missroll,
      excludedWon = e.excludedWon, rollType = e.rollType, overCap = e.overCap })
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

-- Roll-size budgets for sims: a crowded window is unreadable, so each
-- simulated roll involves 3-7 players total (clamped against the roster).
M.SIM_ROLLERS_MIN = 3
M.SIM_ROLLERS_MAX = 7

-- Pick n distinct names from a list (order-preserving, 5.0-safe).
local function takeNames(names, n, skip)
  local out = {}
  local i = 1
  while names[i] ~= nil and count(out) < n do
    local nm = names[i]
    if nm and nm ~= "" and not (skip and skip[nm]) then
      table.insert(out, nm)
    end
    i = i + 1
  end
  return out
end

-- THE fake-roll generator: sim AND rehearsal share this (one code path).
-- Every roll is math.random(1-100) for the number; the KIND (MS/OS/TMOG)
-- is drawn at random per roller. SR holders roll SR (their reserve),
-- everyone else rolls a random kind — same as a live mixed roll.
-- Roster: SR holders first, then the rest of the sheet roster; invented
-- names (rehearsal) arrive as an opts.roster override. Off-sheet items
-- (no holders) roll the whole roster with random kinds.
-- Group size: 3-7 total (opts.count pins it for tests).
-- rng: function(lo,hi) default math.random. Returns rolls list.
-- opts.tmog = {names}: those rollers roll TMOG instead of their draw
--   (TMOG demos: the player still rolls, just a different die).
-- opts.roster = {names}: use instead of the sheet roster (rehearsal).
-- opts.count = exact roller total (tests pin the size deterministically).
-- opts.srOnly = holders roll SR, extras roll MS only (legacy sim shape;
--   prefer the random-kind default for new callers).
function M.FakeRolls(sheetLike, itemID, opts, rng)
  opts = opts or {}
  rng = rng or function(lo, hi) return math.random(lo, hi) end
  local kinds = { "MS", "OS", "TMOG" }
  local function drawKind()
    return kinds[rng(1, 3)]
  end
  local function rollFor(kind)
    return rng(1, M.TypeCap(kind))
  end
  -- Roster: explicit override (rehearsal invented names) else sheet.
  local players = {}
  if type(opts.roster) == "table" then
    for i = 1, count(opts.roster) do
      if opts.roster[i] and opts.roster[i] ~= "" then
        table.insert(players, opts.roster[i])
      end
    end
  else
    local SRD = (Z and Z.SRData) or ZugLoot.SRData
    if SRD and SRD.AllPlayerNames then
      players = SRD.AllPlayerNames(sheetLike) or {}
    end
    if count(players) == 0 and sheetLike and sheetLike.items then
      local seen = {}
      for _, item in pairs(sheetLike.items) do
        local rr = (item or {}).rollers or {}
        local j = 1
        while rr[j] ~= nil do
          local nm = rr[j].name
          if nm and nm ~= "" and not seen[nm] then
            seen[nm] = true
            table.insert(players, nm)
          end
          j = j + 1
        end
      end
    end
  end
  local total = opts.count
  if total == nil then
    total = rng(M.SIM_ROLLERS_MIN, M.SIM_ROLLERS_MAX)
  end
  if total < 1 then total = 1 end
  local tmogSet = {}
  if type(opts.tmog) == "table" then
    for t = 1, count(opts.tmog) do tmogSet[opts.tmog[t]] = true end
  end
  local rolls = {}
  local skip = {}
  -- SR holders roll SR (their reserve); a tmog-forced holder rolls TMOG.
  if sheetLike and sheetLike.items and sheetLike.items[itemID] then
    local rollers = sheetLike.items[itemID].rollers or {}
    local i = 1
    while rollers[i] ~= nil and count(rolls) < total do
      local nm = rollers[i].name
      if nm and nm ~= "" then
        local kind = tmogSet[nm] and "TMOG" or "SR"
        table.insert(rolls, { name = nm, roll = rollFor(kind), type = kind })
        skip[nm] = true
      end
      i = i + 1
    end
  end
  -- Fill the rest of the budget from the roster with random kinds.
  -- Wrap on small rosters (names stay unique via suffix).
  local n = 1
  while count(rolls) < total and count(players) > 0 do
    local nm = players[((n - 1) % count(players)) + 1]
    local tag = nm
    if skip[nm] then tag = nm .. n end
    skip[tag] = true
    local kind
    if tmogSet[tag] or tmogSet[nm] then
      kind = "TMOG"
    elseif opts.srOnly then
      kind = "MS"
    else
      kind = drawKind()
    end
    table.insert(rolls, { name = tag, roll = rollFor(kind), type = kind })
    n = n + 1
    if n > total + count(players) + 5 then break end -- paranoia
  end
  -- Named fillers (legacy /sim <link> N path): RollerN entries with random
  -- kinds, only while the budget is unfilled (never past total).
  if type(opts.fillers) == "number" then
    for f = 1, opts.fillers do
      if count(rolls) >= total then break end
      local tag = "Roller" .. f
      if not skip[tag] then
        skip[tag] = true
        local kind = drawKind()
        table.insert(rolls, { name = tag, roll = rollFor(kind), type = kind })
      end
    end
  end
  return rolls
end

if ZugLoot then ZugLoot.Resolver = M end
return M
