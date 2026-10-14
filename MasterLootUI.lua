-- ZugLoot/MasterLootUI.lua
-- RollFor-like master-looter console: loot list + session control + award confirm.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.MasterLootUI = M

-- Roll sessions, one per (corpse, item): the ML works several items at
-- once (roll A, close, roll B, award B, reopen A off its saved rolls) --
-- and the SAME item can roll on two corpses at once. Every roll table
-- below is keyed by ROLL KEY (corpse + item), never bare itemID: a bare
-- key lets corpse B's finish/award overwrite corpse A's parked session
-- and menu, drops A's rolls, and routes every later feed to the dead
-- item. Exactly one session is ACTIVE (its item's rolls feed the
-- session; chat/system rolls land there). M.session stays as the
-- active-session alias so every existing reader keeps working;
-- M.sessions holds the per-key rest.
M.session = nil -- active { key, corpse, id, itemID, itemLink, mode, rolls={}, t=0, itemCount=1 }
M.sessions = {} -- [rollKey] = session (active one included)

local sessionSeq = 0

-- Corpse identity for ROLL state (sessions, menus, parked details, sim
-- lives/timers): the PINNED corpse key (M.lootKey, guid: preferred, fp:
-- fallback), else nil (sim rows, /rf rolls, headless -- bare itemID keys,
-- as before). lootKey is pinned per open corpse and survives partial
-- loots; identity must not shift under a live roll, so sessions stamp it
-- once at BeginSession and lookups re-pin the same value while the corpse
-- is open. After the corpse closes/pins elsewhere (walk-back gap), keyed
-- lookups fall back: lone-copy resolution in ParkedDetail, keyless legacy
-- sessions in SessionFor.
function M.CorpseID()
  return M.lootKey
end

-- Roll key: corpse-scoped when a corpse is pinned, bare itemID otherwise
-- (numeric itemIDs stay numeric -- headless/sim/tests keep working).
function M.RollKey(itemID, corpse)
  if corpse == nil then corpse = M.CorpseID() end
  if corpse and corpse ~= "" then
    return tostring(corpse) .. "|" .. tostring(itemID)
  end
  return itemID
end

-- Key carried on a session table (stamped once at BeginSession, never
-- recomputed -- identity must not shift under a live roll). Keyless
-- sessions (legacy/test stubs) resolve against the given corpse.
local function sessKey(sess, corpse)
  if sess and sess.key ~= nil then return sess.key end
  if sess and sess.itemID ~= nil then return M.RollKey(sess.itemID, corpse) end
  return nil
end

-- Loot console is universal: anyone who can SEE the loot runs the window
-- (solo, party/raid of any loot method, master looter or not). Rolling and
-- awarding never need master-looter rights — only sheet broadcast does.
function M.RequireML()
  return true
end

-- Shared session start for live rolls and sim. silent=true skips the
-- addon-message broadcast (sim must not pop other clients' roller windows
-- or trigger their auto-rolls); the local raider window still shows.
-- One live roll at a time (sequential holds): starting a new roll while
-- another runs is refused by StartItemRoll/Sim.RequestRoll — a roll must
-- be finished, cancelled or stopped before the next starts. A finished
-- roll parks its session for award/continue; the parked session (never
-- the live table) is what survives across items.
function M.BeginSession(itemID, itemLink, mode, silent)
  sessionSeq = sessionSeq + 1
  local itemCount = 1
  if mode == "TWO" then itemCount = 2 end
  local sess = { key = M.RollKey(itemID), corpse = M.CorpseID(), id = sessionSeq, itemID = itemID, itemLink = itemLink, mode = mode, rolls = {}, t = 0, itemCount = itemCount, silent = silent }
  M.sessions = M.sessions or {}
  M.sessions[sess.key] = sess
  M.session = sess -- this roll is the active one
  -- Chat-visible name, resolved once (never a bare item:id in chat).
  sess.dispName = M.DisplayItemLink(itemID, itemLink)
  local label = sess.dispName
  if mode == "OPEN" then label = label .. " (open roll)"
  elseif mode == "RAID" then label = label .. " (raid roll)"
  elseif mode == "TWO" then label = label .. " (2 top win)" end
  if Z.Comm and Z.Comm.WarnGroup then
    Z.Comm.WarnGroup("ZugLoot rolling: " .. label .. " — /roll (" .. Z.DB.rollTime .. "s)")
  end
  if not silent and Z.Comm then
    Z.Comm.SendRollReq(sessionSeq, itemLink, mode)
  end
  if Z.RaiderLootUI then
    Z.RaiderLootUI.ShowItem(itemLink, Z.DB.rollTime)
  end
  Z.Print("Roll started (" .. mode .. ") session #" .. sessionSeq)
  if not silent and Z.AutoRoll and Z.AutoRoll.AllGreenAndAuto() then
    Z.Print("All SR rollers on auto — will auto-resolve on ROLL_ANS.")
  end
  return sess
end

-- Look up a roll session: this (corpse, item)'s own session when it has
-- one (multi-roll: each item owns its rolls; same item on two corpses
-- owns two), else the active session.
function M.SessionFor(itemID, corpse)
  if itemID and M.sessions then
    local k = M.RollKey(itemID, corpse)
    if M.sessions[k] then return M.sessions[k] end
    -- Fallback: a live keyless session for this item (legacy /rf / sim
    -- rows carry no corpse) is still this item's roll.
    for _, s2 in pairs(M.sessions) do
      if s2 and s2.key == nil and s2.itemID == itemID then return s2 end
    end
  end
  return M.session
end

-- Drop a session once its item is handed out. Active alias follows the
-- remaining sessions (or nil when none are left).
function M.DropSession(sess)
  if not sess then return end
  local k = sessKey(sess)
  if M.parkedSessions and k
      and M.parkedSessions[k] == sess then
    M.parkedSessions[k] = nil
  end
  if M.sessions and k and M.sessions[k] == sess then
    M.sessions[k] = nil
  end
  if M.session == sess then
    M.session = nil
    if M.sessions then
      for _, other in pairs(M.sessions) do
        if other then M.session = other break end
      end
    end
  end
end

function M.StartRoll(linkText, mode)
  if not M.RequireML() then return end
  local itemID = Z.Util.ItemID(linkText)
  if not itemID then Z.Print("Usage: /zl rf <itemlink>") return end
  M.BeginSession(itemID, linkText, mode, false)
end

-- ML initiates a roll for one loot-window item (loot list Roll button or
-- /zl roll <item>). Live corpse rows only; sim rows go via Sim.
-- Sequential holds: exactly one roll runs at a time. A finished roll is
-- parked (not live), so rolling ANOTHER item is fine — but re-rolling the
-- same item needs finish/cancel first.
function M.StartItemRoll(itemIDorLink)
  if not M.RequireML() then return end
  local itemID = Z.Util.ItemID(itemIDorLink)
  if not itemID then Z.Print("Usage: /zl roll <itemlink|itemID>") return end
  if M.SessionFor(itemID) and M.SessionFor(itemID).itemID == itemID then
    Z.Print("A roll is already running for this item — finish or /zl cr first.")
    return
  end
  if M.session then
    local liveID = M.session.itemID
    Z.Print("A roll is already running (" .. tostring(liveID)
      .. ") — finish, /zl cr, or close it first.")
    return
  end
  local link = itemIDorLink
  if Z.LootWindow then
    local it = Z.LootWindow.Find(itemID)
    if not it then
      Z.Print("Item " .. tostring(itemID) .. " is not in the loot window.")
      return
    end
    link = it.link or link
    Z.LootWindow.MarkRolling(itemID)
  end
  if type(link) ~= "string" or not string.find(link, "item:") then
    link = "item:" .. tostring(itemID)
  end
  M.BeginSession(itemID, link, "SR", false)
end

function M.OnRollAns(msg, sender)
  -- ROLL_ANS:<session>:<name>:<rollType> — auto-roll path confirmation.
  local sid = tonumber(string.match(msg, "ROLL_ANS:(%d+):") or "")
  if not sid then return end
  if M.sessions then
    for _, sess in pairs(M.sessions) do
      if sess and sess.id == sid then
        -- Auto answer counts as intent; real /roll still decides the number.
        return
      end
    end
  end
  if M.session and sid == M.session.id then return end
end

-- Route an incoming sim roll to its item's session: each roll feeds only
-- its own item. `itemID` pins the target; exact session-id matching
-- preferred. A finished (parked) session id is dead: never fall through
-- to another item — Continue re-attaches it explicitly.
function M.OnItemSystemRoll(itemID, player, roll, minR, maxR, sessionID)
  if not M.sessions then return end
  local sess = nil
  if sessionID then
    for _, s2 in pairs(M.sessions) do
      if s2 and s2.id == sessionID then sess = s2 break end
    end
    if sess == nil then return end
  end
  if not sess and itemID and M.sessions then
    -- Prefer the exact key (same item on two corpses: the feed carries
    -- its session id, so ambiguous item-only feeds must NOT spray both
    -- -- nil sessionID + two live same-item sessions = refuse to guess).
    local k = M.RollKey(itemID)
    if M.sessions[k] then
      sess = M.sessions[k]
    else
      for _, s2 in pairs(M.sessions) do
        if s2 and s2.key == nil and s2.itemID == itemID then
          sess = s2 break
        end
      end
    end
  end
  if not sess then return end
  M.ApplySystemRoll(sess, player, roll, minR, maxR)
end

-- Rolls land on the ACTIVE corpse's session. Parked corpses keep their
-- own sessions but collect no chat while parked (their window is closed);
-- re-looting resumes them via the cache. M.session always belongs to the
-- active corpse, so no routing table is needed.
function M.OnSystemRoll(player, roll, minR, maxR)
  if not M.session then return end
  M.ApplySystemRoll(M.session, player, roll, minR, maxR)
end

