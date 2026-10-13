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
M.live = nil      -- entry currently rolling: left the queue at Roll time,
                  -- listed as rolling until the ML awards it (never dropped)
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
  if M.running then return true end
  if Z.MasterLootUI then
    if Z.MasterLootUI.session ~= nil then return true end
    if Z.MasterLootUI.pendingAwardMenu ~= nil then
      return true -- ML still deciding the award
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
  M.lastEntries = {}
  M.pendingAward = nil
  M.auto = false
  M.running = false
  if Z.MasterLootUI then
    Z.MasterLootUI.session = nil
    Z.MasterLootUI.pendingAwardMenu = nil
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
  local wasRunning = M.running
      or M.live ~= nil
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
    -- An on-sheet item with no rollers (e.g. an unreserved stub from an
    -- earlier run) would otherwise roll with ZERO rolls and finish with
    -- no winner: fall back to an open roll of the whole sheet instead.
    if Z.Util.ArrayCount(rolls) == 0 then
      mode = "SIM-OPEN"
      rolls = M.FakeOpenRolls(sheet, fillers)
    end
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

-- Called after a sim award completes: asks for the next roll.
-- Continuation is timer-deferred so award confirmation never nests the
-- next item inside this call stack.
function M.afterAwards()
  Z.Timer.After(1.0, function() M.RequestNextRoll() end)
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
  -- A nil sess (re-read ML.session after a cancel/stop) is never the live
  -- session — and the nil==nil guard below would otherwise let it through
  -- to sess.itemID. No session, no feed.
  if not sess then return end
  if not Z.MasterLootUI or Z.MasterLootUI.session ~= sess then return end
  local minR, maxR = M.RangeFor(rv.type)
  Z.MasterLootUI.OnSystemRoll(rv.name, rv.roll, minR, maxR)
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
  if not ML or not ML.session then M.RequestNextRoll() return end
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
      Z.Timer.After(1.0, function() M.RequestNextRoll() end)
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
      Z.Timer.After(i * M.ROLL_GAP, function() feedRoll(tieSess, { name = nm, type = tieKind or "SR", roll = math.random(tmin, cap) }) end)
    end
    Z.Timer.After((Z.Util.ArrayCount(names) + 1) * M.ROLL_GAP + 0.2, function() finishSim(entry, round + 1) end)
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
  -- Capture the session (see tie re-rolls above): a cancel/stop before
  -- the feeds fire must silence them, not crash on a nil session.
  local playSess = ML.session
  for i = 1, Z.Util.ArrayCount(entry.rolls) do
    local rv = entry.rolls[i]
    Z.Timer.After(i * M.ROLL_GAP, function() feedRoll(playSess, rv) end)
  end
  Z.Timer.After(rollTime, function() finishSim(entry, 1) end)
end

-- Request the next roll: auto mode plays the queue head (the /zl sim
-- one-shot always auto-plays); manual mode waits for the ML's Roll click.
-- When the queue is empty AND nothing is live/deciding, the run is over:
-- the loot window closes (nothing left to hand out is not a record).
function M.RequestNextRoll()
  if M.auto then
    local head = M.pending[1]
    if head then M.RequestRoll(head.itemID) return end
  end
  if Z.MasterLootUI and Z.MasterLootUI.session then return end -- roll live
  if Z.MasterLootUI and Z.MasterLootUI.pendingAwardMenu then return end -- ML deciding
  M.SyncLootWindow()
  if Z.Util.ArrayCount(M.pending) == 0 and M.live == nil then
    M.MaybeFinish()
  else
    Z.Print("SIM: waiting for the ML — click Roll in the loot window.")
  end
end

-- The ML initiates one queued item (loot-window Roll button). Plays when
-- idle; a live session blocks (finish or /zl cr first).
function M.RequestRoll(itemID)
  if Z.MasterLootUI and Z.MasterLootUI.session then
    Z.Print("A roll is already running — finish or /zl cr first.")
    return
  end
  if M.live and M.live.itemID == itemID then
    Z.Print("Already rolling " .. dispName(itemID, nil) .. " — finish or /zl cr first.")
    return
  end
  for i = 1, Z.Util.ArrayCount(M.pending) do
    if M.pending[i].itemID == itemID then
      local entry = table.remove(M.pending, i)
      M.live = entry -- stays listed as rolling until the ML awards it
      M.running = true
      M.SyncLootWindow()
      Z.Print("SIM: rolling " .. dispName(entry.itemID, entry.link) .. " (ML pick).")
      M.playOne(entry)
      return
    end
  end
  Z.Print("SIM: item " .. tostring(itemID) .. " is not in the loot queue.")
end

-- Backwards-compatible alias (tests + loot rows call RequestRoll).
function M.RollNow(itemID) M.RequestRoll(itemID) end

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
  -- The live (rolling) item left the queue at Roll time but is only done
  -- once the ML awards it: keep it listed as rolling. No item may vanish
  -- mid-roll or on a no-winner finish; handed-out items never come back.
  if M.live then
    local lv = M.live
    table.insert(rows, { itemID = lv.itemID, link = lv.link,
      quality = qualityFor(lv.itemID), badge = badgeFor(lv.itemID) })
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
  if M.live ~= nil then return end
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
    { cap = Z.Caps.SR, sheetOnly = true, tmog = { tmogName } })
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
-- A sim award landed: the live row becomes a done record (snapshotted by
-- the award path) and stops being live. Only clears the matching item.
function M.OnSimAwarded(itemID)
  if M.live and M.live.itemID == itemID then M.live = nil end
end

function M.Requeue(itemID)
  if M.live and M.live.itemID == itemID then M.live = nil end -- back in the queue, no longer live
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
