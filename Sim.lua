-- ZugLoot/Sim.lua
-- In-game simulation: /zl sim <itemlink|itemID> [fillers], /zl simboss <boss>,
-- /zl simtmog <itemlink>, /zl simroll <item>, /zl simstop. Requires the loaded sheet (Z.DB.sheet): every roller is a
-- player from the sheet, and every simulated session is written back into the
-- sheet (sheet.rolls history + won marks + drop log), exactly like a live roll.
--
-- The async path (/zl sim, /zl simboss) replays the REAL live pipeline:
-- MasterLootUI session + group-routed chat + both windows, one item at a
-- time. Fake rolls are precomputed, then ECHOED as chat lines ("Name
-- rolls 42 (1-100)", ML-local only — the group never sees fakes) and
-- registered through the shared chat intake (IntakeChatRoll, the same
-- parser + router live /rolls travel), so the raider list fills live
-- exactly like a master-loot roll; the session finishes at once;
-- afterwards the ML picks the award from the menu and the queue advances
-- (/zl sim one-shots auto-play; simboss waits for the ML's Roll per
-- item). No timers: feeds + finish run inline (the old staggered-feed
-- timers are gone — every feed is a direct call, so no stale-feed
-- guards, timer bookkeeping, or drain pumps are needed).
-- Uses the same Resolver pure module as real sessions and as tests/.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.Sim = M

M.pending = {}   -- queued { itemID, link, mode, rolls } for the boss run
M.live = nil      -- legacy alias: the ACTIVE rolling entry (see M.lives).
                  -- kept so old readers/tests keep working.
M.lives = {}      -- [rollKey] = entry currently rolling (one per corpse+item).
                  -- Entries leave the queue at Roll time and stay listed
                  -- as rolling until the ML awards them (never dropped).
M.running = false -- a sim run is in progress (queue non-empty or item live)

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
-- Roll key for the lives table (corpse+item when pinned): a same-item
-- twin on another corpse gets its own live entry. Entries carry corpse
-- from BuildRehearsalEntry; sim entries queue bare (no corpse).
local function entryKey(entry, itemID)
  local MLUI = Z.MasterLootUI
  local c = entry and entry.corpse
  if c == nil and MLUI then c = MLUI.CorpseID() end
  return (MLUI and MLUI.RollKey(itemID, c)) or itemID
end

-- second /zl simboss for Ragnaros must not see the first run's done rows,
-- queue, detail, menu, raider rolls. Call AFTER the Busy guard (it wipes
-- running/session state) and BEFORE building the new queue/window.
function M.ResetFresh()
  M.pending = {}
  M.live = nil
  M.lives = {}
  M.lastEntries = {}
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
-- queue, clears the award menu, hides the loot window (+detail) and the
-- raider window — so nothing from this sim can linger into the next run.
-- The sheet (history/won marks already written) is untouched.
function M.Stop()
  -- A rehearsal run stops here too (sheet restored, queue dropped).
  if M.rehearseRun then M.StopRehearsal() end
  local wasRunning = M.running
      or (M.lives and next(M.lives) ~= nil)
      or (Z.MasterLootUI and (Z.MasterLootUI.session ~= nil
        or Z.MasterLootUI.pendingAwardMenu ~= nil))
      or (M.pending and Z.Util.ArrayCount(M.pending) > 0)
  M.ResetFresh() -- clears session, menu, queue + loot rows
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

-- Open-roll fakes: thin wrapper over Resolver.FakeRolls (shared code).
-- rng flows through so tests pin it; fillers adds RollerN entries
-- (legacy /zl sim <link> N path).
function M.FakeOpenRolls(sheet, fillers, rng, opts)
  opts = opts or {}
  opts.fillers = fillers
  return Z.Resolver.FakeRolls(sheet, nil, opts, rng)
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
      { count = M.FakeCount })
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
-- Direct call (no timer): feeds + finish already ran inline, so nothing
-- is in flight and the next item can start at once.
function M.afterAwards()
  M.RequestNextRoll()
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