-- Core roll intake for ONE session (pure session target, no routing).
function M.ApplySystemRoll(sess, player, roll, minR, maxR)
  -- First-roll-only.
  for i = 1, Z.Util.ArrayCount(sess.rolls) do
    if sess.rolls[i].name == player then return end
  end
  -- Roll kind: the RANGE the player chose decides SR/MS vs OS vs TMOG,
  -- but 1-100 is SR only when they hold the reserve on this item —
  -- otherwise it is an MS roll. (Sheet lookup here so the roll window,
  -- award menu and resolver all see the same kind.)
  local rtype = "MS"
  if minR == 1 and maxR == Z.Caps.OS then rtype = "OS"
  elseif minR == 1 and maxR == Z.Caps.TMOG then rtype = "TMOG"
  elseif minR == 1 and maxR == Z.Caps.SR then
    rtype = "MS"
    if Z.DB.sheet and Z.SRData.GetRollers then
      local rollers = Z.SRData.GetRollers(Z.DB.sheet, sess.itemID)
      for i = 1, Z.Util.ArrayCount(rollers) do
        if rollers[i].name == player then rtype = "SR" break end
      end
    end
  end
  table.insert(sess.rolls, { name = player, roll = roll, type = rtype })
  -- Already-won flag is SR-only info (MS/OS/TMOG stay contestable); the
  -- live list shows it, the resolver enforces it per kind.
  local excluded = false
  if rtype == "SR" and Z.DB.sheet and Z.SRData.HasWon then
    excluded = Z.SRData.HasWon(Z.DB.sheet, sess.itemID, player)
  end
  if Z.RaiderLootUI then
    Z.RaiderLootUI.OnRoll(player, roll, rtype, excluded)
  end
  -- The open row detail is the ML roll window: show the roll + its kind.
  -- Effective mirrors the resolver (SR bonus when the sheet knows them).
  if Z.LootWindow and Z.LootWindow.DetailOnRoll then
    local eff = roll
    if Z.DB.sheet and rtype == "SR" then
      local rollers = Z.SRData.GetRollers(Z.DB.sheet, sess.itemID)
      for i = 1, Z.Util.ArrayCount(rollers) do
        if rollers[i].name == player then
          eff = roll + (rollers[i].sr_plus or 0)
          break
        end
      end
    end
    Z.LootWindow.DetailOnRoll(sess.itemID, sess.id, player, roll, rtype, eff)
  end
end

-- Finish/cancel target one item's roll without touching the others.
-- No arg = the active (open) item; /zl fr|cr keep working untouched.
-- After a finish the session parks (roll ended, award pending): Finish
-- flips the rolling view to winners on that item's detail, parked or open.
function M.ActiveItemID()
  if Z.LootWindow and Z.LootWindow.detail then
    return Z.LootWindow.detail.itemID
  end
  if M.session then return M.session.itemID end
  return nil
end

function M.FinishEarly(itemID) M.Finish(true, itemID) end
function M.Cancel(itemID)
  local sess = M.SessionFor(itemID) or M.session
  if not sess then Z.Print("No active session.") return end
  local wasSilent = sess.silent
  local itemID = sess.itemID
  local sessionID = sess.id
  local ck = M.RollKey(itemID)
  if M.pendingAwardMenus then M.pendingAwardMenus[ck] = nil end
  if not M.pendingAwardMenus then M.pendingAwardMenu = nil end
  if Z.Sim and Z.Sim.KillItemTimers then Z.Sim.KillItemTimers(itemID) end
  M.DropSession(sess)
  Z.Print("Roll cancelled.")
  if Z.LootWindow and itemID then Z.LootWindow.MarkOpen(itemID) end
  -- A rolling detail whose session just died can never receive rolls
  -- or a finish: close it outright (stale feed timers then find nothing).
  -- A same-item detail that is NOT rolling (award menu etc.) is untouched.
  if Z.LootWindow and Z.LootWindow.detail
      and Z.LootWindow.detail.itemID == itemID then
    if (Z.LootWindow.detail.phase or "pick") == "rolling" then
      Z.LootWindow.CloseDetail()
    elseif Z.LootWindow.detail.sessionID == sessionID then
      Z.LootWindow.detail.phase = "pick"
      Z.LootWindow.detail.sessionID = nil
      Z.LootWindow.detail.rolls = {}
      Z.LootWindow.detail.menu = nil
      Z.LootWindow.detail.status = "open"
      Z.LootWindow.RefreshDetail()
    end
  end
  if Z.RaiderLootUI then Z.RaiderLootUI.Hide() end
  -- A cancelled sim item returns to the queue head for a re-roll.
  -- Rehearsal rolls just drop their queue entry (row back to open; the
  -- ML re-rolls by hand or re-loots the corpse).
  if wasSilent and Z.Sim and Z.Sim.Requeue then
    local isReh = Z.Sim.DropRehearsal and Z.Sim.DropRehearsal(itemID)
    if not isReh then Z.Sim.Requeue(itemID) end
  end
end

-- Park a finished-but-unawarded roll: the session leaves the live table
-- but keeps its rolls in M.parkedSessions; the award menu stays pending.
-- Continue re-attaches it so more rolls append to the SAME list.
M.parkedSessions = nil
function M.ParkSession(sess)
  if not sess then return end
  local k = sessKey(sess)
  M.parkedSessions = M.parkedSessions or {}
  M.parkedSessions[k] = sess
  if M.sessions and k and M.sessions[k] == sess then
    M.sessions[k] = nil
  end
  if M.session == sess then
    M.session = nil
    if M.sessions then
      for _, other in pairs(M.sessions) do
        if other then M.session = other break end
      end
    end
  end
end

-- The live session table, parked or not: parked sessions stay
-- resolvable for award/continue decisions while collecting no rolls.
function M.SessionAny(itemID)
  if not itemID then return M.session end
  local k = M.RollKey(itemID)
  if M.sessions and M.sessions[k] then return M.sessions[k] end
  if M.parkedSessions and M.parkedSessions[k] then
    return M.parkedSessions[k]
  end
  return nil
end

-- Re-attach a parked session so a continued roll appends to the same list.
function M.UnparkSession(sess)
  if not sess then return end
  local k = sessKey(sess)
  if M.parkedSessions and M.parkedSessions[k] == sess then
    M.parkedSessions[k] = nil
  end
  M.sessions = M.sessions or {}
  M.sessions[k] = sess
  M.session = sess
end

-- A parked session by item (nil once awarded/cancelled).
function M.ParkedSession(itemID)
  if itemID and M.parkedSessions then
    local k = M.RollKey(itemID)
    if M.parkedSessions[k] then return M.parkedSessions[k] end
    -- Unscoped lookup (walk-back before the corpse re-pins): exactly one
    -- parked session for this item returns it; two corpses = ambiguous,
    -- nil (the pinned path above owns that case).
    local found = nil
    for _, s2 in pairs(M.parkedSessions) do
      if s2 and s2.itemID == itemID then
        if found then return nil end
        found = s2
      end
    end
    return found
  end
  return nil
end

-- Returns "tie" (session left open for re-rolls), "awaiting" (sim awards
-- pending ML confirmation), or "closed". Live callers ignore the result.
-- Targets one item's session: no arg finishes the ACTIVE (open) item; pass
-- an itemID to finish a held roll. A clean finish PARKS the session (roll
-- ended, award pending): more rolls can't land on it, but Continue
-- re-attaches it explicitly.
function M.Finish(manual, itemID)
  local sess = M.SessionFor(itemID) or M.session
  if not sess then Z.Print("No active session.") return "closed" end
  M.session = sess
  local sheet = Z.DB and Z.DB.sheet
  local openRoll = sess.mode == "OPEN" or sess.mode == "RAID" or sess.mode == "SIM-OPEN"
  local res = Z.Resolver.ResolveItem(sheet or { items = {}, won = {} }, sess.itemID, sess.rolls,
    { cap = Z.Caps.SR, requireSR = (not openRoll and sheet ~= nil), itemCount = sess.itemCount })
  M.AnnounceResult(sess, res)
  if Z.Util.ArrayCount(res.tied) > 0 then
    Z.Print("Tie at top — tied players re-roll.")
    return "tie" -- keep session open for tie re-rolls (extra rolls ignored for others)
  end
  local data = M.BuildAwardMenu(sess, res)
  -- The roll is OVER for this item (early or on time): its sim feed/tie
  -- chain must die here, or fake rolls keep landing after the finish.
  if Z.Sim and Z.Sim.KillItemTimers then Z.Sim.KillItemTimers(sess.itemID) end
  -- Park the finished session: award stays pending, but the roll is
  -- closed for new rolls (Continue re-attaches it explicitly).
  M.ParkSession(sess)
  -- The open row detail becomes the award window (RollFor: rolling view
  -- flips to winners). Falls back to the standalone menu when the roll
  -- was started outside the window (/rf etc.).
  if Z.LootWindow and Z.LootWindow.DetailOnFinish then
    Z.LootWindow.DetailOnFinish(sess.itemID, data)
  end
  if sess.silent then
    -- Sim: hand the menu to the ML (headless: auto-pick the top winner,
    -- like the old ConfirmAward chain); the award flow owns continuation.
    M.HandleSimAward(sess, data)
    return "awaiting"
  end
  M.ShowAwardMenu(sess, data)
  -- Menu stays pending: the ML awards, continues, or cancels. Callers
  -- must check M.session / the pending menus.
  return "awaiting"
end

-- Class-colored display name. Chat-bound lines stay PLAIN (no color
-- codes in addon chat), everything rendered in a frame/text UI is colored.
local function PName(name)
  if Z.ClassColors and Z.ClassColors.ColoredName then
    return Z.ClassColors.ColoredName(name)
  end
  return tostring(name or "")
end

-- Chat carries no color codes: strip any "|c..name|r" wrap the resolver
-- may hand back (defensive; stored data is raw by contract).
local function ChatName(name)
  local s = tostring(name or "")
  local inner = string.match(s, "^|c%x%x%x%x%x%x%x%x(.+)|r$")
  if inner then return inner end
  return s
end

