-- ZugLoot/MasterLootUI.lua
-- RollFor-like master-looter console: loot list + session control + award confirm.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.MasterLootUI = M

-- Roll sessions, one per item: the ML works several items at once (roll A,
-- close, roll B, award B, reopen A off its saved rolls). Exactly one
-- session is ACTIVE (its item's rolls feed the session; chat/system rolls
-- land there). M.session stays as the active-session alias so every
-- existing reader keeps working; M.sessions holds the per-item rest.
M.session = nil -- active { id, itemID, itemLink, mode, rolls={}, t=0, itemCount=1 }
M.sessions = {} -- [itemID] = session (active one included)

local sessionSeq = 0

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
  local sess = { id = sessionSeq, itemID = itemID, itemLink = itemLink, mode = mode, rolls = {}, t = 0, itemCount = itemCount, silent = silent }
  M.sessions = M.sessions or {}
  M.sessions[itemID] = sess
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

-- Look up a roll session: this item's own session when it has one
-- (multi-roll: each item owns its rolls), else the active session.
function M.SessionFor(itemID)
  if itemID and M.sessions and M.sessions[itemID] then
    return M.sessions[itemID]
  end
  return M.session
end

-- Drop a session once its item is handed out. Active alias follows the
-- remaining sessions (or nil when none are left).
function M.DropSession(sess)
  if not sess then return end
  if M.parkedSessions and sess.itemID
      and M.parkedSessions[sess.itemID] == sess then
    M.parkedSessions[sess.itemID] = nil
  end
  if M.sessions and sess.itemID and M.sessions[sess.itemID] == sess then
    M.sessions[sess.itemID] = nil
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
  if M.sessions and M.sessions[itemID] then
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
  if not sess and itemID and M.sessions[itemID] then
    sess = M.sessions[itemID]
  end
  if not sess then return end
  M.ApplySystemRoll(sess, player, roll, minR, maxR)
end

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
  local sess = (itemID and M.sessions and M.sessions[itemID])
    or M.SessionFor(itemID) or M.session
  if not sess then Z.Print("No active session.") return end
  local wasSilent = sess.silent
  local itemID = sess.itemID
  local sessionID = sess.id
  if M.pendingAwardMenus then M.pendingAwardMenus[itemID] = nil end
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
  if wasSilent and Z.Sim and Z.Sim.Requeue then Z.Sim.Requeue(itemID) end
end

-- Park a finished-but-unawarded roll: the session leaves the live table
-- but keeps its rolls in M.parkedSessions; the award menu stays pending.
-- Continue re-attaches it so more rolls append to the SAME list.
M.parkedSessions = nil
function M.ParkSession(sess)
  if not sess then return end
  M.parkedSessions = M.parkedSessions or {}
  M.parkedSessions[sess.itemID] = sess
  if M.sessions and sess.itemID and M.sessions[sess.itemID] == sess then
    M.sessions[sess.itemID] = nil
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
  if M.sessions and M.sessions[itemID] then return M.sessions[itemID] end
  if M.parkedSessions and M.parkedSessions[itemID] then
    return M.parkedSessions[itemID]
  end
  return nil
end

-- Re-attach a parked session so a continued roll appends to the same list.
function M.UnparkSession(sess)
  if not sess then return end
  if M.parkedSessions and M.parkedSessions[sess.itemID] == sess then
    M.parkedSessions[sess.itemID] = nil
  end
  M.sessions = M.sessions or {}
  M.sessions[sess.itemID] = sess
  M.session = sess
end

-- A parked session by item (nil once awarded/cancelled).
function M.ParkedSession(itemID)
  if itemID and M.parkedSessions then return M.parkedSessions[itemID] end
  return nil
end

