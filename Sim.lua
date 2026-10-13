-- ZugLoot/Sim.lua
-- In-game simulation: /zl sim <itemlink|itemID> [fillers], /zl simboss <boss>,
-- /zl simstop. Requires the loaded sheet (Z.DB.sheet): every roller is a
-- player from the sheet, and every simulated session is written back into the
-- sheet (sheet.rolls history + won marks + drop log), exactly like a live roll.
--
-- The async path (/zl sim, /zl simboss) replays the REAL live pipeline:
-- MasterLootUI session + timers + group-routed chat + both windows, one item
-- at a time. Fake rolls are precomputed, then fed through
-- MasterLootUI.OnSystemRoll on short timers so the raider list fills live;
-- the session finishes on the normal roll timer and the boss queue advances
-- to the next drop only afterwards. RunSimSession() stays behind as the
-- synchronous core (tests, instant resolve).
-- Uses the same Resolver pure module as real sessions and as tests/.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.Sim = M

M.pending = {}   -- queued { itemID, link, mode, rolls } for the boss run
M.running = false -- a sim run is in progress (queue non-empty or item live)

-- Seconds between fed fake rolls (lively but readable).
M.ROLL_GAP = 0.45
-- Max tie re-roll rounds per item before giving up with a note.
M.TIE_ROUNDS = 3

function M.RequireSheet()
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then
    Z.Print("Simulation requires a loaded sheet. Import one first: /zl import or Load from File.")
    return nil
  end
  return sheet
end

local function now()
  return (time and time()) or 0
end

function M.Busy()
  return M.running or (Z.MasterLootUI and Z.MasterLootUI.session ~= nil)
end

-- Stop a running sim: drop the queue (the live item, if any, plays out).
function M.Stop()
  M.pending = {}
  if M.running then
    M.running = false
    Z.Print("Sim stopped (queue cleared; current item plays out).")
  else
    Z.Print("No sim running.")
  end
end

-- Print one simulated session (same lines the Sheet tab shows per player).
-- Already-won rollers appear with their roll shown but marked excluded.
-- Used by the synchronous RunSimSession core.
local function printSession(itemID, res, sheet)
  local i = 1
  while res.entries and res.entries[i] ~= nil do
    local e = res.entries[i]
    local tag = e.missroll and " MISSRROLL(ignored)" or ""
    local excluded = e.excludedWon or (sheet.won[itemID] and sheet.won[itemID][e.name])
    local won = excluded and " [already won]" or ""
    Z.Print("  roll " .. e.name .. " " .. e.base .. " + " .. (e.sr_plus or 0) .. " = " .. e.effective .. tag .. won)
    i = i + 1
  end
  if Z.Util.ArrayCount(res.winners or {}) > 0 then
    Z.Print("  => winner: " .. res.winners[1].name .. " (" .. res.winners[1].effective .. ")")
  else
    Z.Print("  => no winner")
  end
  if Z.Util.ArrayCount(res.tied or {}) > 0 then
    local t = {}
    for k = 1, Z.Util.ArrayCount(res.tied) do table.insert(t, res.tied[k].name) end
    Z.Print("  => tie: " .. table.concat(t, ", ") .. " (re-roll)")
  end
end

-- Resolve a fake session and write it back: roll history, won marks (skipped
-- on ties — ties need a re-roll, like live), drop log, window refresh.
-- Synchronous core: instant resolve, no timers, no windows, no chat.
function M.RunSimSession(sheet, itemID, mode, rolls, itemLink)
  local res = Z.Resolver.ResolveItem(sheet, itemID, rolls,
    { cap = Z.Caps.SR, requireSR = (mode == "SIM"), itemCount = 1 })
  printSession(itemID, res, sheet)
  if Z.Util.ArrayCount(res.entries or {}) > 0 then
    -- Simulated off-sheet item: same unreserved stub as live rolls.
    if Z.SRData.EnsureUnreserved then
      Z.SRData.EnsureUnreserved(sheet, itemID, nil)
    end
    Z.SRData.RecordRolls(sheet, itemID, Z.Resolver.ToHistoryEntry(res, mode, now()))
  end
  local tied = Z.Util.ArrayCount(res.tied or {})
  local winners = res.winners or {}
  if tied == 0 and Z.Util.ArrayCount(winners) > 0 then
    for i = 1, Z.Util.ArrayCount(winners) do
      local name = winners[i].name
      Z.SRData.MarkWon(sheet, itemID, name)
      if Z.DropLog then Z.DropLog.Add(itemID, itemLink, "sim", "award", name) end
    end
  end
  if Z.MainWindow then Z.MainWindow.Refresh() end
  if Z.SRView then Z.SRView.Refresh() end
  return res