function M.AnnounceResult(sess, res)
  local parts = {}
  for i = 1, Z.Util.ArrayCount(res.ranked) do
    local e = res.ranked[i]
    local nm = (e and e.name) or "?"
    local s = ChatName(nm) .. " " .. tostring(e and e.base)
    if e and e.sr_plus and e.sr_plus > 0 then s = s .. "(+" .. e.sr_plus .. "=" .. e.effective .. ")" end
    table.insert(parts, s)
  end
  if Z.Util.ArrayCount(res.missrolls) > 0 then
    local mm = {}
    for i = 1, Z.Util.ArrayCount(res.missrolls) do table.insert(mm, ChatName(res.missrolls[i].name)) end
    table.insert(parts, "missrolls: " .. table.concat(mm, ","))
  end
  -- Already-won rollers can't win again but stay visible.
  local excl = res.excluded or {}
  if Z.Util.ArrayCount(excl) == 0 and res.entries then
    for i = 1, Z.Util.ArrayCount(res.entries) do
      local e = res.entries[i]
      if e.excludedWon and not e.missroll then table.insert(excl, e) end
    end
  end
  if Z.Util.ArrayCount(excl) > 0 then
    local xm = {}
    for i = 1, Z.Util.ArrayCount(excl) do
      local e = excl[i]
      local s = ChatName(e.name) .. " " .. tostring(e.base)
      if e.sr_plus and e.sr_plus > 0 then s = s .. "(+" .. e.sr_plus .. "=" .. (e.effective or e.base) .. ")" end
      table.insert(xm, s .. " [already won]")
    end
    table.insert(parts, "excluded: " .. table.concat(xm, ", "))
  end
  local itemTxt = sess.dispName or sess.itemLink or ("item:" .. tostring(sess.itemID))
  local resultText = "ZugLoot result [" .. tostring(itemTxt) .. "]: " .. table.concat(parts, " | ")
  if Z.Comm and Z.Comm.SayGroup then
    Z.Comm.SayGroup(resultText)
  else
    Z.Print(resultText)
  end
  -- Per-kind result lines: each type is judged by itself (SR 100, MS
  -- 100, OS 99, TMOG 98), priority SR > MS > OS.
  local pt = res.perType or {}
  local function kindLine(kind, tag)
    local row = pt[kind]
    if row and row.entry then
      local e = row.entry
      local s = tag .. " winner: " .. ChatName(e.name) .. " (" .. tostring(e.effective) .. ")"
      if Z.Comm and Z.Comm.WarnGroup then Z.Comm.WarnGroup(s) else Z.Print(s) end
      return e
    end
    return nil
  end
  local srW = kindLine("SR", "SR")
  local msW = kindLine("MS", "MS")
  local osW = kindLine("OS", "OS")
  local tmogRow = pt.TMOG
  if tmogRow and tmogRow.entry then
    local e = tmogRow.entry
    local line = "TMOG winner: " .. ChatName(e.name) .. " (" .. tostring(e.effective) .. ")"
    if Z.Comm and Z.Comm.WarnGroup then Z.Comm.WarnGroup(line) else Z.Print(line) end
  end
  if Z.Util.ArrayCount(res.winners) > 0 then
    local w = {}
    for i = 1, Z.Util.ArrayCount(res.winners) do table.insert(w, PName(res.winners[i].name) .. " (" .. res.winners[i].effective .. ")") end
    -- LootBlare-style top-screen banner for the local player.
    if Z.RaiderLootUI and Z.RaiderLootUI.ShowResult then
      Z.RaiderLootUI.ShowResult("The winner is " .. table.concat(w, ", ") .. " !")
    end
  else
    if Z.RaiderLootUI and Z.RaiderLootUI.ShowResult then
      Z.RaiderLootUI.ShowResult("No winner this time.")
    end
  end
  -- Persist the session into per-item roll history (survives the session).
  -- Same shape the sim writes (Resolver.ToHistoryEntry).
  if Z.DB and Z.DB.sheet and Z.SRData.RecordRolls then
    -- Item rolled but never SR'd: stub it onto the sheet so it shows at the
    -- bottom, flagged as not SR'd. Only when rolls actually happened.
    if Z.Util.ArrayCount(res.entries or {}) > 0 and Z.SRData.EnsureUnreserved then
      local q = nil
      if GetItemInfo then
        local _, _, qq = GetItemInfo(tonumber(sess.itemID))
        q = qq
      end
      if Z.SRData.EnsureUnreserved(Z.DB.sheet, sess.itemID, q) then
        Z.Print("Note: " .. tostring(sess.dispName or sess.itemLink or sess.itemID) .. " was not on the SR sheet — added below, marked not SR'd.")
      end
    end
    Z.SRData.RecordRolls(Z.DB.sheet, sess.itemID,
      Z.Resolver.ToHistoryEntry(res, sess.mode, (time and time()) or 0))
    if Z.MainWindow then Z.MainWindow.Refresh() end
  end
end

-- Award menu data (RollFor RollController-finish style, pure data for
-- tests + text/headless render; a client frame shows the same rows).
-- Returns { winners, groups, perType, candidates, res, none }.
--
-- winners: overall winner(s) by priority SR > MS > OS (+effective).
-- perType: each kind judged by itself — { SR={entry,tied}, MS=..., OS=...,
--   TMOG=... } — so the menu can award each kind's own winner. The ML
--   awards the SR, MS, OS or TMOG winner directly; what happens to the
--   item afterwards (e.g. a trade) is outside the addon.
-- groups: SR>MS>OS>TMOG full lists {name, rollType, effective}.
-- candidates: class-sorted full roster the ML can award any raider from
--   when something is wrong with the rolls.
-- none: true when nobody eligible rolled.
-- Live name -> raw class map: raid roster, party units, self (shared with
-- the roll window via ClassColors). Values are client-reported; callers
-- normalize. Nil-safe: {} with no client APIs.
function M.RosterClasses()
  if Z.ClassColors and Z.ClassColors.RosterMap then
    return Z.ClassColors.RosterMap()
  end
  local map = {}
  if GetNumRaidMembers and GetNumRaidMembers() > 0 and GetRaidRosterInfo then
    for i = 1, GetNumRaidMembers() do
      local name, _, _, _, _, class = GetRaidRosterInfo(i)
      if name and name ~= "" then map[name] = class end
    end
  elseif GetNumPartyMembers and UnitName then
    local me = UnitName("player")
    if me then
      local _, cls = nil, nil
      if UnitClass then _, cls = UnitClass("player") end
      map[me] = cls
    end
    for i = 1, GetNumPartyMembers() do
      local n = UnitName("party" .. i)
      if n then
        local _, cls = nil, nil
        if UnitClass then _, cls = UnitClass("party" .. i) end
        map[n] = cls
      end
    end
  end
  if UnitName then
    local me = UnitName("player")
    if me and not map[me] then
      local _, cls = nil, nil
      if UnitClass then _, cls = UnitClass("player") end
      map[me] = cls
    end
  end
  return map
end

function M.BuildCandidates(sheet, sessRolls)
  -- Class-sorted roster: sheet players + seen rollers + raid roster, unique.
  local seen = {}
  local names = {}
  local function add(n)
    if n and n ~= "" and not seen[n] then seen[n] = true table.insert(names, n) end
  end
  for i = 1, Z.Util.ArrayCount(sessRolls or {}) do
    if sessRolls[i] then add(sessRolls[i].name) end
  end
  if sheet then
    local all = Z.SRData.AllPlayerNames(sheet)
    for i = 1, Z.Util.ArrayCount(all) do add(all[i]) end
    local function addEntries(ents)
      for e = 1, Z.Util.ArrayCount(ents or {}) do add(ents[e].name) end
    end
    for _, h in pairs(sheet.rolls or {}) do
      if type(h) == "table" then
        if h.entries ~= nil then addEntries(h.entries) -- single record
        else -- array of records (itemID -> { rec, ... })
          for r = 1, Z.Util.ArrayCount(h) do
            if type(h[r]) == "table" then addEntries(h[r].entries) end
          end
        end
      end
    end
  end
  local classes = M.RosterClasses()
  for n in pairs(classes) do add(n) end
  local out = {}
  for i = 1, Z.Util.ArrayCount(names) do
    local raw = classes[names[i]]
    local canon = raw
    if Z.ClassColors and Z.ClassColors.NormalizeClass then
      canon = Z.ClassColors.NormalizeClass(raw)
    end
    -- Sheet fallback: the live roster may not know everyone.
    if not canon and sheet and Z.SRData and Z.SRData.PlayerClass then
      canon = Z.SRData.PlayerClass(sheet, names[i])
    end
    table.insert(out, { name = names[i], class = canon })
  end
  -- Class first (unknown last), then name — RollFor's roster ordering.
  table.sort(out, function(a, b)
    local ca, cb = a.class or "~~~", b.class or "~~~"
    if ca ~= cb then return ca < cb end
    return (a.name or "") < (b.name or "")
  end)
  return out
end

local function entryRollType(e)
  local t = e.rollType or "SR"
  if t ~= "SR" and t ~= "MS" and t ~= "OS" and t ~= "TMOG" then t = "MS" end
  return t
end

function M.BuildAwardMenu(sess, res)
  local data = { winners = {}, groups = { SR = {}, MS = {}, OS = {}, TMOG = {} },
    perType = {}, candidates = {}, res = res, none = false,
    itemID = sess.itemID, itemLink = sess.itemLink, sessionID = sess.id }
  local entries = res.entries or {}
  for i = 1, Z.Util.ArrayCount(entries) do
    local e = entries[i]
    if not e.missroll and not e.excludedWon and not e.overCap then
      table.insert(data.groups[entryRollType(e)],
        { name = e.name, rollType = entryRollType(e), effective = e.effective or e.base })
    end
  end
  -- Rank groups best-first (ties by name).
  for _, g in pairs(data.groups) do
    table.sort(g, function(a, b)
      if (a.effective or 0) ~= (b.effective or 0) then return (a.effective or 0) > (b.effective or 0) end
      return (a.name or "") < (b.name or "")
    end)
  end
  -- Per-type contests straight from the resolver (each kind by itself).
  data.perType = res.perType or {}
  local winners = res.winners or {}
  for i = 1, Z.Util.ArrayCount(winners) do
    local w = winners[i]
    table.insert(data.winners, { name = w.name, rollType = w.rollType or "SR",
      effective = w.effective })
  end
    if Z.Util.ArrayCount(data.winners) == 0 then data.none = true end
  data.candidates = M.BuildCandidates(Z.DB and Z.DB.sheet, sess.rolls)
  return data
end

function M.AwardMenuLines(data)
  local lines = {}
  local menuName = data.itemLink
  if Z.MasterLootUI and Z.MasterLootUI.DisplayItemLink then
    menuName = Z.MasterLootUI.DisplayItemLink(data.itemID, data.itemLink)
  end
  table.insert(lines, "Award " .. tostring(menuName) .. " to?")
  -- Each kind judged by itself (ranges: SR 100, MS 100, OS 99, TMOG 98).
  -- Names render in class color (plain in addon chat — the client chat
  -- frame has no FontString coloring, so colored lines would show codes).
  for _, gt in ipairs({ "SR", "MS", "OS", "TMOG" }) do
    local row = (data.perType or {})[gt]
    if row and row.entry then
      local e = row.entry
      table.insert(lines, "  " .. gt .. " winner: " .. PName(e.name) .. " (" .. tostring(e.effective) .. ")")
      for t = 1, Z.Util.ArrayCount(row.tied or {}) do
        table.insert(lines, "    tied: " .. PName(row.tied[t].name) .. " (" .. tostring(row.tied[t].effective) .. ")")
      end
    end
  end
  for i = 1, Z.Util.ArrayCount(data.winners or {}) do
    local w = data.winners[i]
    table.insert(lines, "  overall: " .. PName(w.name) .. " (" .. tostring(w.rollType) .. " " .. tostring(w.effective) .. ")")
  end
  for _, gt in ipairs({ "SR", "MS", "OS", "TMOG" }) do
    local g = (data.groups or {})[gt] or {}
    for j = 1, Z.Util.ArrayCount(g) do
      table.insert(lines, "  " .. gt .. ": " .. PName(g[j].name) .. " (" .. tostring(g[j].effective) .. ")")
    end
  end
  if data.none then table.insert(lines, "  (no eligible rolls — pick anyone or cancel)") end
  local cands = data.candidates or {}
  local names = {}
  for i = 1, Z.Util.ArrayCount(cands) do
    local c = cands[i]
    table.insert(names, PName(c.name))
  end
  if Z.Util.ArrayCount(names) > 0 then
    table.insert(lines, "  candidates: " .. table.concat(names, ", "))
  end
  return lines