-- Returns "tie" (session left open for re-rolls), "awaiting" (sim awards
-- pending ML confirmation), or "closed". Live callers ignore the result.
-- Targets one item's session: no arg finishes the ACTIVE (open) item; pass
-- an itemID to finish a held roll. A clean finish PARKS the session (roll
-- ended, award pending): more rolls can't land on it, but Continue
-- re-attaches it explicitly.
function M.Finish(manual, itemID)
  local sess = (itemID and M.sessions and M.sessions[itemID])
    or M.SessionFor(itemID) or M.session
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
  M.pendingAwardMenus[sess.itemID] = { sess = sess, data = data }
  M.pendingAwardMenu = M.pendingAwardMenus[sess.itemID]
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
function M.LootCorpseSlot(link, itemID, winnerName, slotHint)
  local slot = slotHint or nil
  if not slot and Z.LootWindow then
    local it = Z.LootWindow.Find(itemID)
    if it and it.slot then slot = it.slot end
  end
  if not slot and GetNumLootItems and GetLootSlotLink then
    local n = GetNumLootItems() or 0
    for s = 1, n do
      local ok, l = pcall(GetLootSlotLink, s)
      if ok and l and Z.Util.ItemID(l) == itemID then slot = s break end
    end
  end
  if not slot then return end
  local me = nil
  if UnitName then local ok, nm = pcall(UnitName, "player") if ok then me = nm end end
  local method = nil
  if GetLootMethod then local ok, m = pcall(GetLootMethod) if ok then method = m end end
  if method == nil and Z.SRSecurity and Z.SRSecurity.LootMethod then
    local ok, m = pcall(Z.SRSecurity.LootMethod) if ok then method = m end
  end
  if method == "master" and me and winnerName and winnerName ~= me then
    if GiveMasterLoot then pcall(GiveMasterLoot, slot, winnerName) end
  else
    if LootSlot then pcall(LootSlot, slot) end
  end
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
  M.DoAward(itemID, link, winnerName, source == "sim" and "sim" or "raid")
  -- Loot the corpse slot through Blizzard's frame (the only path that
  -- moves the item), then drop our row. Sim rows have no slot: skip.
  if source ~= "sim" then M.LootCorpseSlot(link, itemID, winnerName) end
  -- Handed out = gone: the row leaves the list (live loot too, like the
  -- corpse running dry). Stays gone until the next LOOT_OPENED / simboss.
  if Z.LootWindow and Z.LootWindow.RemoveItem then Z.LootWindow.RemoveItem(itemID) end
  -- A directly-awarded sim row leaves the roll queue as well: it must not
  -- be rollable after being handed out.
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
  M.pendingAwardMenus[sess.itemID] = { sess = sess, data = data }
  M.pendingAwardMenu = M.pendingAwardMenus[sess.itemID]
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
    if itemID and M.pendingAwardMenus[itemID] then
      pend = M.pendingAwardMenus[itemID]
    elseif openID and M.pendingAwardMenus[openID] then
      pend = M.pendingAwardMenus[openID]
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
  local source = sess.silent and "sim" or "raid"
  showAwardPopup(link, name, function()
    M.DoAward(sess.itemID, link, name, source)
    closeFinishedDetail()
    if source ~= "sim" then M.LootCorpseSlot(link, sess.itemID, name) end
    if Z.LootWindow and Z.LootWindow.RemoveItem then
      Z.LootWindow.RemoveItem(sess.itemID)
    end
    if M.pendingAwardMenus then M.pendingAwardMenus[sess.itemID] = nil end
    M.pendingAwardMenu = nil
    M.DropSession(sess)
    if sess.silent then
      -- Awarded = done: only now does the row leave the rolling state.
      if Z.Sim and Z.Sim.OnSimAwarded then Z.Sim.OnSimAwarded(sess.itemID) end
      if Z.Sim and Z.Sim.afterAwards then Z.Sim.afterAwards() end
    elseif Z.RaiderLootUI and Z.RaiderLootUI.Hide then
      Z.RaiderLootUI.Hide()
    end
  end)
  -- Headless (tests): no popup API — the award above already applied via
  -- DoAward inside... only when the popup fires. Without a client there is
  -- no OnAccept, so apply directly.
  if not (StaticPopupDialogs and StaticPopup_Show) then
    M.DoAward(sess.itemID, link, name, source)
    closeFinishedDetail()
    if source ~= "sim" then M.LootCorpseSlot(link, sess.itemID, name) end
    if Z.LootWindow and Z.LootWindow.RemoveItem then
      Z.LootWindow.RemoveItem(sess.itemID)
    end
    if M.pendingAwardMenus then M.pendingAwardMenus[sess.itemID] = nil end
    M.pendingAwardMenu = nil
    M.DropSession(sess)
    if sess.silent then
      -- Awarded = done: only now does the row leave the rolling state.
      if Z.Sim and Z.Sim.OnSimAwarded then Z.Sim.OnSimAwarded(sess.itemID) end
      if Z.Sim and Z.Sim.afterAwards then Z.Sim.afterAwards() end
    end
  end