-- Feed one fake roll into the live sim session: ECHO it as a chat line
-- ("Name rolls 42 (1-100)", ML-local only — the group never sees fakes)
-- and register it through the shared chat intake, exactly like a real
-- /roll. The 1.12 client derives the roll KIND from the /roll range, so
-- each fake echoes through its own kind's range (MS 1-100, OS 1-99,
-- TMOG 1-98) — the live ApplySystemRoll re-derives the kind from the
-- range, and the precomputed entry's type stamps the intent after (belt
-- and suspenders: a fake 1-100 from a non-holder must read MS, never
-- SR). The stamp runs against sess.rolls (the entry's own tables),
-- while the routing guard stays live-vs-dead only (EchoSimRoll refuses
-- parked/cancelled sessions).
local function feedRoll(sess, rv)
  -- A nil sess (re-read ML session after a cancel/stop) is never the
  -- live session. No session, no feed. The ML roll window mirrors the
  -- corrected kind (EchoSimRoll -> ApplySystemRoll -> DetailOnRoll
  -- already painted it; this only fixes the range-blind kind stamp).
  if not sess then return end
  if not Z.MasterLootUI then return end
  local MLUI = Z.MasterLootUI
  local cur = nil
  if sess.key ~= nil and MLUI.sessions then
    cur = MLUI.sessions[sess.key]
  elseif MLUI.sessions then
    cur = MLUI.SessionFor and MLUI.SessionFor(sess.itemID) or MLUI.sessions[sess.itemID]
  end
  if cur == nil then cur = MLUI.session end
  if cur ~= sess then return end
  local minR, maxR = M.RangeFor(rv.type)
  MLUI.EchoSimRoll(sess, rv.name, rv.roll, minR, maxR)
  if rv.type and sess and sess.rolls then
    for i = 1, Z.Util.ArrayCount(sess.rolls) do
      if sess.rolls[i].name == rv.name then
        sess.rolls[i].type = rv.type
        break
      end
    end
  end
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
-- Fully inline: feeds ran inline, so the finish resolves at once and tie
-- re-rolls feed + re-resolve in the same call (loop, not chain).
local function finishSim(entry, round)
  round = round or 1
  local ML = Z.MasterLootUI
  -- Rehearsal entries advance the rehearsal queue, never the sim queue.
  local nextFn = (entry and entry.rehearse) and M.afterRehearsal or M.RequestNextRoll
  if not ML or not ML.session then nextFn() return end
  while true do
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
      local outcome = ML.Finish()
    if outcome ~= "tie" then break end
    if Z.Util.ArrayCount(names) == 0 or round > M.TIE_ROUNDS then
      Z.Print("SIM tie left unresolved — re-roll manually or /zl cr.")
      ML.Cancel()
      nextFn()
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
    -- Same-session guard: a cancel/stop between rounds leaves ML.session
    -- nil or a different session — stop instead of feeding the void.
    local tieSess = ML.session
    if not tieSess then nextFn() return end
    for i = 1, Z.Util.ArrayCount(names) do
      local nm = names[i]
      if ML.session ~= tieSess then nextFn() return end
      feedRoll(tieSess, { name = nm, type = tieKind or "SR", roll = math.random(tmin, cap) })
    end
    round = round + 1
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
-- addon broadcast to other clients), both windows visible, rolls fed
-- inline, finish at once. Only the ML starts entries — playOne runs from
-- StartQueuedRoll (loot-window Roll button, auto mode, /zl sim one-shot).
function M.playOne(entry)
  local ML = Z.MasterLootUI
  ML.BeginSession(entry.itemID, entry.link, entry.mode, true)
  -- Stamp entry flags onto the fresh session at birth (synchronous:
  -- BeginSession just created it). Rehearsal sessions carry rehearse +
  -- the invented roster so the award path routes to the rehearsal queue
  -- and sheet writes fence off invented names. Stamping here (not in the
  -- caller) survives the inline finish — by the time RehearseRoll runs
  -- its post-playOne stamp, the session is already parked.
  if entry and entry.rehearse and ML then
    local born = ML.SessionFor and ML.SessionFor(entry.itemID)
    if born and born.itemID == entry.itemID then
      born.rehearse = true
      born.invented = entry.roster
    end
  end
  if Z.LootWindow then Z.LootWindow.MarkRolling(entry.itemID) end
  -- No forced sheet window: the sim plays in the loot + roll windows, and
  -- the sheet opens only on player request (/zl sheet).
  -- Capture THIS item's session table (per-item: ML.session re-aliases
  -- on every BeginSession, which would cross-wire parallel feeds).
  -- Own the rolling view here too: every starter (sim auto, simboss
  -- manual, rehearsal) funnels through playOne, so the detail flip lives
  -- in exactly one place and fed rolls always have a rolling-phase home
  -- (DetailOnRoll drops rolls for non-rolling details).
  local playSess = (ML.SessionFor and ML.SessionFor(entry.itemID)
    and ML.SessionFor(entry.itemID).itemID == entry.itemID
    and ML.SessionFor(entry.itemID))
    or ML.session
  if Z.LootWindow and Z.LootWindow.OpenDetail then
    local d = Z.LootWindow.OpenDetail(entry.itemID)
    if d then
      d.phase = "rolling"
      d.rolls = {}
      d.menu = nil
      d.status = "rolling"
      d.sessionID = playSess and playSess.id or nil
      Z.LootWindow.RefreshDetail()
      if Z.LootWindow.MarkRolling then Z.LootWindow.MarkRolling(entry.itemID) end
    end
  end
  -- Inline feeds: every precomputed roll lands now, in order. No timers
  -- means no stale-feed race — a cancel/stop simply finds no session and
  -- the feed guard refuses (cur ~= sess).
  for i = 1, Z.Util.ArrayCount(entry.rolls) do
    feedRoll(playSess, entry.rolls[i])
  end
  finishSim(entry, 1)
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