end

-- Show the award menu (RollFor finish-popup equivalent). Client builds the
-- frame with winner buttons + roll-type rows + candidate grid; headless and
-- text clients (tests, /zl text UIs) get the same rows printed so the ML
-- can answer with /zl award <name>. Stores the pending menu for AwardChosen
-- PER ITEM (multi-roll: each finished item keeps its own decision point).
-- M.pendingAwardMenu stays as the legacy alias of the active item's menu.
function M.ShowAwardMenu(sess, data)
  M.pendingAwardMenus = M.pendingAwardMenus or {}
  local sk = sess.key or M.RollKey(sess.itemID)
  M.pendingAwardMenus[sk] = { sess = sess, data = data }
  M.pendingAwardMenu = M.pendingAwardMenus[sk]
  if Z.AwardMenuUI and Z.AwardMenuUI.Show then
    Z.AwardMenuUI.Show(sess, data)
    return
  end
  local lines = M.AwardMenuLines(data)
  for i = 1, Z.Util.ArrayCount(lines) do Z.Print(lines[i]) end
  Z.Print("Pick with /zl award <name> (or /zl cr to cancel).")
end

-- Display link for award UI: the readable name, never a bare item:id.
-- Prefers the LootWindow row name (resolved at scan), else the [Name] in a
-- full link, else the sheet name via GetItemInfo, else the link as-is.
function M.DisplayItemLink(itemID, itemLink)
  if Z.LootWindow then
    local it = Z.LootWindow.Find(itemID)
    if it and Z.LootWindow.DisplayName then
      local nm = Z.LootWindow.DisplayName(it)
      if nm and nm ~= "" and nm ~= ("item:" .. tostring(itemID)) then
        return nm
      end
    elseif it and it.name and it.name ~= "" then
      return tostring(it.name)
    end
  end
  local link = tostring(itemLink or "")
  local nm = string.match(link, "%[(.-)%]")
  if nm and nm ~= "" then return nm end
  if GetItemInfo and Z.LootWindow and Z.LootWindow.ResolveItemInfo then
    local rName = Z.LootWindow.ResolveItemInfo(itemID, itemLink, nil, nil, nil)
    if rName and rName ~= "" then return tostring(rName) end
  end
  if link ~= "" then return link end
  return "item:" .. tostring(itemID)
end

-- Award popup text helper (pre-formatted: the client must not fill %s).
local function showAwardPopup(itemLink, winnerName, onAccept)
  if not (StaticPopupDialogs and StaticPopup_Show) then return false end
  StaticPopupDialogs["ZUGLOOT_AWARD"] = StaticPopupDialogs["ZUGLOOT_AWARD"] or {
    text = "",
    button1 = "Award", button2 = "Cancel",
    OnAccept = function() end, timeout = 0, whileDead = 1,
  }
  -- Confirm shows the ITEM NAME (regression: bare item:id here). The full
  -- link stays on the dialog for shift-click/insert parity.
  local display = tostring(itemLink)
  if Z.MasterLootUI and Z.MasterLootUI.DisplayItemLink then
    local id = Z.Util.ItemID(itemLink)
    display = Z.MasterLootUI.DisplayItemLink(id, itemLink)
  end
  StaticPopupDialogs["ZUGLOOT_AWARD"].text =
    string.format("Award %s to %s?", display, PName(winnerName))
  StaticPopupDialogs["ZUGLOOT_AWARD"].itemLink = itemLink
  StaticPopupDialogs["ZUGLOOT_AWARD"].OnAccept = onAccept or function() end
  StaticPopup_Show("ZUGLOOT_AWARD")
  return true
end

-- Loot one corpse slot through Blizzard's loot frame (nil-safe: no-ops
-- headless and when the slot can't be resolved). Master loot hands the
-- corpse item to the winner; any other method loots it to us. Either way
-- OUR window stays the visible loot window: the item leaves the corpse
-- and our row drops (RemoveItem), never Blizzard's frame popping back.
-- Three outcomes: true = loot call ISSUED (slot resolved + API present);
-- "noslot" = no corpse slot/API involved (sim rows, /rf rolls, headless
-- award tests) — the caller proceeds without corpse interaction; false =
-- REFUSED (master-loot non-candidate) — the caller aborts and keeps row.
-- The row leaves the list only on LOOT_SLOT_CLEARED for that slot — never
-- optimistically here — so a failed LootSlot (locked, full bags, range)
-- leaves the row up for retry.
function M.LootCorpseSlot(link, itemID, winnerName, slotHint)
  -- Session gate FIRST: no open loot session (walked away, corpse closed)
  -- means no call can possibly land. Report "nolooot" so the caller logs
  -- + keeps the list intact — never touch VerifySlot/rescan, which would
  -- read an empty corpse and wipe every row.
  if not M.lootOpen then return "nolooot" end
  -- LIVE-resolve the slot at call time: stored slot numbers go stale the
  -- moment anything shifts the corpse (earlier loot, page change), and a
  -- stale LootSlot() is a silent server-side no-op — exactly the reported
  -- "gray [done], nothing looted, no error" ghost. When the hinted slot
  -- no longer holds THIS item, re-scan the corpse for it; when the item
  -- is gone entirely, report "gone" (caller leaves the row for rescan).
  -- Range gate SECOND: a moved-away player must never issue the call —
  -- report "norange" so the caller logs + keeps the list intact.
  if M.CheckLootRange() == "norange" then return "norange" end
  local slot = M.VerifySlot(itemID, slotHint)
  if slot == "gone" then return "gone" end
  if not slot then return "noslot" end
  local me = nil
  if UnitName then local ok, nm = pcall(UnitName, "player") if ok then me = nm end end
  local method = nil
  if GetLootMethod then local ok, m = pcall(GetLootMethod) if ok then method = m end end
  if method == nil and Z.SRSecurity and Z.SRSecurity.LootMethod then
    local ok, m = pcall(Z.SRSecurity.LootMethod) if ok then method = m end
  end
  -- BoP items need a second call: LootSlot raises the LOOT_BIND_CONFIRM
  -- popup, ConfirmLootSlot(slot) takes it. Without it BoP loot sits on
  -- the corpse forever. The confirm lands in OnEvent (Core routes
  -- LOOT_BIND_CONFIRM) and confirms every armed pending slot.
  -- SuperWoW hook (Turtle client): LootSlot takes an optional second arg
  -- (force). A plain LootSlot(slot) from script context is silently
  -- dropped by this client — verified live: direct call, correct slot,
  -- freeforall, no error, no loot. RollFor documents the same class of
  -- limitation for coins. Pass force=1 (verified strings: SuperWoWhook
  -- exports "LootSlot(slot [, force])"). pcall-guarded: a stock 1.12
  -- client ignores extra C-API args, so this stays compatible.
  local function superLoot(s)
    if LootSlot then return pcall(LootSlot, s, 1) end
  end
  local function callLoot()
    if method == "master" and me and winnerName and winnerName ~= me then
      -- Master loot hands the corpse item to ANOTHER player by candidate
      -- index (RollFor parity: GetMasterLootCandidate(slot, i) -> index).
      -- Vanilla quirk: one-arg GetMasterLootCandidate(i) ignores the slot.
      local idx = M.MasterLootIndex(slot, winnerName)
      if not idx then
        Z.Print("Can't award " .. tostring(winnerName) .. ": not a loot candidate.")
        return false
      end
      if GiveMasterLoot then return pcall(GiveMasterLoot, slot, idx) end
      return "noslot"
    end
    if LootSlot then return superLoot(slot) end
    return "noslot"
  end
  local okCall, errCall = callLoot()
  if okCall == "noslot" then return "noslot" end
  if not okCall then
    -- The pcall itself blew up (bad slot, tainted call): NEVER dim the
    -- row — surface the error so a dead loot call can't masquerade as
    -- "done" (the reported ghost: gray row, nothing looted).
    Z.Print("Loot failed (slot " .. tostring(slot) .. "): " .. tostring(errCall))
    return false
  end
  -- Armed, not done: the row drops when LOOT_SLOT_CLEARED confirms the
  -- slot left the corpse (post-confirm rescan prunes anything stale).
  if Z.LootWindow and Z.LootWindow.Find then
    local row = Z.LootWindow.Find(itemID)
    if row and (slotHint == nil or row.slot == slot) then
      M.pendingLoot = M.pendingLoot or {}
      M.pendingLoot[slot] = row
    end
  end
  return true
end

-- Corpse identity, strongest key first:
-- 1. Creature GUID via UnitExists("target") -> (exists, guid). This
--    client (Nampower/SuperWoW hooks) extends UnitExists with a second
--    GUID return (DoiteAuras/Luna/Aegis_SBR/MageTools all rely on it),
--    and GUIDs double as unit tokens. A GUID pins the UNIQUE corpse —
--    two same-named Plainstriders never share a window. Nil-safe: the
--    stock 1.12 UnitExists returns only exists (no guid), and headless
--    tests may define neither.
-- 2. Fallback: loot-target name + loot fingerprint (sorted itemIDs +
--    coin flag). Same corpse re-looted after walking back still matches;
--    same-named/same-loot twins may share (rescan reconciles correctly).
-- Pure helper for tests: pass guid, name + id list.
function M.TargetGUID()
  if not UnitExists then return nil end
  local ok, exists, guid = pcall(UnitExists, "target")
  if ok and exists and guid and guid ~= "" then return guid end
  return nil
end

function M.CorpseKey(targetGUID, targetName, itemIDs, hasCoin)
  if targetGUID and targetGUID ~= "" then
    return "guid:" .. tostring(targetGUID)
  end
  local ids = {}
  for i = 1, Z.Util.ArrayCount(itemIDs) do
    table.insert(ids, tostring(itemIDs[i]))
  end
  table.sort(ids)
  return "fp:" .. tostring(targetName or "?") .. "|" .. table.concat(ids, ",")
    .. (hasCoin and "|+coin" or "")