end

-- Legacy entry point (pre-menu auto-award). Kept for compatibility:
-- routes through the menu choice so the ML still confirms.
function M.Award(itemID, itemLink, winnerEntry)
  local sess = (M.sessions and M.sessions[itemID]) or M.session
  if sess and sess.itemID == itemID then
    local menu = { sess = sess, data = M.BuildAwardMenu(sess,
      Z.Resolver.ResolveItem(Z.DB.sheet or { items = {}, won = {} },
        sess.itemID, sess.rolls, { cap = Z.Caps.SR, requireSR = true, itemCount = sess.itemCount })) }
    M.pendingAwardMenus = M.pendingAwardMenus or {}
    M.pendingAwardMenus[itemID] = menu
    M.pendingAwardMenu = menu
  else
    local menu = { sess = { itemID = itemID, itemLink = itemLink, id = 0, silent = false, itemCount = 1 },
      data = { winners = {}, groups = { SR = {}, MS = {}, OS = {}, TMOG = {} },
        candidates = {}, perType = {}, none = false, itemID = itemID, itemLink = itemLink } }
    M.pendingAwardMenus = M.pendingAwardMenus or {}
    M.pendingAwardMenus[itemID] = menu
    M.pendingAwardMenu = menu
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
function M.ScanSlot(slot, threshold)
  if not GetNumLootItems then return nil end
  -- Coin first: no link, texture + amount text from the slot info.
  if Z.LootWindow and Z.LootWindow.IsCoinSlot
      and Z.LootWindow.IsCoinSlot(slot) then
    local tex, slotName = nil, nil
    if GetLootSlotInfo then
      local a, b = GetLootSlotInfo(slot)
      if type(a) == "string" then tex = a end
      if type(b) == "string" then slotName = b end
    end
    return { itemID = "Coin", link = nil, quality = 0,
      texture = tex, quantity = nil, slot = slot,
      name = slotName or "Coin", coin = true }
  end
  if not GetLootSlotLink then return nil end
  local link = GetLootSlotLink(slot)
  if not link then return nil end
  -- RollFor reads everything off the slot: GetLootSlotInfo gives
  -- texture + quantity in one call, GetItemInfo gives quality.
  local tex, qty, slotName = nil, nil, nil
  if GetLootSlotInfo then
    -- Vanilla: (texture, name, quantity, quality); retail adds args.
    local a, b, c, d = GetLootSlotInfo(slot)
    tex, slotName, qty = a, b, c
    if type(qty) ~= "number" then qty = nil end
    if type(tex) ~= "string" then tex = nil end
  end
  local q = nil
  if GetItemInfo then
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
  entry.free = true -- leftover: one click loots, no rolling
  return entry
end

