-- ZugLoot/Sim.lua
-- In-game simulation: /zl sim <itemlink|itemID> [fillers], /zl simboss <boss>,
-- /zl simtmog <itemlink>, /zl simroll <item>, /zl simstop. Requires the loaded sheet (Z.DB.sheet): every roller is a
-- player from the sheet, and every simulated session is written back into the
-- sheet (sheet.rolls history + won marks + drop log), exactly like a live roll.
--
-- The async path (/zl sim, /zl simboss) replays the REAL live pipeline:
-- MasterLootUI session + timers + group-routed chat + both windows, one item
-- at a time. Fake rolls are precomputed, then fed through
-- MasterLootUI.OnSystemRoll on short timers so the raider list fills live;
-- the session finishes on the normal roll timer; afterwards the ML picks
-- the award from the menu and the queue advances (/zl sim one-shots
-- auto-play; simboss waits for the ML's Roll per item). RunSimSession() stays behind as the
-- synchronous core (tests, instant resolve).
-- Uses the same Resolver pure module as real sessions and as tests/.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.Sim = M

M.pending = {}   -- queued { itemID, link, mode, rolls } for the boss run
M.live = nil      -- legacy alias: the ACTIVE rolling entry (see M.lives).
                  -- kept so old readers/tests keep working.
M.lives = {}      -- [itemID] = entry currently rolling (one per item).
                  -- Entries leave the queue at Roll time and stay listed
                  -- as rolling until the ML awards them (never dropped).
M.running = false -- a sim run is in progress (queue non-empty or item live)
M.timers = {}     -- [itemID] = { timer handles } for that item's sim chain
                  -- (feeds, finish, tie rounds). Killed when the ML ends the
                  -- roll early so no fake roll can land after the finish.

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
  if M.running then return true end
  if Z.MasterLootUI then
    if Z.MasterLootUI.session ~= nil then return true end
    if Z.MasterLootUI.sessions then
      for _, sess in pairs(Z.MasterLootUI.sessions) do
        if sess then return true end -- a roll is live (any item)
      end
    end
    if Z.MasterLootUI.pendingAwardMenu ~= nil then return true end
    if Z.MasterLootUI.pendingAwardMenus then
      for _, pend in pairs(Z.MasterLootUI.pendingAwardMenus) do
        if pend then return true end -- ML still deciding (any item)
      end
    end
  end
  return false
end

-- Display name for sim chat lines (never a bare item:id).
local function dispName(itemID, link)
  if Z.MasterLootUI and Z.MasterLootUI.DisplayItemLink then
    return Z.MasterLootUI.DisplayItemLink(itemID, link)
  end
  return tostring(link or ("item:" .. tostring(itemID)))
end

-- Stop a running sim: drop the queue (the live item, if any, plays out).
-- Fresh loot session: every sim (and every live loot) starts clean. A
-- second /zl simboss for Ragnaros must not see the first run's done rows,
-- queue, detail, menu, raider rolls or trailing timers. Call AFTER the
-- Busy guard (it wipes running/session state) and BEFORE building the
-- new queue/window.
function M.ResetFresh()
  if Z.Timer and Z.Timer.CancelAll then Z.Timer.CancelAll() end
  M.pending = {}
  M.live = nil
  M.lives = {}
  M.timers = {}
  M.lastEntries = {}
  M.pendingAward = nil
  M.auto = false
  M.running = false
  if Z.MasterLootUI then
    Z.MasterLootUI.session = nil
    Z.MasterLootUI.sessions = {}
    Z.MasterLootUI.parkedSessions = nil
    Z.MasterLootUI.pendingAwardMenu = nil
    Z.MasterLootUI.pendingAwardMenus = nil
  end
  if Z.LootWindow then
    if Z.LootWindow.CloseMoreDropdown then Z.LootWindow.CloseMoreDropdown() end
    Z.LootWindow.Clear()
  end
  if Z.RaiderLootUI and Z.RaiderLootUI.Hide then Z.RaiderLootUI.Hide() end
end

-- Stop a running sim: a FULL stop. Cancels the live session, drops the
-- queue, kills all sim timers (feed/tie/finish/continuation), clears the
-- award menu, hides the loot window (+detail) and the raider window — so
-- nothing from this sim can fire or linger into the next run. The sheet
-- (history/won marks already written) is untouched.
function M.Stop()
  -- A rehearsal run stops here too (sheet restored, queue dropped).
  if M.rehearseRun then M.StopRehearsal() end
  local wasRunning = M.running
      or (M.lives and next(M.lives) ~= nil)
      or (Z.MasterLootUI and (Z.MasterLootUI.session ~= nil
        or Z.MasterLootUI.pendingAwardMenu ~= nil))
      or (M.pending and Z.Util.ArrayCount(M.pending) > 0)
  M.ResetFresh() -- cancels timers, session, menu; clears queue + loot rows
  M.MaybeFinish() -- prints + hides windows (no "SIM done" print needed here)
  if Z.LootWindow then
    if Z.LootWindow.Hide then
      Z.LootWindow.Hide() -- hides frame AND closes the detail
    else
      if Z.LootWindow.CloseDetail then Z.LootWindow.CloseDetail() end
    end
  end
  if Z.AwardMenuUI and Z.AwardMenuUI.Hide then
    Z.AwardMenuUI.Hide()
  end
  if wasRunning then
    Z.Print("Sim stopped (windows closed, everything reset).")
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

-- Open-roll fakes for items nobody SR'd: 3-7 sheet members roll MS/OS/TMOG
-- (caps 100/99/98). opts.count pins the size for tests. fillers adds
-- extra RollerN entries (legacy /zl sim <link> N path).
function M.FakeOpenRolls(sheet, fillers, rng, opts)
  rng = rng or function(lo, hi) return math.random(lo, hi) end
  opts = opts or {}
  local minN = Z.Resolver.SIM_ROLLERS_MIN or 3
  local maxN = Z.Resolver.SIM_ROLLERS_MAX or 7
  local total = opts.count
  if total == nil then total = rng(minN, maxN) end
  if total < 1 then total = 1 end
  local rolls = {}
  local names = Z.SRData.AllPlayerNames(sheet)
  local nNames = Z.Util.ArrayCount(names)
  local kinds = { "MS", "OS", "TMOG" }
  local taken = {}
  local n = 1
  while Z.Util.ArrayCount(rolls) < total and (nNames > 0 or (fillers or 0) > 0) do
    local nm = nil
    if nNames > 0 then nm = names[((n - 1) % nNames) + 1] end
    if not nm or nm == "" then
      nm = "Roller" .. n
    elseif taken[nm] then
      nm = nm .. n -- wrap: keep names unique on small rosters
    end
    -- Duplicate guard (small roster + wrap): skip taken names.
    local dupe = taken[nm]
    if not dupe then
      taken[nm] = true
      local kind = kinds[((n - 1) % 3) + 1]
      local rcap = Z.Caps.SR
      if kind == "OS" then rcap = Z.Caps.OS elseif kind == "TMOG" then rcap = Z.Caps.TMOG end
      table.insert(rolls, { name = nm, roll = rng(1, rcap), type = kind })
    end
    n = n + 1
    if n > total + nNames + (fillers or 0) + 5 then break end -- paranoia
  end
  return rolls
end

-- Test hook: pin the sim roller headcount (opts.count flows through
-- BuildEntry). Tests set Sim.FakeCount; live runs leave it nil for the
-- 3-7 budget draw.
M.FakeCount = nil

-- Build one queued entry: precomputed fake rolls for an item.
-- Returns entry or nil + usage error.
function M.BuildEntry(sheet, itemID, link, fillers)
  local onSheet = sheet.items[itemID] ~= nil
  local mode, rolls
  if onSheet then
    mode = "SIM"
    rolls = Z.Resolver.FakeRolls(sheet, itemID,
      { cap = Z.Caps.SR, count = M.FakeCount })
    -- An on-sheet item with no rollers (e.g. an unreserved stub from an
    -- earlier run) would otherwise roll with ZERO rolls and finish with
    -- no winner: fall back to an open roll of the whole sheet instead.
    if Z.Util.ArrayCount(rolls) == 0 then
      mode = "SIM-OPEN"
      rolls = M.FakeOpenRolls(sheet, fillers, nil, { count = M.FakeCount })
    end
  else
    mode = "SIM-OPEN"
    rolls = M.FakeOpenRolls(sheet, fillers, nil, { count = M.FakeCount })
  end
  return { itemID = itemID, link = link, mode = mode, rolls = rolls }
end

-- Resolve opts mirroring MasterLootUI.Finish for a sim session.
local function finishOpts(sess, sheet)
  local openRoll = sess.mode == "OPEN" or sess.mode == "RAID" or sess.mode == "SIM-OPEN"
  return { cap = Z.Caps.SR, requireSR = (not openRoll and sheet ~= nil), itemCount = sess.itemCount or 1 }
end

-- Called after a sim award completes: asks for the next roll.
-- Continuation is timer-deferred so award confirmation never nests the
-- next item inside this call stack.
function M.afterAwards()
  Z.Timer.After(1.0, function() M.RequestNextRoll() end)
end

-- Feed/finish/tie timers belong to ONE item: they are scheduled through
-- here and killed (KillItemTimers) when the ML ends that roll early, so
-- simulated rolls never land after the finish. Pure bookkeeping on top of
-- Z.Timer — surviving handles are still Timer.Cancel-safe.
function M.TrackTimer(itemID, h)
  if not itemID or not h then return h end
  M.timers = M.timers or {}
  M.timers[itemID] = M.timers[itemID] or {}
  table.insert(M.timers[itemID], h)
  return h
end

function M.KillItemTimers(itemID)
  if not itemID or not M.timers then return end
  local set = M.timers[itemID]
  if not set then return end
  for i = 1, Z.Util.ArrayCount(set) do
    if Z.Timer and Z.Timer.Cancel then Z.Timer.Cancel(set[i]) end
  end
  M.timers[itemID] = nil
end

-- Roll range per type (mirrors live caps): SR/MS 1-100, OS 1-99, TMOG 1-98.
-- OnSystemRoll derives the roll type from maxR, so feeds must carry the
-- right range or every fake roll reads as SR.
function M.RangeFor(rtype)
  local caps = Z.Caps or { SR = 100, MS = 100, OS = 99, TMOG = 98 }
  if rtype == "OS" then return 1, caps.OS or 99 end
  if rtype == "TMOG" then return 1, caps.TMOG or 98 end
  return 1, caps.SR or 100
end

-- Feed one roll into the live sim session (timer callback). The precomputed
-- entry carries the INTENT (like a player clicking the MS dice): feed the
-- range, then stamp the intended kind — OnSystemRoll would otherwise read
-- every sheet roller at 1-100 back as SR.
local function feedRoll(sess, rv)
  -- A nil sess (re-read ML session after a cancel/stop) is never the live
  -- session — and the nil==nil guard below would otherwise let it through
  -- to sess.itemID. No session, no feed. Matched per-item: another item's
  -- session must never accept this feed, even after the ML switches rows.
  if not sess then return end
  if not Z.MasterLootUI then return end
  local MLUI = Z.MasterLootUI
  local cur = MLUI.sessions and MLUI.sessions[sess.itemID] or MLUI.session
  if cur ~= sess then return end
  local minR, maxR = M.RangeFor(rv.type)
  Z.MasterLootUI.OnItemSystemRoll(sess.itemID, rv.name, rv.roll, minR, maxR, sess.id)
  if rv.type and sess and sess.rolls then
    for i = 1, Z.Util.ArrayCount(sess.rolls) do
      if sess.rolls[i].name == rv.name then
        sess.rolls[i].type = rv.type
        break
      end
    end
  end
  -- The ML roll window mirrors the corrected kind.
  if Z.LootWindow and Z.LootWindow.detail
      and Z.LootWindow.detail.itemID == sess.itemID
      and Z.LootWindow.detail.phase == "rolling" then
    local drolls = Z.LootWindow.detail.rolls or {}
    for i = 1, Z.Util.ArrayCount(drolls) do
      if drolls[i].name == rv.name then drolls[i].rollType = rv.type break end
    end
    Z.LootWindow.RefreshDetail()
  end
end

-- Finish wrapper: resolves, re-rolls ties (up to TIE_ROUNDS fresh rounds
-- for the tied subset), then the ML decides the award from the menu.
local function finishSim(entry, round)
  round = round or 1
  local ML = Z.MasterLootUI
  -- Rehearsal entries advance the rehearsal queue, never the sim queue.
  local nextFn = (entry and entry.rehearse) and M.afterRehearsal or M.RequestNextRoll
  if not ML or not ML.session then nextFn() return end
  local sheet = Z.DB and Z.DB.sheet
  local names = {}
  local tieKind = nil
  -- Pre-resolve (same opts Finish uses): tie subset + its kind (ties only
  -- ever happen WITHIN one kind, so re-rolls keep that kind's range).
  -- Finish re-resolves deterministically on identical inputs.
  local pre = nil
  if sheet then
    pre = Z.Resolver.ResolveItem(sheet, ML.session.itemID, ML.session.rolls, finishOpts(ML.session, sheet))
    local tied = pre.tied or {}
    for i = 1, Z.Util.ArrayCount(tied) do
      table.insert(names, tied[i].name)
      if tied[i].rollType then tieKind = tied[i].rollType end
    end
  end
  M.pendingAward = nil
  local outcome = ML.Finish()
  if outcome == "tie" then
    if Z.Util.ArrayCount(names) == 0 or round > M.TIE_ROUNDS then
      Z.Print("SIM tie left unresolved — re-roll manually or /zl cr.")
      ML.Cancel()
      Z.Timer.After(1.0, function() nextFn() end)
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
    local tmin, tmax = 1, Z.Caps.SR
    if tieKind then tmin, tmax = M.RangeFor(tieKind) end
    local cap = tmax
    -- Capture the live session NOW: re-reading ML.session at fire time
    -- yields nil after a cancel/stop, and feedRoll(nil) used to slip past
    -- the guard (nil == nil) into sess.itemID. A cancelled tie simply
    -- stops feeding (guard: session no longer matches).
    local tieSess = ML.session
    for i = 1, Z.Util.ArrayCount(names) do
      local nm = names[i]
      M.TrackTimer(entry.itemID,
        Z.Timer.After(i * M.ROLL_GAP, function() feedRoll(tieSess, { name = nm, type = tieKind or "SR", roll = math.random(tmin, cap) }) end))
    end
    M.TrackTimer(entry.itemID,
      Z.Timer.After((Z.Util.ArrayCount(names) + 1) * M.ROLL_GAP + 0.2, function() finishSim(entry, round + 1) end))
    return
  end
  if outcome == "awaiting" then
    -- The ML decides: in-client the menu frame is on screen and
    -- AwardChosen/popup continuations own what follows; headless the menu
    -- stays pending for the harness's AwardChosen. A no-winner finish
    -- (nobody eligible) never auto-skips: the item stays in the loot
    -- window until the ML awards it to someone else or re-rolls.
    local pend = ML.pendingAwardMenu
    if pend and pend.data and pend.data.none then
      Z.Print("SIM: no eligible winner — award anyone (/zl award <name>) or /zl cr to re-roll. The item stays in the loot window.")
    end
    return
  end
  -- "closed": nothing owns continuation (should not happen for sim).
end

-- Start one queued entry through the real pipeline: silent session (no
-- addon broadcast to other clients), both windows visible, rolls fed on
-- timers, finish on the normal roll timer. Only the ML starts entries —
-- playOne runs from RequestRoll (loot-window Roll button), RequestNextRoll
-- (auto mode), or the /zl sim one-shot.
function M.playOne(entry)
  local ML = Z.MasterLootUI
  local rollTime = (Z.DB and Z.DB.rollTime) or 15
  ML.BeginSession(entry.itemID, entry.link, entry.mode, true)
  if Z.LootWindow then Z.LootWindow.MarkRolling(entry.itemID) end
  -- No forced sheet window: the sim plays in the loot + roll windows, and
  -- the sheet opens only on player request (/zl sheet).
  -- Capture THIS item's session table (per-item: ML.session re-aliases
  -- on every BeginSession, which would cross-wire parallel feeds).
  local playSess = ML.sessions and ML.sessions[entry.itemID] or ML.session
  for i = 1, Z.Util.ArrayCount(entry.rolls) do
    local rv = entry.rolls[i]
    M.TrackTimer(entry.itemID,
      Z.Timer.After(i * M.ROLL_GAP, function() feedRoll(playSess, rv) end))
  end
  M.TrackTimer(entry.itemID,
    Z.Timer.After(rollTime, function() finishSim(entry, 1) end))
end

-- Request the next roll: auto mode plays the queue head (the /zl sim
-- one-shot always auto-plays); manual mode waits for the ML's Roll click.
-- When the queue is empty AND nothing is live/deciding, the run is over:
-- the loot window closes (nothing left to hand out is not a record).
-- Multi-roll: other items rolling/deciding do NOT block the queue head.
function M.RequestNextRoll()
  if M.auto then
    local head = M.pending[1]
    if head then M.RequestRoll(head.itemID) return end
  end
  if Z.MasterLootUI then
    if Z.MasterLootUI.sessions then
      for _, sess in pairs(Z.MasterLootUI.sessions) do
        if sess then return end -- a roll is live (any item)
      end
    elseif Z.MasterLootUI.session then
      return
    end
    if Z.MasterLootUI.pendingAwardMenus then
      for _, pend in pairs(Z.MasterLootUI.pendingAwardMenus) do
        if pend then return end -- ML deciding (any item)
      end
    elseif Z.MasterLootUI.pendingAwardMenu then
      return
    end
  end
  M.SyncLootWindow()
  if Z.Util.ArrayCount(M.pending) == 0 and M.live == nil then
    M.MaybeFinish()
  else
    Z.Print("SIM: waiting for the ML — click Roll in the loot window.")
  end
end

-- The ML initiates one queued item (loot-window Roll button).
-- Sequential holds: one roll runs at a time. A parked (finished) item may
-- start rolling again only via Continue (same session); a FRESH roll of an
-- item that already has a live session is refused.
function M.RequestRoll(itemID)
  local MLUI = Z.MasterLootUI
  if MLUI and MLUI.sessions and MLUI.sessions[itemID] then
    Z.Print("Already rolling " .. dispName(itemID, nil) .. " — finish or /zl cr first.")
    return
  end
  if MLUI and MLUI.session then
    Z.Print("A roll is already running — finish, /zl cr, or close it first.")
    return
  end
  if M.lives and M.lives[itemID] then
    Z.Print("Already rolling " .. dispName(itemID, nil) .. " — finish or /zl cr first.")
    return
  end
  local queued = false
  for i = 1, Z.Util.ArrayCount(M.pending) do
    if M.pending[i].itemID == itemID then queued = true break end
  end
  if not queued then
    Z.Print("SIM: item " .. tostring(itemID) .. " is not in the loot queue.")
    return
  end
  for i = 1, Z.Util.ArrayCount(M.pending) do
    if M.pending[i].itemID == itemID then
      local entry = table.remove(M.pending, i)
      M.lives = M.lives or {}
      M.lives[entry.itemID] = entry -- stays listed until the ML awards it
      M.live = entry -- active alias
      M.running = true
      M.SyncLootWindow()
      Z.Print("SIM: rolling " .. dispName(entry.itemID, entry.link) .. " (ML pick).")
      M.playOne(entry)
      return
    end
  end
  Z.Print("SIM: item " .. tostring(itemID) .. " is not in the loot queue.")
end

-- Flag flip for /zl rehearse [on|off] and the Setup toggle (nil = flip).
-- Turning off mid-run stops the run but keeps already-looted items.
function M.SetRehearse(arg)
  local want = nil
  if arg ~= nil then
    local s = string.lower(Z.Util.Trim(tostring(arg or "")))
    if s == "on" or s == "1" or s == "true" then want = true
    elseif s == "off" or s == "0" or s == "false" then want = false end
  end
  if want == nil then want = not (Z.DB and Z.DB.rehearse) end
  if Z.DB then Z.DB.rehearse = want end
  if not want and M.rehearseRun then M.StopRehearsal() end
  Z.Print("Solo rehearsal " .. (want and "ON" or "OFF")
    .. " (corpse items roll with invented raiders, awards loot for real).")
end

-- Backwards-compatible alias (tests + loot rows call RequestRoll).
function M.RollNow(itemID) M.RequestRoll(itemID) end

-- Solo master-loot rehearsal (see /zl rehearse): each corpse item (never
-- coin) gets a roll window with 3-5 fake rolls from invented raiders,
-- then the ML awards it and the item is REALLY looted (solo corpse take
-- via the normal LootCorpseSlot path — no party, no master candidate).
-- Runs on the same live pipeline as sim (silent sessions, feed/finish
-- timers, award menu), but against a THROWAWAY scratch sheet swapped in
-- for the run: invented rollers never touch the real sheet's won marks
-- or history. No sheet required. Solo only; one corpse run at a time.
M.rehearseRun = false -- a rehearsal run is in progress
M.rehearseSavedSheet = nil -- real sheet parked here during the run
M.RehearseNames = { "Aldric", "Bryn", "Cora", "Dain", "Elswyth", "Fenna" }

function M.Rehearsing()
  return M.rehearseRun == true
end

-- Scratch sheet carrying the invented roster: FakeOpenRolls reads names
-- off items[].rollers, so one stub item holds the whole fake raid.
local function rehearsalSheet()
  local rollers = {}
  for i = 1, Z.Util.ArrayCount(M.RehearseNames) do
    table.insert(rollers, { name = M.RehearseNames[i] })
  end
  return { items = { [1] = { rollers = rollers } } }
end

function M.BuildRehearsalEntry(itemID, link)
  local n = math.random(3, 5)
  return { itemID = itemID, link = link, mode = "SIM-OPEN",
    rolls = M.FakeOpenRolls(rehearsalSheet(), 0, nil, { count = n }),
    rehearse = true }
end

-- Queue every non-coin corpse row for rehearsal play. No-ops unless the
-- Z.DB.rehearse flag is on, solo, idle, and the corpse actually holds
-- rollable rows. Auto-starts the head ONLY when the general rollAuto
-- master-loot option is on (default OFF: ML picks each Roll button)
-- (default OFF: the ML picks each item's Roll button). Returns the
-- queued count.
function M.StartRehearsal()
  if not (Z.DB and Z.DB.rehearse) then return 0 end
  if not (Z.SRSecurity and Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo()) then return 0 end
  if M.rehearseRun or M.Busy() then return 0 end
  if not (Z.SRData and Z.SRData.NewSheet) then return 0 end
  local W = Z.LootWindow
  if not W then return 0 end
  local n = 0
  for i = 1, Z.Util.ArrayCount(W.items) do
    local it = W.items[i]
    -- Live corpse rows only: never coin, never another flow's sim rows.
    if it and not it.coin and it.itemID and it.source ~= "sim" then
      table.insert(M.pending, M.BuildRehearsalEntry(it.itemID,
        it.link or ("item:" .. tostring(it.itemID))))
      n = n + 1
    end
  end
  if n == 0 then return 0 end
  M.rehearseSavedSheet = Z.DB.sheet -- park the real sheet (may be nil)
  Z.DB.sheet = Z.SRData.NewSheet() -- scratch: rehearsal marks stay here
  M.rehearseRun = true
  M.running = true
  Z.Print("Rehearsal: " .. n .. " item" .. (n == 1 and "" or "s")
    .. " queued — roll window + invented rolls, then award to loot.")
  if Z.DB.rollAuto then
    M.RehearseRoll(M.pending[1].itemID)
  else
    Z.Print("Rehearsal: pick an item's Roll button to start its roll.")
  end
  return n
end

-- Auto-play one queued rehearsal entry: same shape as RequestRoll, but
-- the detail flips to its rolling view (like the loot-window Roll
-- button does) so the ML watches the fake rolls land live. Entries
-- whose row already left the corpse are dropped (pre-roll award etc.).
function M.RehearseRoll(itemID)
  local MLUI = Z.MasterLootUI
  if MLUI and MLUI.session then return false end -- sequential holds
  for i = 1, Z.Util.ArrayCount(M.pending) do
    local entry = M.pending[i]
    if entry and entry.itemID == itemID and entry.rehearse then
      local W = Z.LootWindow
      local row = W and W.Find(itemID)
      if not row then
        table.remove(M.pending, i) -- row gone: drop, advance
        M.afterRehearsal()
        return
      end
      table.remove(M.pending, i)
      M.lives = M.lives or {}
      M.lives[itemID] = entry
      M.live = entry
      M.running = true
      local d = W.OpenDetail(itemID)
      if d then
        d.phase = "rolling"
        d.rolls = {}
        d.menu = nil
        d.status = "rolling"
        W.RefreshDetail()
      end
      M.playOne(entry)
      -- playOne BeginSession'd synchronously: stamp the session so the
      -- award path routes to the rehearsal continuation, and link the
      -- detail to it so fed rolls land on the open window.
      local sess = MLUI and MLUI.sessions and MLUI.sessions[itemID]
      if sess then sess.rehearse = true end
      if d then
        d.sessionID = sess and sess.id or nil
        W.RefreshDetail()
      end
      if W.MarkRolling then W.MarkRolling(itemID) end
      Z.Print("Rehearsal: rolling " .. dispName(itemID, entry.link) .. ".")
      return true
    end
  end
  return false
end

-- Drop a queued rehearsal entry (pre-roll award / cancel paths).
-- Returns true when anything was dropped (lets Cancel tell rehearsal
-- apart from sim requeue duty).
function M.DropRehearsal(itemID)
  local dropped = false
  for i = Z.Util.ArrayCount(M.pending), 1, -1 do
    local e = M.pending[i]
    if e and e.itemID == itemID and e.rehearse then
      table.remove(M.pending, i)
      dropped = true
    end
  end
  if M.lives and M.lives[itemID] then M.lives[itemID] = nil dropped = true end
  if M.live and M.live.itemID == itemID then M.live = nil dropped = true end
  return dropped
end

-- Continuation after a rehearsal award: auto-start the next queued item
-- only with the general rollAuto option on, else end the run when
-- the queue drains (ML in control)
-- (restore the real sheet) and report. Timer-deferred like sim.
function M.afterRehearsal()
  Z.Timer.After(1.0, function()
    if Z.DB and Z.DB.rollAuto then
      for i = 1, Z.Util.ArrayCount(M.pending) do
        local e = M.pending[i]
        if e and e.rehearse then M.RehearseRoll(e.itemID) return end
      end
    end
    for i = 1, Z.Util.ArrayCount(M.pending) do
      local e = M.pending[i]
      if e and e.rehearse then
        Z.Print("Rehearsal: pick the next item's Roll button (or enable auto-start).")
        return
      end
    end
    M.EndRehearsalRun("Rehearsal done — items looted, scratch sheet dropped.")
  end)
end

-- End the run anywhere (queue empty, /zl simstop, flag off): timers dead,
-- scratch sheet dropped, real sheet restored, windows left alone (awarded
-- rows already left the list; leftovers stay listed).
function M.EndRehearsalRun(msg)
  for i = Z.Util.ArrayCount(M.pending), 1, -1 do
    if M.pending[i] and M.pending[i].rehearse then
      table.remove(M.pending, i)
    end
  end
  if M.lives then
    for k, e in pairs(M.lives) do
      if e and e.rehearse then M.lives[k] = nil end
    end
  end
  if M.live and M.live.rehearse then M.live = nil end
  M.rehearseRun = false
  if M.rehearseSavedSheet ~= nil or Z.DB then
    Z.DB.sheet = M.rehearseSavedSheet -- nil when none was loaded: clean
  end
  M.rehearseSavedSheet = nil
  if not M.Busy() then M.running = false end
  if msg then Z.Print(msg) end
end

function M.StopRehearsal()
  if not M.rehearseRun then return false end
  if Z.Timer and Z.Timer.CancelAll then Z.Timer.CancelAll() end
  M.EndRehearsalRun("Rehearsal stopped — real sheet restored.")
  return true
end

-- Push the queue (+live session marker) into the shared loot window.
-- Awarded items LEAVE the list: a handed-out item is done, not a trophy.
-- The window always shows exactly what still needs the ML: the queued
-- entries plus the live (rolling) one. Nothing else.
function M.SyncLootWindow()
  if not Z.LootWindow then return end
  local W = Z.LootWindow
  local sheet = Z.DB and Z.DB.sheet
  local function badgeFor(itemID)
    local badge = ""
    if sheet and Z.SRData.ReserveBadge then
      badge = Z.SRData.ReserveBadge(sheet, itemID)
    elseif sheet and Z.SRData.GetRollers then
      local n = Z.Util.ArrayCount(Z.SRData.GetRollers(sheet, itemID))
      if n == 1 then badge = "SR" elseif n > 1 then badge = "SR:" .. n end
    end
    return badge
  end
  local function qualityFor(itemID)
    return (sheet and sheet.items[itemID] and sheet.items[itemID].quality) or 0
  end
  local rows = {}
  for i = 1, Z.Util.ArrayCount(M.pending) do
    local e = M.pending[i]
    table.insert(rows, { itemID = e.itemID, link = e.link,
      quality = qualityFor(e.itemID), badge = badgeFor(e.itemID) })
  end
  -- Live (rolling) items left the queue at Roll time but are only done
  -- once the ML awards them: keep each listed as rolling. No item may
  -- vanish mid-roll or on a no-winner finish; handed-out items never
  -- come back.
  if M.lives then
    for _, lv in pairs(M.lives) do
      if lv and lv.itemID then
        table.insert(rows, { itemID = lv.itemID, link = lv.link,
          quality = qualityFor(lv.itemID), badge = badgeFor(lv.itemID) })
      end
    end
  end
  W.SetItems(rows, "sim")
  local live = Z.MasterLootUI and Z.MasterLootUI.session
  if live and W.Find(live.itemID) then
    W.MarkRolling(live.itemID)
  end
end

-- Nothing left to loot: close the ML loot window and end the run.
-- A window with zero rows is not a record — the Sheet tab holds history.
function M.MaybeFinish()
  if Z.Util.ArrayCount(M.pending) > 0 then return end
  if M.lives then
    for _, lv in pairs(M.lives) do
      if lv then return end
    end
  end
  if Z.MasterLootUI and (Z.MasterLootUI.session ~= nil
      or Z.MasterLootUI.pendingAwardMenu ~= nil) then
    return
  end
  if M.running then
    M.running = false
    Z.Print("SIM done — window closed, see the Sheet tab.")
  end
  if Z.LootWindow and Z.LootWindow.Hide then Z.LootWindow.Hide() end
  if Z.RaiderLootUI and Z.RaiderLootUI.Hide then Z.RaiderLootUI.Hide() end
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
  M.ResetFresh() -- fresh loot session: no state from a previous sim
  local fillers = tonumber(n) or 0
  local entry = M.BuildEntry(sheet, itemID, link, fillers)
  Z.Print("SIM " .. entry.mode .. " item " .. dispName(itemID, link) .. " (" .. Z.Util.ArrayCount(entry.rolls) .. " rolls, replaying live with timers):")
  table.insert(M.pending, entry)
  M.auto = true -- one-shot: ML chose it by typing the command
  M.SyncLootWindow()
  M.RequestRoll(entry.itemID)
end

-- Random re-rolled subset of a static boss table (BossData fallback).
-- Self-contained in Sim.lua so the fallback NEVER depends on pfLoot
-- having loaded: shuffled distinct items, random count, one possible
-- double. Re-rolled every call, so consecutive runs vary.
local function RollStaticDrops(list, count)
  count = count or 4
  local n = Z.Util.ArrayCount(list or {})
  if n == 0 then return {} end
  local idx = {}
  for i = 1, n do idx[i] = i end
  for i = n, 2, -1 do
    local j = math.random(1, i)
    idx[i], idx[j] = idx[j], idx[i]
  end
  local maxk = math.min(count, n)
  local mink = math.min(2, maxk)
  local k = math.random(mink, maxk)
  if k < mink then k = mink elseif k > maxk then k = maxk end
  local out = {}
  for i = 1, k do table.insert(out, list[idx[i]]) end
  if k < count and math.random(1, 2) == 1 then
    table.insert(out, out[math.random(1, k)])
  end
  return out
end

function M.SimBoss(name)
  local sheet = M.RequireSheet()
  if not sheet then return end
  if M.Busy() then
    Z.Print("A roll or sim is already running — wait or /zl simstop.")
    return
  end
  name = Z.Util.Trim(name or "")
  -- Drop source, in order: live pfQuest loot table (random weighted picks
  -- from the boss's own drops, Rarescanner pattern) -> static BossData
  -- (random re-rolled subset, so every run varies even without pfQuest).
  local table_ = nil
  local source = "BossData"
  if Z.pfLoot then
    local picks = Z.pfLoot.BossDrops(name)
    if Z.Util.ArrayCount(picks) > 0 then
      table_ = picks
      source = "pfQuest (" .. Z.Util.ArrayCount(picks) .. " rolled drops)"
    end
  end
  if not table_ then
    local static = Z.BossData[name]
    if static then
      -- Always re-rolled fresh: the BossData table is a candidate pool,
      -- not a fixed drop list (no pfQuest needed for variance).
      table_ = RollStaticDrops(static)
      source = "BossData (" .. Z.Util.ArrayCount(table_) .. " rolled drops)"
    end
  end
  if not table_ then
    local avail = {}
    for b in pairs(Z.BossData) do table.insert(avail, b) end
    Z.Print("Unknown boss (not in pfQuest or BossData). Try: " .. table.concat(avail, ", "))
    return
  end
  local disp = name
  if Z.pfLoot and source ~= "BossData" then
    -- Show the localized pfQuest name when it differs (typed "rag" etc.).
    local entry = Z.pfLoot.EntryIdByName(name)
    if entry then disp = Z.pfLoot.NameOf(entry) .. " [" .. name .. "]" end
  end
  -- Show the actual rolled drops so the source and variance are visible.
  local ids = {}
  for i = 1, Z.Util.ArrayCount(table_) do table.insert(ids, tostring(table_[i])) end
  local idTxt = table.concat(ids, ", ")
  if idTxt == "" then idTxt = "(none rolled)" end
  Z.Print("SIM boss " .. disp .. " drops (" .. source .. "): " .. idTxt)
  M.ResetFresh() -- fresh loot session: no done rows / queue / detail from a previous run
  for i = 1, Z.Util.ArrayCount(table_) do
    local itemID = table_[i]
    table.insert(M.pending, M.BuildEntry(sheet, itemID, tostring(itemID), 0))
  end
  M.auto = false -- boss runs are ML-driven: Roll per item, like live loot
  for i = 1, Z.Util.ArrayCount(M.pending) do
    table.insert(M.lastEntries, { itemID = M.pending[i].itemID, link = M.pending[i].link })
  end
  M.running = true
  M.SyncLootWindow()
  if Z.LootWindow then Z.LootWindow.Show("Simulated loot: " .. tostring(name)) end
  Z.Print("Loot window open — click Roll on an item (or /zl simroll <item>).")
end

-- Transmog demo: like /zl sim, but the first sheet roller rolls TMOG
-- instead of SR, so the award window offers the TMOG kind winner.
function M.SimTmog(argText)
  local sheet = M.RequireSheet()
  if not sheet then return end
  if M.Busy() then
    Z.Print("A roll or sim is already running — wait or /zl simstop.")
    return
  end
  local link = string.match((argText or ""), "(%S+)")
  local itemID = Z.Util.ItemID(link or "")
  if not itemID then Z.Print("Usage: /zl simtmog <itemlink|itemID>") return end
  if sheet.items[itemID] == nil then
    Z.Print("simtmog needs an SR'd item (got " .. tostring(itemID) .. ").")
    return
  end
  local rollers = sheet.items[itemID].rollers or {}
  if not rollers[1] then Z.Print("simtmog needs an SR'd item with rollers.") return end
  local tmogName = rollers[1].name
  -- That player rolls TMOG *instead of* SR (live first-roll-only rule
  -- would drop their second roll, so the SR entry is replaced).
  local all = Z.Resolver.FakeRolls(sheet, itemID,
    { cap = Z.Caps.SR, count = M.FakeCount, tmog = { tmogName } })
  -- Everyone else rolls MS in this demo.
  local kept = {}
  for i = 1, Z.Util.ArrayCount(all) do
    local rv = all[i]
    if rv.name == tmogName and rv.type == "SR" then
      -- replaced by the TMOG entry below
    else
      if rv.type == "SR" then rv.type = "MS" end
      table.insert(kept, rv)
    end
  end
  local entry = { itemID = itemID, link = link, mode = "SIM", rolls = kept }
  Z.Print("SIM-TMOG item " .. dispName(itemID, link) .. " (" .. tostring(tmogName) .. " rolls TMOG instead of SR):")
  M.ResetFresh() -- fresh loot session: no state from a previous sim
  table.insert(M.pending, entry)
  M.auto = true
  M.SyncLootWindow()
  M.RequestRoll(entry.itemID)
end

-- A cancelled sim item goes back to the queue head so the ML can re-roll
-- it from the loot window (Cancel during a sim = "not this one, again").
--
-- Continue a parked sim roll: schedule FRESH fake rolls for the still-
-- unrolled sheet members, appended to the same session by feedRoll's
-- first-roll-only rule (already-rolled names are skipped, never doubled).
-- The continued chain is tracked so an early Finish kills it too.
function M.ContinueRoll(itemID)
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then return end
  local MLUI = Z.MasterLootUI
  local sess = MLUI and MLUI.sessions and MLUI.sessions[itemID] or nil
  if not sess then return end
  local seen = {}
  for i = 1, Z.Util.ArrayCount(sess.rolls or {}) do
    if sess.rolls[i] then seen[sess.rolls[i].name] = true end
  end
  local fresh = M.BuildEntry(sheet, itemID, sess.itemLink, 0)
  local n = 0
  for i = 1, Z.Util.ArrayCount(fresh.rolls or {}) do
    local rv = fresh.rolls[i]
    if rv and not seen[rv.name] then
      n = n + 1
      seen[rv.name] = true
      M.TrackTimer(itemID,
        Z.Timer.After(n * M.ROLL_GAP, function() feedRoll(sess, rv) end))
    end
  end
  if n > 0 then
    Z.Print("SIM: " .. n .. " more roll(s) coming in for "
      .. dispName(itemID, sess.itemLink) .. ".")
  else
    Z.Print("SIM: everyone already rolled — Finish to award.")
  end
end

-- A sim award landed: the live row becomes a done record (snapshotted by
-- the award path) and stops being live. Only clears the matching item.
function M.OnSimAwarded(itemID)
  if M.lives then M.lives[itemID] = nil end -- back in the queue, no longer live
  if M.live and M.live.itemID == itemID then M.live = nil end
end

function M.Requeue(itemID)
  if M.lives then M.lives[itemID] = nil end -- back in the queue, no longer live
  if M.live and M.live.itemID == itemID then M.live = nil end
  for i = 1, Z.Util.ArrayCount(M.pending) do
    if M.pending[i].itemID == itemID then return end -- still queued
  end
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then return end
  local link = tostring(itemID)
  for i = 1, Z.Util.ArrayCount(M.lastEntries or {}) do
    if M.lastEntries[i].itemID == itemID then link = M.lastEntries[i].link end
  end
  table.insert(M.pending, 1, M.BuildEntry(sheet, itemID, link, 0))
  M.running = true
  M.SyncLootWindow()
  Z.Print("SIM: item " .. dispName(itemID, nil) .. " back in the loot window.")
end