end

function M.LiveCorpseKey()
  local guid = M.TargetGUID()
  local target = nil
  if UnitName then
    local ok, nm = pcall(UnitName, "target")
    if ok then target = nm end
  end
  local ids, coin = {}, false
  if GetNumLootItems and GetLootSlotLink then
    local n = GetNumLootItems() or 0
    for s = 1, n do
      if Z.LootWindow and Z.LootWindow.IsCoinSlot
          and Z.LootWindow.IsCoinSlot(s) then
        coin = true
      else
        local ok, l = pcall(GetLootSlotLink, s)
        if ok and l then
          local id = Z.Util.ItemID(l)
          if id then table.insert(ids, id) end
        end
      end
    end
  end
  return M.CorpseKey(guid, target, ids, coin)
end

-- Range gate: block a loot attempt when the player has moved away from
-- the looted corpse. 1.12 has no movement event, so the signal is
-- CheckInteractDistance("target", 1) (loot range) against the corpse
-- pinned at scan time — by GUID when available (unique corpse), else by
-- target name. Same corpse + out of range = moved away: block early
-- ("norange"), list untouched, caller logs. Anything unverifiable (no
-- live corpse, target changed/cleared, GUID-less different corpse with
-- the same name) allows the attempt — the server has the final say.
-- Only live corpse loot is gated (GetNumLootItems() > 0); sim/award
-- bookkeeping never is.
function M.CheckLootRange()
  if not (GetNumLootItems and (GetNumLootItems() or 0) > 0) then
    return true
  end
  if not (CheckInteractDistance and UnitName) then return true end
  local pinnedGUID, pinnedName = M.lootGUID, M.lootTarget
  if not (pinnedGUID or pinnedName) then return true end
  local guid = M.TargetGUID()
  if pinnedGUID then
    -- GUID-pinned: a different GUID (or none) is a different corpse —
    -- allow, the key check owns identity. Same GUID + out of range =
    -- moved away from THIS corpse: block.
    if not guid or guid ~= pinnedGUID then return true end
  else
    local okCur, cur = pcall(UnitName, "target")
    if not okCur or cur ~= pinnedName then return true end
  end
  local okR, inRange = pcall(CheckInteractDistance, "target", 1)
  if okR and not inRange then return "norange" end
  return true
end

-- Verify a stored slot still holds the expected item, live from the
-- corpse. Returns the (possibly re-resolved) slot number, "gone" when
-- the item is nowhere on the corpse, or nil when the corpse can't be
-- read at all. Coin rows (itemID "Coin") verify via IsCoinSlot since
-- they carry no link.
function M.VerifySlot(itemID, slotHint)
  if not (GetNumLootItems and GetLootSlotLink) then
    if slotHint then return slotHint end
    return nil
  end
  local n = GetNumLootItems() or 0
  local function slotHolds(s)
    if itemID == "Coin" then
      return Z.LootWindow and Z.LootWindow.IsCoinSlot
        and Z.LootWindow.IsCoinSlot(s)
    end
    local ok, l = pcall(GetLootSlotLink, s)
    return ok and l and Z.Util.ItemID(l) == itemID
  end
  if slotHint and slotHint >= 1 and slotHint <= n and slotHolds(slotHint) then
    return slotHint -- still valid: cheapest path, no scan
  end
  for s = 1, n do
    if s ~= slotHint and slotHolds(s) then return s end -- shifted: re-resolve
  end
  if slotHint then return "gone" end -- was tracked, now absent
  return nil
end

-- Click confirmations in flight: [slot] = row, armed by LootCorpseSlot,
-- cleared by the LOOT_SLOT_CLEARED confirmation (same slot) or the LOOT
-- re-scan (slot gone = looted elsewhere / corpse closed). Rows leave the
-- list ONLY through confirmation — never optimistically at click time.
M.pendingLoot = nil

-- Candidate index of a player for one corpse slot (nil when absent).
-- RollFor parity: vanilla 1.12 takes ONE arg (index); backports/retail
-- take (slot, index). One-arg first — a two-arg call on vanilla would
-- silently misread (extra C-API args ignored, slot mistaken for index).
-- GetMasterLootCandidate errors with no candidate list (solo /
-- non-master methods) — pcall-guarded, never raises.
function M.MasterLootIndex(slot, playerName)
  if not GetMasterLootCandidate or not playerName then return nil end
  for i = 1, 40 do
    local ok, nm = pcall(GetMasterLootCandidate, i)
    if ok and nm ~= nil and nm ~= "" then
      if nm == playerName then return i end
    else
      local ok2, nm2 = pcall(GetMasterLootCandidate, slot, i)
      if ok2 and nm2 ~= nil and nm2 ~= "" then
        if nm2 == playerName then return i end
      else
        break -- end of the candidate list (either form)
      end
    end
  end
  return nil
end

-- Direct award from the loot-window row detail: no roll, straight to the
-- single SR/HR holder (RollFor: one SR = direct award, no rolling needed).
-- source mirrors DoAward ("raid" live, "sim" for sim rows).
function M.AwardDirect(itemID, winnerName, source)
  if not M.RequireML() then return end
  local link = "item:" .. tostring(itemID)
  if Z.LootWindow then
    local it = Z.LootWindow.Find(itemID)
    if it and it.link then link = it.link end
  end
  -- Live distribution of a CORPSE row needs the corpse OPEN (master-loot
  -- handoff moves a corpse slot; walked-away corpse = nothing to hand).
  -- Block early with a log, keep row + menu — the ML re-loots and awards
  -- from the still-open window. Non-row awards (/rf rolls, sim, headless)
  -- have no corpse slot: always apply.
  if source ~= "sim" and not M.lootOpen
      and Z.LootWindow and Z.LootWindow.Find(itemID) then
    Z.Print("Not awarding " .. tostring(winnerName)
      .. ": no loot open. Loot the corpse again, then award.")
    return false
  end
  -- Loot the corpse slot FIRST (the only path that moves the item): a
  -- refused loot call (non-candidate, unresolvable slot) aborts the award
  -- and keeps the row. Sim rows have no slot: skip straight to DoAward.
  if source ~= "sim" then
    if M.LootCorpseSlot(link, itemID, winnerName) == false then return false end
  end
  M.DoAward(itemID, link, winnerName, source == "sim" and "sim" or "raid")
  -- Handed out = gone: the row leaves the list (live loot too, like the
  -- corpse running dry). Stays gone until the next LOOT_OPENED / simboss.
  if Z.LootWindow and Z.LootWindow.RemoveItem then Z.LootWindow.RemoveItem(itemID) end
  -- A directly-awarded sim row leaves the roll queue as well: it must not
  -- be rollable after being handed out. Same for a pre-roll rehearsal
  -- award (entry dropped, continuation advances the run).
  if Z.Sim and Z.Sim.DropRehearsal and Z.Sim.DropRehearsal(itemID) then
    if Z.Sim.Rehearsing and Z.Sim.Rehearsing()
        and Z.Sim.afterRehearsal then
      Z.Sim.afterRehearsal()
    end
  end
  if source == "sim" and Z.Sim then
    if Z.Sim.pending then
      for i = Z.Util.ArrayCount(Z.Sim.pending), 1, -1 do
        if Z.Sim.pending[i] and Z.Sim.pending[i].itemID == itemID then
          table.remove(Z.Sim.pending, i)
        end
      end
    end
    if Z.Sim.OnSimAwarded then Z.Sim.OnSimAwarded(itemID) end
    if Z.Sim.SyncLootWindow then Z.Sim.SyncLootWindow() end
  end
end

-- Award core: marks won, broadcasts, logs, prints. No UI.
-- Data stays raw everywhere (sheet, addon messages, history); the local
-- confirmation print colors the winner for the ML's own chat frame.
function M.DoAward(itemID, itemLink, winnerName, source)
  if not Z.DB.sheet then Z.DB.sheet = Z.SRData.NewSheet() end
  source = source or "raid"
  Z.SRData.MarkWon(Z.DB.sheet, itemID, winnerName)
  if Z.Comm then Z.Comm.BroadcastAward(itemID, winnerName) end
  if Z.DropLog then Z.DropLog.Add(itemID, itemLink, source, "award", winnerName) end
  local disp = tostring(itemLink)
  if M.DisplayItemLink then disp = M.DisplayItemLink(itemID, itemLink) end
  Z.Print("Awarded " .. disp .. " to " .. PName(winnerName))
  if Z.SRView then Z.SRView.Refresh() end
end

-- Sim award flow: the ML picks one row of the award menu for each winner
-- slot. Headless (tests): the menu stays pending and the harness plays
-- the ML via AwardChosen. A no-winner finish is NOT auto-closed: the ML
-- awards the item to anyone (or re-rolls); the row stays until awarded.
M.pendingAwardMenu = nil -- legacy alias: active item's { sess, data }
M.pendingAwardMenus = nil -- per-item { [itemID] = { sess, data } } while the ML decides

function M.HandleSimAward(sess, data)
  M.pendingAwardMenus = M.pendingAwardMenus or {}
  local sk = sess.key or M.RollKey(sess.itemID)
  M.pendingAwardMenus[sk] = { sess = sess, data = data }
  M.pendingAwardMenu = M.pendingAwardMenus[sk]
  local winners = data.winners or {}
  if Z.Util.ArrayCount(winners) == 0 then
    -- Nobody eligible: the item stays open for the ML to award anyone
    -- or re-roll (/zl cr). Session stays parked on the award menu.
    return
  end
  if not (StaticPopupDialogs and StaticPopup_Show) then
    -- Headless (tests): the menu stays pending and the harness plays the
    -- ML via AwardChosen — same decision point as the client, minus the
    -- frame.
    return
  end
  -- In-client sim: show the real menu like a live roll.
  M.ShowAwardMenu(sess, data)
end