-- The ML initiates one queued item (loot-window Roll button, auto mode,
-- /zl sim one-shot, rehearsal auto-start). Sim + rehearsal share it:
-- both dequeue a precomputed entry and hand it to playOne. Sequential
-- holds: one roll runs at a time (a parked/finished item re-rolls only
-- via Continue, same session). Returns true when the entry started.
-- A parked (finished) item may start rolling again only via Continue
-- (same session); a FRESH roll of an item that already has a live
-- session is refused.
function M.StartQueuedRoll(itemID)
  local MLUI = Z.MasterLootUI
  local liveS = MLUI and MLUI.SessionFor and MLUI.SessionFor(itemID)
  if liveS and liveS.itemID == itemID then
    Z.Print("Already rolling " .. dispName(itemID, nil) .. " — finish or /zl cr first.")
    return false
  end
  -- Sequential holds: a LIVE roll anywhere refuses (finish, /zl cr, or
  -- close it first). Parked award menus do NOT block: the ML works
  -- several items at once (roll A, park, roll B, award B, award A).
  -- A pending award menu for ANOTHER item does not block: the ML works
  -- several items at once (roll A, park, roll B, award B, award A).
  -- Same-item re-roll while ITS menu pends is refused (award it first).
  if MLUI and MLUI.pendingAwardMenus then
    for k, pend in pairs(MLUI.pendingAwardMenus) do
      if pend and pend.sess and pend.sess.itemID == itemID then
        Z.Print("Already rolling " .. dispName(itemID, nil) .. " — finish or /zl cr first.")
        return false
      end
    end
  end
  if MLUI and MLUI.session then
    Z.Print("A roll is already running — finish, /zl cr, or close it first.")
    return false
  end
  local lkey = (MLUI and MLUI.RollKey(itemID)) or itemID
  if M.lives and M.lives[lkey] then
    Z.Print("Already rolling " .. dispName(itemID, nil) .. " — finish or /zl cr first.")
    return false
  end
  local entry, at = nil, nil
  for i = 1, Z.Util.ArrayCount(M.pending) do
    if M.pending[i] and M.pending[i].itemID == itemID then
      entry, at = M.pending[i], i
      break
    end
  end
  if not entry then
    Z.Print("SIM: item " .. tostring(itemID) .. " is not in the loot queue.")
    return false
  end
  -- Rehearsal entries are corpse-backed: a row that already left the
  -- corpse (pre-roll award etc.) drops instead of rolling a ghost.
  if entry.rehearse then
    local W = Z.LootWindow
    local row = W and W.Find and W.Find(itemID)
    if not row then
      table.remove(M.pending, at) -- row gone: drop, advance
      M.afterRehearsal()
      return false
    end
  end
  table.remove(M.pending, at)
  M.lives = M.lives or {}
  M.lives[entryKey(entry, entry.itemID)] = entry -- stays listed until the ML awards it
  M.live = entry -- active alias
  M.running = true
  M.SyncLootWindow()
  if entry.rehearse then
    Z.Print("Rehearsal: rolling " .. dispName(itemID, entry.link) .. ".")
  else
    Z.Print("SIM: rolling " .. dispName(entry.itemID, entry.link) .. " (ML pick).")
  end
  -- Rolling view + MarkRolling owned by playOne (shared starter).
  M.playOne(entry)
  -- playOne BeginSession'd synchronously: a rehearsal session stamps
  -- here too so the award path routes to the rehearsal continuation
  -- and fences the invented roster off sheet writes (SR typing, won,
  -- history skip these names — the real sheet stays pristine).
  if entry.rehearse then
    local sess = MLUI and MLUI.SessionFor and MLUI.SessionFor(itemID)
    if sess and sess.itemID == itemID then
      sess.rehearse = true
      sess.invented = entry.roster
    end
  end
  return true
end