end

-- Open-roll fakes for items nobody SR'd: every player on the sheet rolls.
function M.FakeOpenRolls(sheet, fillers, rng)
  rng = rng or function(lo, hi) return math.random(lo, hi) end
  local rolls = {}
  local names = Z.SRData.AllPlayerNames(sheet)
  for i = 1, Z.Util.ArrayCount(names) do
    table.insert(rolls, { name = names[i], roll = rng(1, Z.Caps.SR), type = "MS" })
  end
  for f = 1, (fillers or 0) do
    table.insert(rolls, { name = "Filler" .. f, roll = rng(1, Z.Caps.SR), type = "MS" })
  end
  return rolls
end

-- Build one queued entry: precomputed fake rolls for an item.
-- Returns entry or nil + usage error.
function M.BuildEntry(sheet, itemID, link, fillers)
  local onSheet = sheet.items[itemID] ~= nil
  local mode, rolls
  if onSheet then
    mode = "SIM"
    rolls = Z.Resolver.FakeRolls(sheet, itemID,
      { cap = Z.Caps.SR, fillers = fillers, sheetOnly = (fillers == 0) })
  else
    mode = "SIM-OPEN"
    rolls = M.FakeOpenRolls(sheet, fillers)
  end
  return { itemID = itemID, link = link, mode = mode, rolls = rolls }
end

-- Resolve opts mirroring MasterLootUI.Finish for a sim session.
local function finishOpts(sess, sheet)
  local openRoll = sess.mode == "OPEN" or sess.mode == "RAID" or sess.mode == "SIM-OPEN"
  return { cap = Z.Caps.SR, requireSR = (not openRoll and sheet ~= nil), itemCount = sess.itemCount or 1 }
end

-- Names needing a tie re-roll for the live sim session (pre-resolve with the
-- same opts Finish uses). Empty when the session would finish cleanly.
local function tieNames(sess, sheet)
  local res = Z.Resolver.ResolveItem(sheet, sess.itemID, sess.rolls, finishOpts(sess, sheet))
  local out = {}
  local tied = res.tied or {}
  for i = 1, Z.Util.ArrayCount(tied) do
    table.insert(out, tied[i].name)
  end
  return out
end

-- Feed one roll into the live sim session (timer callback).
local function feedRoll(sess, rv, cap)
  if not Z.MasterLootUI or Z.MasterLootUI.session ~= sess then return end
  Z.MasterLootUI.OnSystemRoll(rv.name, rv.roll, 1, cap)
end

-- Finish wrapper for the sim pump: resolves, re-rolls ties (up to
-- TIE_ROUNDS fresh rounds for the tied subset), then hands back to pump.
local function finishSim(entry, round)
  round = round or 1
  local ML = Z.MasterLootUI
  if not ML or not ML.session then M.pump() return end
  local sheet = Z.DB and Z.DB.sheet
  local names = {}
  if sheet then names = tieNames(ML.session, sheet) end
  ML.Finish()
  if ML.session then
    -- Still open: tie at the top.
    if Z.Util.ArrayCount(names) == 0 or round > M.TIE_ROUNDS then
      Z.Print("SIM tie left unresolved — re-roll manually or /zl cr.")
      ML.Cancel()
      M.pump()
      return
    end
    Z.Print("SIM tie between " .. table.concat(names, ", ") .. " — re-rolling (round " .. round .. ").")
    -- Clear the tied players' old rolls so the live first-roll-only rule
    -- accepts their re-rolls (same as a real re-roll round).
    local sess = ML.session
    if sess then
      local re = {}
      for i = 1, Z.Util.ArrayCount(names) do re[names[i]] = true end
      local kept = {}
      for i = 1, Z.Util.ArrayCount(sess.rolls) do
        if not re[sess.rolls[i].name] then table.insert(kept, sess.rolls[i]) end
      end
      sess.rolls = kept
    end
    local cap = Z.Caps.SR
    for i = 1, Z.Util.ArrayCount(names) do
      local nm = names[i]
      Z.Timer.After(i * M.ROLL_GAP, function() feedRoll(ML.session, { name = nm, roll = math.random(1, cap) }, cap) end)
    end
    Z.Timer.After((Z.Util.ArrayCount(names) + 1) * M.ROLL_GAP + 0.2, function() finishSim(entry, round + 1) end)
    return
  end
  -- Session closed (winner, no winner, awards done): next item after a beat.
  Z.Timer.After(1.0, function() M.pump() end)