-- The ML chose a recipient for the finished roll (kind-winner row,
-- candidate grid, or ... selection). Confirms via popup, then awards.
-- Works for live and sim; sim continuation runs through Sim.afterAwards.
-- choice = { name=recipient, via="winner"|"menu"|"candidate"|"tmog",
--            rollType=optional }
function M.AwardChosen(choice, itemID)
  -- Award target: explicit itemID first (slash + preaward rows), else the
  -- OPEN item's menu (the ML decides on screen), else the legacy alias.
  local pend = nil
  local openID = Z.LootWindow and Z.LootWindow.detail
    and Z.LootWindow.detail.itemID or nil
  if M.pendingAwardMenus then
    if itemID and M.pendingAwardMenus[M.RollKey(itemID)] then
      pend = M.pendingAwardMenus[M.RollKey(itemID)]
    elseif openID and M.pendingAwardMenus[M.RollKey(openID)] then
      pend = M.pendingAwardMenus[M.RollKey(openID)]
    end
  end
  if not pend and itemID and M.session and M.session.itemID == itemID then
    pend = { sess = M.session, data = M.BuildAwardMenu(M.session,
      Z.Resolver.ResolveItem(Z.DB.sheet or { items = {}, won = {} },
        M.session.itemID, M.session.rolls,
        { cap = Z.Caps.SR, requireSR = true, itemCount = M.session.itemCount })) }
  end
  if not pend then pend = M.pendingAwardMenu end
  if not pend then
    -- Live path: no pending menu object, award the current session's item.
    local sess = M.session
    if not sess then Z.Print("No active session.") return end
    pend = { sess = sess, data = M.BuildAwardMenu(sess,
      Z.Resolver.ResolveItem(Z.DB.sheet or { items = {}, won = {} },
        sess.itemID, sess.rolls, { cap = Z.Caps.SR, requireSR = true, itemCount = sess.itemCount })) }
  end
  local sess, data = pend.sess, pend.data
  if Z.Sim then Z.Sim.pendingAward = nil end
  local name = choice and choice.name
  if not name then Z.Print("Pick a recipient first.") return end
  -- Award applied (popup accepted or headless): a finished detail closes,
  -- the row shows done on the overview.
  local function closeFinishedDetail()
    if Z.LootWindow and Z.LootWindow.detail
        and Z.LootWindow.detail.itemID == sess.itemID
        and (Z.LootWindow.detail.phase or "pick") == "award" then
      Z.LootWindow.CloseDetail()
    end
  end
  local link = sess.itemLink
  -- Rehearsal awards are REAL live awards (corpse take, "raid" source)
  -- even though the session runs silent: the item must actually leave
  -- the solo corpse. Only the continuation differs (rehearsal queue).
  local source = (sess.rehearse and "raid")
    or (sess.silent and "sim" or "raid")
  showAwardPopup(link, name, function()
    -- Live distribution of a corpse row needs the corpse OPEN; a refused
    -- call aborts and keeps row + menu. Non-row awards always apply.
    if source ~= "sim" and not M.lootOpen
        and Z.LootWindow and Z.LootWindow.Find(sess.itemID) then
      Z.Print("Not awarding " .. tostring(name)
        .. ": no loot open. Loot the corpse again, then award.")
      return
    end
    if source ~= "sim" and M.LootCorpseSlot(link, sess.itemID, name) == false then return end
    M.DoAward(sess.itemID, link, name, source)
    closeFinishedDetail()
    if Z.LootWindow and Z.LootWindow.RemoveItem then
      Z.LootWindow.RemoveItem(sess.itemID)
    end
    local ak = sess.key or M.RollKey(sess.itemID)
    if M.pendingAwardMenus then M.pendingAwardMenus[ak] = nil end
    M.pendingAwardMenu = nil
    if M.pendingAwardMenus then
      for _, other in pairs(M.pendingAwardMenus) do
        if other then M.pendingAwardMenu = other break end
      end
    end
    M.DropSession(sess)
    if sess.rehearse then
      -- Rehearsal award: normal live award above, then next queued item.
      if Z.Sim and Z.Sim.OnSimAwarded then Z.Sim.OnSimAwarded(sess.itemID) end
      if Z.Sim and Z.Sim.afterRehearsal then Z.Sim.afterRehearsal() end
    elseif sess.silent then
      -- Awarded = done: only now does the row leave the rolling state.
      if Z.Sim and Z.Sim.OnSimAwarded then Z.Sim.OnSimAwarded(sess.itemID) end
      if Z.Sim and Z.Sim.afterAwards then Z.Sim.afterAwards() end
    elseif Z.RaiderLootUI and Z.RaiderLootUI.Hide then
      Z.RaiderLootUI.Hide()
      -- Manual roll+award during an active rehearsal run: keep the queue
      -- moving instead of stalling on entries whose rows just left.
      if Z.Sim and Z.Sim.Rehearsing and Z.Sim.Rehearsing() then
        if Z.Sim.afterRehearsal then Z.Sim.afterRehearsal() end
      end
    end
  end)
  -- Headless (tests): no popup API — the award above already applied via
  -- DoAward inside... only when the popup fires. Without a client there is
  -- no OnAccept, so apply directly.
  if not (StaticPopupDialogs and StaticPopup_Show) then
    if source ~= "sim" and not M.lootOpen
        and Z.LootWindow and Z.LootWindow.Find(sess.itemID) then
      Z.Print("Not awarding " .. tostring(name)
        .. ": no loot open. Loot the corpse again, then award.")
      return
    end
    if source ~= "sim" and M.LootCorpseSlot(link, sess.itemID, name) == false then return end
    M.DoAward(sess.itemID, link, name, source)
    closeFinishedDetail()
    if Z.LootWindow and Z.LootWindow.RemoveItem then
      Z.LootWindow.RemoveItem(sess.itemID)
    end
    local ak = sess.key or M.RollKey(sess.itemID)
    if M.pendingAwardMenus then M.pendingAwardMenus[ak] = nil end
    M.pendingAwardMenu = nil
    if M.pendingAwardMenus then
      for _, other in pairs(M.pendingAwardMenus) do
        if other then M.pendingAwardMenu = other break end
      end
    end
    M.DropSession(sess)
    if sess.rehearse then
      if Z.Sim and Z.Sim.OnSimAwarded then Z.Sim.OnSimAwarded(sess.itemID) end
      if Z.Sim and Z.Sim.afterRehearsal then Z.Sim.afterRehearsal() end
    elseif sess.silent then
      -- Awarded = done: only now does the row leave the rolling state.
      if Z.Sim and Z.Sim.OnSimAwarded then Z.Sim.OnSimAwarded(sess.itemID) end
      if Z.Sim and Z.Sim.afterAwards then Z.Sim.afterAwards() end
    end
  end
end

-- Legacy entry point (pre-menu auto-award). Kept for compatibility:
-- routes through the menu choice so the ML still confirms.
function M.Award(itemID, itemLink, winnerEntry)
  local sess = M.SessionFor(itemID) or M.session
  if sess and sess.itemID == itemID then
    local akey = sess.key or M.RollKey(itemID)
    local menu = { sess = sess, data = M.BuildAwardMenu(sess,
      Z.Resolver.ResolveItem(Z.DB.sheet or { items = {}, won = {} },
        sess.itemID, sess.rolls, { cap = Z.Caps.SR, requireSR = true, itemCount = sess.itemCount })) }
    M.pendingAwardMenus = M.pendingAwardMenus or {}
    M.pendingAwardMenus[akey] = menu
    M.pendingAwardMenu = menu
  else
    local menu = { sess = { itemID = itemID, itemLink = itemLink, id = 0, silent = false, itemCount = 1 },
      data = { winners = {}, groups = { SR = {}, MS = {}, OS = {}, TMOG = {} },
        candidates = {}, perType = {}, none = false, itemID = itemID, itemLink = itemLink } }
    M.pendingAwardMenus = M.pendingAwardMenus or {}
    M.pendingAwardMenus[M.RollKey(itemID)] = menu
    M.pendingAwardMenu = M.pendingAwardMenus[M.RollKey(itemID)]
  end
  M.AwardChosen({ name = winnerEntry.name, via = "winner" }, itemID)
end