-- Backwards-compatible names (tests, loot-window router, auto mode).
function M.RequestRoll(itemID) return M.StartQueuedRoll(itemID) end
function M.RehearseRoll(itemID) return M.StartQueuedRoll(itemID) end

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

-- Backwards-compatible aliases (tests + loot-window router).
function M.RollNow(itemID) return M.StartQueuedRoll(itemID) end

-- Solo master-loot rehearsal (see /zl rehearse): each corpse item (never
-- coin) gets a roll window with 3-5 fake rolls from invented raiders,
-- then the ML awards it and the item is REALLY looted (solo corpse take
-- via the normal LootCorpseSlot path — no party, no master candidate).
-- Runs on the same live pipeline as sim (silent sessions, feed/finish
-- timers, award menu) with the same FakeRolls generator (invented roster
-- via opts.roster). Sheet safety WITHOUT a swap: rehearsal sessions
-- carry an invented roster on the session (sess.invented), and the
-- sheet-touching paths (SR typing, won marks, history) consult it — so
-- invented rollers never touch the real sheet's won marks or history,
-- and the real sheet stays loaded throughout. No sheet required. Solo
-- only; one corpse run at a time.
M.rehearseRun = false -- a rehearsal run is in progress
M.RehearseNames = { "Aldric", "Bryn", "Cora", "Dain", "Elswyth", "Fenna" }

function M.Rehearsing()
  return M.rehearseRun == true
end

-- Rehearsal entries share the sim generator: same FakeRolls, invented
-- roster passed as opts.roster (no scratch sheet needed anymore).
function M.BuildRehearsalEntry(itemID, link)
  local n = math.random(3, 5)
  local MLUI = Z.MasterLootUI
  -- Copy the invented roster onto the entry: the live session stamps it
  -- as sess.invented so sheet writes skip these names.
  local roster = {}
  for i = 1, Z.Util.ArrayCount(M.RehearseNames) do
    roster[i] = M.RehearseNames[i]
  end
  return { itemID = itemID, link = link, mode = "SIM-OPEN",
    rolls = Z.Resolver.FakeRolls(nil, nil,
      { roster = roster, count = n }),
    roster = roster,
    rehearse = true,
    -- Owning corpse: the queue is per-corpse, so Park/Restore can shelve
    -- unplayed entries with their corpse instead of ResetFresh orphaning
    -- them on every new-corpse scan.
    corpse = MLUI and MLUI.lootKey or nil }
end

-- True when an itemID is already queued, live, or rolling anywhere —
-- shared by the top-up scan and corpse restore (no double-queue).
function M.RehearsalCovered(itemID)
  for i = 1, Z.Util.ArrayCount(M.pending) do
    local e = M.pending[i]
    if e and e.itemID == itemID and e.rehearse then return true end
  end
  local MLUI = Z.MasterLootUI
  local k = MLUI and MLUI.RollKey(itemID) or itemID
  if M.lives and M.lives[k] then return true end
  if MLUI and MLUI.SessionFor then
    local s2 = MLUI.SessionFor(itemID)
    if s2 and s2.itemID == itemID then return true end
  end
  if MLUI and MLUI.session and MLUI.session.itemID == itemID then return true end
  return false
end