end

-- Play one queued entry through the real pipeline: silent session (no
-- addon broadcast to other clients), both windows visible, rolls fed on
-- timers, finish on the normal roll timer.
function M.playOne(entry)
  local ML = Z.MasterLootUI
  local rollTime = (Z.DB and Z.DB.rollTime) or 15
  ML.BeginSession(entry.itemID, entry.link, entry.mode, true)
  -- ML view: make sure the sheet window is up (don't toggle it away).
  if Z.MainWindow and Z.MainWindow.Show then
    local f = Z.MainWindow.frame
    if not f or not (f.IsVisible and f:IsVisible()) then
      Z.MainWindow.Show("sheet")
    end
  end
  local cap = Z.Caps.SR
  for i = 1, Z.Util.ArrayCount(entry.rolls) do
    local rv = entry.rolls[i]
    Z.Timer.After(i * M.ROLL_GAP, function() feedRoll(ML.session, rv, cap) end)
  end
  Z.Timer.After(rollTime, function() finishSim(entry, 1) end)
end

-- Queue worker: one item at a time; next starts only when no session is live.
function M.pump()
  if Z.MasterLootUI and Z.MasterLootUI.session then return end
  local nextEntry = nil
  if Z.Util.ArrayCount(M.pending) > 0 then
    nextEntry = table.remove(M.pending, 1)
  end
  if not nextEntry then
    if M.running then
      M.running = false
      Z.Print("SIM done — see the Sheet tab.")
    end
    return
  end
  M.running = true
  M.playOne(nextEntry)
end

function M.SimItem(argText)
  local sheet = M.RequireSheet()
  if not sheet then return end
  if M.Busy() then
    Z.Print("A roll or sim is already running — wait or /zl simstop.")
    return
  end
  local link, n = string.match((argText or ""), "(%S+)%s*(%d*)")
  local itemID = Z.Util.ItemID(link or "")
  if not itemID then Z.Print("Usage: /zl sim <itemlink|itemID> [fillers]") return end
  local fillers = tonumber(n) or 0
  local entry = M.BuildEntry(sheet, itemID, link, fillers)
  Z.Print("SIM " .. entry.mode .. " item " .. itemID .. " (" .. Z.Util.ArrayCount(entry.rolls) .. " rolls, replaying live with timers):")
  table.insert(M.pending, entry)
  M.pump()
end

function M.SimBoss(name)
  local sheet = M.RequireSheet()
  if not sheet then return end
  if M.Busy() then
    Z.Print("A roll or sim is already running — wait or /zl simstop.")
    return
  end
  name = Z.Util.Trim(name or "")
  local table_ = Z.BossData[name]
  if not table_ then
    local avail = {}
    for b in pairs(Z.BossData) do table.insert(avail, b) end
    Z.Print("Unknown boss. Try: " .. table.concat(avail, ", "))
    return
  end
  Z.Print("SIM boss " .. name .. " drops, one item at a time (sheet players, one-win applies across drops):")
  for i = 1, Z.Util.ArrayCount(table_) do
    local itemID = table_[i]
    table.insert(M.pending, M.BuildEntry(sheet, itemID, tostring(itemID), 0))
  end
  M.pump()
end