-- Universal loot scan: whoever opens a corpse runs the window — solo,
-- party/raid, any loot method. EVERY corpse slot gets a row (RollFor
-- parity): coin first, then roll-worthy items (quality >= threshold, SR/HR
-- badge, announce + log `loot`/`seen`), then below-threshold leftovers as
-- one-click free rows. No Blizzard fallback — our window IS the loot UI.
-- Further items go through /rf (or the sim loot window in sim).
-- Scan one corpse slot into a row entry (nil when the slot is empty or
-- unreadable). Coin slots carry no link: { itemID="Coin" }.
-- threshold: OUR roll-row cutoff (DB minLootQuality, default rare+).
-- groupThresh: the PARTY's Need/Greed cutoff (GetLootThreshold, default
-- uncommon) — items below it never enter a group roll.
-- Row kinds: coin (always click-loot) | roll (>= threshold: SR detail) |
-- group (group-loot item at/above groupThresh but BELOW our threshold:
-- Blizzard's Need/Greed frames own it — we list it but never loot it) |
-- free (everything else: one click loots, no rolling).
function M.ScanSlot(slot, threshold, groupThresh)
  if not GetNumLootItems then return nil end
  -- Coin first: no link, texture + amount text from the slot info.
  -- Zero-copper corpses still carry an (empty) coin slot client-side —
  -- skip it so wolves etc. don't grow a phantom "0 Copper" row.
  -- Texture fallback chain: slot texture, then the stock gold-coin icon
  -- (never the "?" placeholder — coin always has art on 1.12).
  if Z.LootWindow and Z.LootWindow.IsCoinSlot
      and Z.LootWindow.IsCoinSlot(slot) then
    local tex, slotName = nil, nil
    if GetLootSlotInfo then
      local a, b = GetLootSlotInfo(slot)
      if type(a) == "string" then tex = a end
      if type(b) == "string" then slotName = b end
    end
    if Z.LootWindow.IsEmptyCoin and Z.LootWindow.IsEmptyCoin(slotName) then
      return nil
    end
    tex = tex or "Interface\\Icons\\INV_Misc_Coin_01"
    return { itemID = "Coin", link = nil, quality = 0,
      texture = tex, quantity = nil, slot = slot,
      name = slotName or "Coin", coin = true }
  end
  if not GetLootSlotLink then return nil end
  local link = GetLootSlotLink(slot)
  if not link then return nil end
  -- RollFor reads everything off the slot: GetLootSlotInfo gives
  -- texture + quantity in one call, GetItemInfo gives quality.
  -- Quality prefers the SLOT's 4th return (always present client-side)
  -- over the item cache (uncached GetItemInfo lies 0 and would
  -- misclassify an epic as free loot).
  local tex, qty, slotName, slotQ = nil, nil, nil, nil
  if GetLootSlotInfo then
    -- Vanilla: (texture, name, quantity, quality); retail adds args.
    local a, b, c, d = GetLootSlotInfo(slot)
    tex, slotName, qty = a, b, c
    if type(qty) ~= "number" then qty = nil end
    if type(tex) ~= "string" then tex = nil end
    if type(d) == "number" then slotQ = d end
  end
  local q = slotQ
  if q == nil and GetItemInfo then
    local _, _, qq = GetItemInfo(link)
    q = qq
  end
  q = q or 0
  local entry = { link = link, quality = q,
    texture = tex, quantity = qty, slot = slot, name = slotName }
  entry.itemID = Z.Util.ItemID(link)
  if q >= (threshold or 3) then
    return entry -- roll row (badge added below)
  end
  if Z.LootWindow and Z.LootWindow.IsGroupRollItem
      and Z.LootWindow.IsGroupRollItem(q) then
    entry.group = true -- Blizzard's Need/Greed owns it: list, don't touch
    return entry
  end
  entry.free = true -- leftover: one click loots, no rolling
  return entry
end

-- Re-scan the corpse and patch the TRACKED rows (LOOT_SLOT_CLEARED /
-- Close path): drop rows whose slots went empty, keep badge/status of the
-- rest, append genuinely new slots. M.items here is the LootWindow list
-- (MasterLootUI owns no row list of its own). Returns the live row count.
-- Nil-safe headless.
-- Open-session flag: true between LOOT_OPENED and LOOT_CLOSED. A rescan
-- with no open session must keep every row — GetNumLootItems reads empty
-- with no session, which otherwise looks exactly like "all looted" and
-- wipes the window (the reported walk-away wipe).
M.lootOpen = false
function M.RescanLeftovers()
  local rows = (Z.LootWindow and Z.LootWindow.items) or M.items
  if not GetNumLootItems then return Z.Util.ArrayCount(rows) end
  if not M.lootOpen then return Z.Util.ArrayCount(rows) end
  local threshold = (Z.DB and Z.DB.minLootQuality) or 3
  local n = GetNumLootItems()
  -- Slot NUMBERS shift when a slot is looted (old slot 2 becomes slot 1),
  -- so reconciliation matches by identity multiset, not slot index:
  -- corpse entries { key, entry } in slot order; each tracked row consumes
  -- one equal-key corpse entry. Rows with no match left the corpse.
  -- key: "coin" | "id:<itemID>" (free rows included — a grey is a grey).
  local corpse = {}
  for slot = 1, n do
    local e = M.ScanSlot(slot, threshold)
    if e then
      local key = e.coin and "coin"
        or ((e.group and "group:") or "id:") .. tostring(e.itemID)
      table.insert(corpse, { key = key, entry = e })
    end
  end
  local function rowKey(it)
    if not it then return nil end
    if it.coin then return "coin" end
    return ((it.group and "group:") or "id:") .. tostring(it.itemID)
  end
  -- First pass: match armed click-to-loot rows. An armed row WITH a corpse
  -- match is a failed LootSlot (locked, full bags, range): keep the row
  -- (retryable), un-dim it. An armed row with NO match is a confirmed
  -- loot: drop it. Arms always clear — and a confirm also clears the
  -- kill-switch watch for that slot (a working path must never trip it).
  local armed = {}
  if M.pendingLoot then
    for slot in pairs(M.pendingLoot) do armed[slot] = true end
    M.pendingLoot = nil
  end
  local function clearSilentWatch(slot, itemID)
    local W = Z.LootWindow and Z.LootWindow.silentLootArms
    if not W then return end
    for i = Z.Util.ArrayCount(W), 1, -1 do
      local a = W[i]
      if a and (slot == nil or a.slot == slot)
          and (itemID == nil or a.itemID == itemID) then
        table.remove(W, i)
      end
    end
  end
  local corpseUsed = {}
  local keepRow = {}
  for i = 1, Z.Util.ArrayCount(rows) do
    local it = rows[i]
    local matched = nil
    if it then
      for c = 1, Z.Util.ArrayCount(corpse) do
        if not corpseUsed[c] and corpse[c].key == rowKey(it) then
          matched = c break
        end
      end
    end
    if matched then
      corpseUsed[matched] = true
      keepRow[i] = true
      -- Refresh the slot number: slots shift after each loot.
      rows[i].slot = corpse[matched].entry.slot
      -- Armed + still present = FAILED call (server answered by keeping
      -- the slot), never silent: clear its kill-switch watch. A retry is
      -- a fresh first arm, not a second silent strike.
      if armed[rows[i].slot] or (it and armed[it.slot]) then
        clearSilentWatch(nil, it and it.itemID)
      end
    elseif it and armed[it.slot] then
      keepRow[i] = false -- confirmed click: row leaves
      clearSilentWatch(it.slot, it.itemID) -- working path: never trip switch
      if Z.LootWindow and Z.LootWindow.DropParked then
        Z.LootWindow.DropParked(it.itemID)
      end
    elseif it then
      keepRow[i] = false -- looted outside our rows: row leaves
    else
      keepRow[i] = false
    end
  end
  local fresh = {}
  for c = 1, Z.Util.ArrayCount(corpse) do
    if not corpseUsed[c] then table.insert(fresh, corpse[c].entry) end
  end
  for i = Z.Util.ArrayCount(rows), 1, -1 do
    if not keepRow[i] then table.remove(rows, i) end
  end
  -- Failed clicks (armed but still on the corpse) return to open state.
  for i = 1, Z.Util.ArrayCount(rows) do
    local it = rows[i]
    if it and it.status == "done" then it.status = "open" end
  end
  -- Badge + append genuinely new slots (same shaping as OnLootOpened).
  for i = 1, Z.Util.ArrayCount(fresh) do
    local e = fresh[i]
    local badge = ""
    if not e.coin and not e.free and not e.group and e.itemID
        and Z.DB and Z.DB.sheet and Z.SRData.ReserveBadge then
      badge = Z.SRData.ReserveBadge(Z.DB.sheet, e.itemID)
    end
    e.badge = badge
    e.index = Z.Util.ArrayCount(rows) + 1
    e.status = "open"
    e.source = "loot"
    if Z.LootWindow and Z.LootWindow.EnsureResolved then
      Z.LootWindow.EnsureResolved(e)
    end
    table.insert(rows, e)
  end
  for i = 1, Z.Util.ArrayCount(rows) do rows[i].index = i end
  if Z.LootWindow and Z.LootWindow.Refresh then Z.LootWindow.Refresh() end
  return Z.Util.ArrayCount(rows)
end

-- Session-only corpse cache, keyed by corpse key (guid: preferred,
-- fp: fallback — see CorpseKey). NEVER persisted: plain module tables,
-- empty at load, no SavedVariables touch. Each entry owns EVERYTHING for
-- one not-fully-looted corpse so walk-away-and-back resumes exactly:
-- rows (with statuses), open detail, parked details, live sessions,
-- parked sessions, award menus, click arms. Corpse B looted mid-roll on
-- corpse A parks A intact; re-looting A restores it whole — a live roll
-- on A keeps collecting /roll chat while B is worked, and B's award
-- never touches A's state. Sim rows (source "sim", no corpse) live
-- outside the cache on the live tables as before.
-- Entry: { key, guid, target, rows, detail, parked,
--            sessions, sessionID, parkedSessions,
--            awardMenus, awardMenu, pendingLoot }
-- Bounded: abandoned corpses (parked, never re-looted) evict oldest-first
-- past M.CORPSE_CACHE_MAX. Session-only either way — never persisted.
M.CORPSE_CACHE_MAX = 5
M.corpseCache = {}
M.corpseOrder = {}
M.lootGUID = nil -- pinned corpse GUID (nil when client offers none)
M.lootTarget = nil -- pinned loot target name (fallback path)
M.lootKey = nil -- active corpse key (cache key while a corpse is open)
-- Stash the live tables into the active corpse's cache entry (deep
-- enough that later mutation can't alias: rows + detail + parked are
-- copied row-wise; sessions/menus are referenced — they are only ever
-- touched through their owning corpse while it is active).
local function snapshotRows(rows)
  local out = {}
  for i = 1, Z.Util.ArrayCount(rows) do
    local r = rows[i]
    if r then
      local c = {}
      for k, v in pairs(r) do c[k] = v end
      table.insert(out, c)
    end
  end
  return out
end
function M.ParkCorpse()
  local key = M.lootKey
  if not key then return end
  local W = Z.LootWindow
  M.corpseCache = M.corpseCache or {}
  M.corpseOrder = M.corpseOrder or {}
  for i = Z.Util.ArrayCount(M.corpseOrder), 1, -1 do
    if M.corpseOrder[i] == key then table.remove(M.corpseOrder, i) end
  end
  table.insert(M.corpseOrder, key)
  while Z.Util.ArrayCount(M.corpseOrder) > (M.CORPSE_CACHE_MAX or 5) do
    local oldest = table.remove(M.corpseOrder, 1)
    if oldest then M.corpseCache[oldest] = nil end
  end
  -- Shelve this corpse's unplayed rehearsal queue entries with it (the
  -- shared pending queue is ResetFresh-wiped on every new-corpse scan).
  -- LIVE entries (rolling now) stay put — they belong to the active flow.
  local rehearsePending = {}
  if Z.Sim and Z.Sim.pending then
    for i = Z.Util.ArrayCount(Z.Sim.pending), 1, -1 do
      local e = Z.Sim.pending[i]
      if e and e.rehearse and (e.corpse == nil or e.corpse == key) then
        table.insert(rehearsePending, table.remove(Z.Sim.pending, i))
      end
    end
  end
  M.corpseCache[key] = {
    key = key, guid = M.lootGUID, target = M.lootTarget,
    rows = W and snapshotRows(W.items) or {},
    detail = W and W.detail or nil,
    parked = W and W.parked or {},
    sessions = M.sessions or {},
    sessionID = M.session and M.session.id or nil,
    parkedSessions = M.parkedSessions,
    awardMenus = M.pendingAwardMenus,
    awardMenu = M.pendingAwardMenu,
    pendingLoot = M.pendingLoot,
    rehearsePending = rehearsePending,
  }