-- Re-scan the corpse and patch the tracked rows (LOOT_SLOT_CLEARED path):
-- drop rows whose slots went empty, keep badge/status of the rest, append
-- genuinely new slots. Returns the live row count. Nil-safe headless.
function M.RescanLeftovers()
  if not GetNumLootItems then return Z.Util.ArrayCount(M.items) end
  local threshold = (Z.DB and Z.DB.minLootQuality) or 3
  local n = GetNumLootItems()
  -- Slot-keyed (duplicate itemIDs across slots are distinct rows).
  local seen = {}
  local fresh = {}
  for slot = 1, n do
    local e = M.ScanSlot(slot, threshold)
    if e then
      local key = "slot:" .. slot
      seen[key] = true
      local tracked = false
      if Z.LootWindow and Z.LootWindow.items then
        for j = 1, Z.Util.ArrayCount(Z.LootWindow.items) do
          if Z.LootWindow.items[j].slot == slot then tracked = true break end
        end
      end
      if not tracked then table.insert(fresh, e) end
    end
  end
  -- Drop rows whose slot went empty (looted outside our rows).
  for i = Z.Util.ArrayCount(M.items), 1, -1 do
    local it = M.items[i]
    if it then
      local key = "slot:" .. tostring(it.slot or -1)
      if not seen[key] then
        table.remove(M.items, i)
      end
    end
  end
  -- Badge + append genuinely new slots (same shaping as OnLootOpened).
  for i = 1, Z.Util.ArrayCount(fresh) do
    local e = fresh[i]
    local badge = ""
    if not e.coin and not e.free and e.itemID
        and Z.DB and Z.DB.sheet and Z.SRData.ReserveBadge then
      badge = Z.SRData.ReserveBadge(Z.DB.sheet, e.itemID)
    end
    e.badge = badge
    e.index = Z.Util.ArrayCount(M.items) + 1
    e.status = "open"
    e.source = "loot"
    if Z.LootWindow and Z.LootWindow.EnsureResolved then
      Z.LootWindow.EnsureResolved(e)
    end
    table.insert(M.items, e)
  end
  for i = 1, Z.Util.ArrayCount(M.items) do M.items[i].index = i end
  if Z.LootWindow and Z.LootWindow.Refresh then Z.LootWindow.Refresh() end
  return Z.Util.ArrayCount(M.items)
end

function M.OnLootOpened()
  if M.session then return end -- already rolling
  if M.pendingAwardMenu then return end -- still deciding the award
  if not GetNumLootItems then return end
  local threshold = (Z.DB and Z.DB.minLootQuality) or 3
  local found, coin, free = {}, {}, {}
  local n = GetNumLootItems()
  for slot = 1, n do
    local e = M.ScanSlot(slot, threshold)
    if e then
      if e.coin then table.insert(coin, e)
      elseif e.free then table.insert(free, e)
      else table.insert(found, e) end
    end
  end
  if Z.Util.ArrayCount(found) == 0
      and Z.Util.ArrayCount(coin) == 0
      and Z.Util.ArrayCount(free) == 0 then
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
  -- Ours is the loot window now: (re-)detach Blizzard's frame — hiding
  -- once is not enough, FrameXML re-shows it on every loot — while our
  -- rows cover this corpse. Detach is idempotent (safe to repeat per loot).
  if Z.LootWindow and Z.LootWindow.DetachBlizzardLoot then
    pcall(Z.LootWindow.DetachBlizzardLoot)
  end
  -- RollFor-style loot window: coin first, roll rows next, free leftovers
  -- last. The ML works each roll row from the list; coin/free rows loot
  -- on click.
  if Z.LootWindow then
    local rows = {}
    local function push(e, badge)
      table.insert(rows, { itemID = e.itemID, link = e.link,
        name = e.name, texture = e.texture,
        quality = e.quality, quantity = e.quantity,
        slot = e.slot, badge = badge or "", coin = e.coin, free = e.free })
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
    for i = 1, Z.Util.ArrayCount(free) do push(free[i]) end
    Z.LootWindow.SetItems(rows, "loot")
    Z.LootWindow.Show("Boss loot")
  end
  Z.Print("Loot window open — click a row, then Award / ... / Close.")
end

function M.OnEvent(event, a1, a2)
  if event == "CHAT_MSG_SYSTEM" and M.session then
    -- "Name rolls 42 (1-100)"
    local player, roll, minR, maxR = string.match(tostring(a1 or ""), "(.+) rolls (%d+) %((%d+)%-(%d+)%)")
    if player then M.OnSystemRoll(player, tonumber(roll), tonumber(minR), tonumber(maxR)) end
  elseif event == "LOOT_OPENED" then
    M.OnLootOpened()
  end
end