-- Queue every non-coin corpse row for rehearsal play. No-ops unless the
-- Z.DB.rehearse flag is on, solo, and the corpse actually holds rollable
-- rows. Top-up semantics: a new corpse mid-run queues only items not
-- already queued/live/in-session (OnLootOpened's ResetFresh wipes the
-- queue on every corpse, so without this the second corpse would orphan
-- the first corpse's unplayed entries). Auto-starts the head ONLY when
-- the general rollAuto master-loot option is on AND nothing is live
-- (default OFF: ML picks each Roll button). Returns the queued count.
function M.StartRehearsal()
  if not (Z.DB and Z.DB.rehearse) then return 0 end
  if not (Z.SRSecurity and Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo()) then return 0 end
  -- No Busy guard here by design: OnLootOpened always runs ResetFresh
  -- first (fresh-corpse semantics kill live sims/rolls for EVERY mode
  -- equally), so by this point the table is definitionally idle. An
  -- active run tops up; a new run starts clean.
  if not (Z.SRData and Z.SRData.NewSheet) then return 0 end
  local W = Z.LootWindow
  if not W then return 0 end
  local MLUI = Z.MasterLootUI
  local n = 0
  for i = 1, Z.Util.ArrayCount(W.items) do
    local it = W.items[i]
    -- Live corpse rows only: never coin, never another flow's sim rows,
    -- never an item already queued/live/rolling.
    if it and not it.coin and it.itemID and it.source ~= "sim"
        and not M.RehearsalCovered(it.itemID) then
      table.insert(M.pending, M.BuildRehearsalEntry(it.itemID,
        it.link or ("item:" .. tostring(it.itemID))))
      n = n + 1
    end
  end
  if n == 0 then return 0 end
  if not M.rehearseRun then
    -- No sheet swap: the real sheet stays loaded (invented rollers are
    -- fenced off by the session invented roster instead).
    M.rehearseRun = true
    M.running = true
  end
  Z.Print("Rehearsal: " .. n .. " item" .. (n == 1 and "" or "s")
    .. " queued — roll window + invented rolls, then award to loot.")
  local idle = not (MLUI and MLUI.session)
  if Z.DB.rollAuto and idle then
    for i = 1, Z.Util.ArrayCount(M.pending) do
      local e = M.pending[i]
      if e and e.rehearse then M.RehearseRoll(e.itemID) break end
    end
  elseif not Z.DB.rollAuto then
    Z.Print("Rehearsal: pick an item's Roll button to start its roll.")
  end
  return n
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
  if M.lives then
    for k, e in pairs(M.lives) do
      if e and e.itemID == itemID then M.lives[k] = nil dropped = true end
    end
  end
  if M.live and M.live.itemID == itemID then M.live = nil dropped = true end
  return dropped
end

-- Continuation after a rehearsal award: auto-start the next queued item
-- only with the general rollAuto option on, else end the run when
-- the queue drains (ML in control). Direct call (feeds ran inline).
function M.afterRehearsal()
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
  M.EndRehearsalRun("Rehearsal done — items looted.")
end

-- End the run anywhere (queue empty, /zl simstop, flag off): invented
-- queue entries dropped, windows left alone (awarded rows already left
-- the list; leftovers stay listed). The real sheet was never swapped
-- (session invented rosters fence off sheet writes), so nothing restores.
function M.EndRehearsalRun(msg)
  -- Stray-call guard: with no run there is nothing to tear down.
  if not M.rehearseRun then return end
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
  if not M.Busy() then M.running = false end
  if msg then Z.Print(msg) end
end

function M.StopRehearsal()
  if not M.rehearseRun then return false end
  M.EndRehearsalRun("Rehearsal stopped.")
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
  Z.Print("SIM " .. entry.mode .. " item " .. dispName(itemID, link) .. " (" .. Z.Util.ArrayCount(entry.rolls) .. " rolls, replaying live):")
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
  -- That player rolls TMOG *instead of* SR (the shared generator takes
  -- tmog={name}); everyone else in this demo rolls MS (srOnly).
  local kept = Z.Resolver.FakeRolls(sheet, itemID,
    { count = M.FakeCount, tmog = { tmogName }, srOnly = true })
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
-- Continue a parked SILENT roll: feed FRESH fake rolls for the still-
-- unrolled members, appended to the same session by feedRoll's
-- first-roll-only rule (already-rolled names are skipped, never doubled).
-- Live (non-silent) sessions never feed fakes — the ML waits for real
-- /roll chat instead; the window is already rolling again. Mode-agnostic
-- entry: doAction "continue" calls FeedFreshRolls for every continued
-- roll, and the silent gate decides.
function M.FeedFreshRolls(itemID)
  local MLUI = Z.MasterLootUI
  local sess = MLUI and MLUI.SessionFor and MLUI.SessionFor(itemID) or nil
  if not sess or sess.itemID ~= itemID then return end
  if not sess.silent then return end -- live: real rolls land via chat
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then return end
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
      feedRoll(sess, rv)
    end
  end
  if n > 0 then
    Z.Print("SIM: " .. n .. " more roll(s) coming in for "
      .. dispName(itemID, sess.itemLink) .. ".")
  else
    Z.Print("SIM: everyone already rolled — Finish to award.")
  end
end

-- Backwards-compatible alias (tests + old callers).
function M.ContinueRoll(itemID) return M.FeedFreshRolls(itemID) end

-- A sim award landed: the live row becomes a done record (snapshotted by
-- the award path) and stops being live. Only clears the matching item.
function M.OnSimAwarded(itemID)
  if M.lives then -- clear every key copy (same item, twin corpses)
    for k, e in pairs(M.lives) do
      if e and e.itemID == itemID then M.lives[k] = nil end
    end
  end
  if M.live and M.live.itemID == itemID then M.live = nil end
end

function M.Requeue(itemID)
  if M.lives then -- clear every key copy (same item, twin corpses)
    for k, e in pairs(M.lives) do
      if e and e.itemID == itemID then M.lives[k] = nil end
    end
  end
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