end
-- Restore a cached corpse onto the live tables. Sessions re-link by id;
-- parked details/menus resume untouched. Caller reconciles + shows.
-- TAKE semantics: the entry leaves the cache on restore (the live tables
-- own the state from here; walking away re-parks fresh). Stale copies
-- must never linger beside live state.
function M.RestoreCorpse(key)
  local e = M.corpseCache and M.corpseCache[key]
  if not e then return false end
  M.corpseCache[key] = nil
  if M.corpseOrder then
    for i = Z.Util.ArrayCount(M.corpseOrder), 1, -1 do
      if M.corpseOrder[i] == key then table.remove(M.corpseOrder, i) end
    end
  end
  -- Merge, not overwrite: live tables may have moved on after the park
  -- (e.g. a session finished + menu opened while walked away). Live-newer
  -- state wins per key; the park only fills gaps. Rows/detail take the
  -- park when the live window is empty, else stay (rescan reconciles).
  local W = Z.LootWindow
  if W then
    if Z.Util.ArrayCount(W.items) == 0 then
      W.items = snapshotRows(e.rows)
    end
    if not W.detail then W.detail = e.detail end
    W.parked = W.parked or {}
    for k, v in pairs(e.parked or {}) do
      if W.parked[k] == nil then W.parked[k] = v end
    end
  end
  M.sessions = M.sessions or {}
  for k, v in pairs(e.sessions or {}) do
    if M.sessions[k] == nil then M.sessions[k] = v end
  end
  if not M.session and e.sessionID then
    for _, s in pairs(M.sessions) do
      if s and s.id == e.sessionID then M.session = s break end
    end
  end
  if not M.session then
    for _, s in pairs(M.sessions) do
      if s then M.session = s break end
    end
  end
  M.parkedSessions = M.parkedSessions or {}
  for k, v in pairs(e.parkedSessions or {}) do
    if M.parkedSessions[k] == nil then M.parkedSessions[k] = v end
  end
  M.pendingAwardMenus = M.pendingAwardMenus or {}
  for k, v in pairs(e.awardMenus or {}) do
    if M.pendingAwardMenus[k] == nil then M.pendingAwardMenus[k] = v end
  end
  if not M.pendingAwardMenu then M.pendingAwardMenu = e.awardMenu end
  if not M.pendingLoot then M.pendingLoot = e.pendingLoot end
  -- Unshelve this corpse's rehearsal queue: re-add entries not already
  -- covered live (played on while parked, or re-queued by top-up).
  if Z.Sim and e.rehearsePending then
    for i = 1, Z.Util.ArrayCount(e.rehearsePending) do
      local qe = e.rehearsePending[i]
      if qe and not Z.Sim.RehearsalCovered(qe.itemID) then
        table.insert(Z.Sim.pending, qe)
      end
    end
  end
  M.lootGUID = e.guid
  M.lootTarget = e.target
  M.lootKey = e.key
  return true
end
-- Drop a corpse from the cache once fully looted (no rows left after a
-- reconcile, or Close with an empty list). Distributed corpses must not
-- linger — the cache is for NOT-fully-looted mobs only.
function M.ForgetCorpse(key)
  if M.corpseCache and key then M.corpseCache[key] = nil end
  if M.corpseOrder and key then
    for i = Z.Util.ArrayCount(M.corpseOrder), 1, -1 do
      if M.corpseOrder[i] == key then table.remove(M.corpseOrder, i) end
    end
  end
end
function M.OnLootOpened()
  if not GetNumLootItems then return end
  M.lootOpen = true -- session is definitionally open inside this handler
  local key = M.LiveCorpseKey()
  -- Cached corpse (walked away mid-roll/award, now back): restore it
  -- whole — rows, live roll, parked details, award menus — then
  -- reconcile against the live corpse. A different corpse parks the
  -- active one first (untouched), so multi-corpse interleaves keep
  -- every roll collecting independently.
  if key and M.corpseCache and M.corpseCache[key] then
    if M.lootKey and M.lootKey ~= key then M.ParkCorpse() end
    M.RestoreCorpse(key)
    M.RescanLeftovers()
    if Z.LootWindow then
      if Z.Util.ArrayCount(Z.LootWindow.items) == 0 then
        M.ForgetCorpse(key)
        if M.lootKey == key then
          M.lootKey, M.lootGUID, M.lootTarget = nil, nil, nil
        end
        Z.LootWindow.Hide()
      else
        Z.LootWindow.Show()
        Z.Print("Loot window resumed — rolls and award state kept.")
      end
    end
    return
  end
  -- New corpse while another is mid-roll: park the active one intact
  -- (its live roll keeps collecting chat), then build fresh below.
  if M.lootKey and M.lootKey ~= key then M.ParkCorpse() end
  local threshold = (Z.DB and Z.DB.minLootQuality) or 3
  local found, coin, free, grouped = {}, {}, {}, {}
  local n = GetNumLootItems()
  for slot = 1, n do
    local e = M.ScanSlot(slot, threshold)
    if e then
      if e.coin then table.insert(coin, e)
      elseif e.group then table.insert(grouped, e)
      elseif e.free then table.insert(free, e)
      else table.insert(found, e) end
    end
  end
  if Z.Util.ArrayCount(found) == 0
      and Z.Util.ArrayCount(coin) == 0
      and Z.Util.ArrayCount(free) == 0
      and Z.Util.ArrayCount(grouped) == 0 then
    return -- corpse unreadable/empty: nothing to cover, stay out of the way
  end
  -- Announce + log the ROLL rows only (coin/free loot needs no roll call).
  for i = 1, Z.Util.ArrayCount(found) do
    local f = found[i]
    Z.Comm.WarnGroup("ZugLoot loot: " .. f.link)
    if Z.DropLog then Z.DropLog.Add(Z.Util.ItemID(f.link), f.link, "loot", "seen", nil) end
  end
  -- Fresh loot session: a new corpse must not inherit rows, done marks,
  -- open detail, sim queue or raider rolls from a previous loot/sim.
  -- Guarded: ResetFresh must never abort the scan (its pieces are
  -- independently nil-safe, but a corpse with loot open takes priority).
  if Z.Sim and Z.Sim.ResetFresh then pcall(Z.Sim.ResetFresh) end
  -- Ours is the loot window now — UNLESS the kill-switch stood us down
  -- (persisted lootTakeover=false): then stay out of the way entirely so
  -- Blizzard's frame handles the corpse (no rows, no detach, no announce
  -- spam — the stock UI is the loot UI until the user re-arms).
  if Z.LootWindow and not Z.LootWindow.TakeoverWanted() then return end
  -- (Re-)detach Blizzard's frame — hiding once is not enough, FrameXML
  -- re-shows it on every loot — while our rows cover this corpse.
  -- Detach is idempotent (safe to repeat per loot).
  if Z.LootWindow and Z.LootWindow.DetachBlizzardLoot then
    pcall(Z.LootWindow.DetachBlizzardLoot)
  end
  -- Pin the corpse for the walk-away-and-back flow (GUID > name +
  -- fingerprint). GUID survives re-targeting; name does not.
  M.lootGUID = M.TargetGUID()
  if UnitName then
    local ok, nm = pcall(UnitName, "target")
    M.lootTarget = (ok and nm) or nil
  else
    M.lootTarget = nil
  end
  M.lootKey = M.LiveCorpseKey()
  -- RollFor-style loot window: coin first, roll rows next, group-roll
  -- items (Blizzard's Need/Greed owns those) after, free leftovers last.
  -- The ML works each roll row from the list; coin/free rows loot on
  -- click; group rows are display-only until Blizzard's roll resolves.
  if Z.LootWindow then
    local rows = {}
    local function push(e, badge)
      table.insert(rows, { itemID = e.itemID, link = e.link,
        name = e.name, texture = e.texture,
        quality = e.quality, quantity = e.quantity,
        slot = e.slot, badge = badge or "", coin = e.coin,
        free = e.free, group = e.group })
    end
    for i = 1, Z.Util.ArrayCount(coin) do push(coin[i]) end
    for i = 1, Z.Util.ArrayCount(found) do
      local id = Z.Util.ItemID(found[i].link)
      local badge = ""
      if Z.DB and Z.DB.sheet and id and Z.SRData.ReserveBadge then
        badge = Z.SRData.ReserveBadge(Z.DB.sheet, id)
      end
      push(found[i], badge)
    end
    for i = 1, Z.Util.ArrayCount(grouped) do push(grouped[i], "ROLL") end
    for i = 1, Z.Util.ArrayCount(free) do push(free[i]) end
    Z.LootWindow.SetItems(rows, "loot")
    Z.LootWindow.Show("Boss loot")
  end
  Z.Print("Loot window open — click a row, then Award / ... / Close.")
  -- Solo rehearsal takeover: queue every non-coin row for the invented-
  -- roller pipeline and auto-play the head. No-ops unless the flag is on
  -- (StartRehearsal guards solo/idle/rows/sheet-module itself).
  if Z.Sim and Z.Sim.StartRehearsal then
    pcall(Z.Sim.StartRehearsal)
  end
end

function M.OnEvent(event, a1, a2)
  if event == "CHAT_MSG_SYSTEM" and M.session then
    -- "Name rolls 42 (1-100)"
    local player, roll, minR, maxR = string.match(tostring(a1 or ""), "(.+) rolls (%d+) %((%d+)%-(%d+)%)")
    if player then M.OnSystemRoll(player, tonumber(roll), tonumber(minR), tonumber(maxR)) end
  elseif event == "LOOT_OPENED" then
    M.lootOpen = true
    M.OnLootOpened()
  elseif event == "LOOT_CLOSED" then
    M.lootOpen = false
  elseif event == "LOOT_BIND_CONFIRM" then
    -- BoP take: confirm every armed click-to-loot slot. a1 is the slot
    -- on 1.12 (nil-safe: confirm all armed slots when it isn't).
    if ConfirmLootSlot then
      if type(a1) == "number" and M.pendingLoot and M.pendingLoot[a1] then
        pcall(ConfirmLootSlot, a1)
      elseif M.pendingLoot then
        for slot in pairs(M.pendingLoot) do pcall(ConfirmLootSlot, slot) end
      end
    end
  elseif event == "UI_ERROR_MESSAGE" then
    -- A dead loot call (locked, full bags, range, coin-in-master-mode)
    -- must NEVER strand a dimmed row: drop the arms AND un-dim every
    -- "done" row back to open immediately (don't wait for a rescan that
    -- may never come — no LOOT_SLOT_CLEARED fires on failure). The client
    -- already shows the error itself; stay quiet here. Also drops the
    -- kill-switch watch: a REFUSED call is answered (not silent), so it
    -- must never count toward the dead-path trip.
    M.pendingLoot = nil
    if Z.LootWindow then Z.LootWindow.silentLootArms = nil end
    if Z.LootWindow and Z.LootWindow.items then
      local touched = false
      for i = 1, Z.Util.ArrayCount(Z.LootWindow.items) do
        local it = Z.LootWindow.items[i]
        if it and it.status == "done" then it.status = "open" touched = true end
      end
      if touched and Z.LootWindow.Refresh then Z.LootWindow.Refresh() end
    end
  end
end
