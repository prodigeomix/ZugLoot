-- ZugLoot/MasterLootUI.lua
-- RollFor-like master-looter console: loot list + session control + award confirm.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.MasterLootUI = M

M.session = nil -- { id, itemID, itemLink, mode, rolls={}, t=0, itemCount=1 }

local sessionSeq = 0

function M.RequireML()
  if not Z.SRSecurity.AmML() then
    Z.Print("Only the master looter can start rolls.")
    return false
  end
  return true
end

-- Shared session start for live rolls and sim. silent=true skips the
-- addon-message broadcast (sim must not pop other clients' roller windows
-- or trigger their auto-rolls); the local raider window still shows.
function M.BeginSession(itemID, itemLink, mode, silent)
  sessionSeq = sessionSeq + 1
  local itemCount = 1
  if mode == "TWO" then itemCount = 2 end
  M.session = { id = sessionSeq, itemID = itemID, itemLink = itemLink, mode = mode, rolls = {}, t = 0, itemCount = itemCount, silent = silent }
  local label = itemLink
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
  return M.session
end

function M.StartRoll(linkText, mode)
  if not M.RequireML() then return end
  local itemID = Z.Util.ItemID(linkText)
  if not itemID then Z.Print("Usage: /zl rf <itemlink>") return end
  M.BeginSession(itemID, linkText, mode, false)
end

-- ML initiates a roll for one loot-window item (loot list Roll button or
-- /zl roll <itemID|link>). Live corpse rows only; sim rows go via Sim.
function M.StartItemRoll(itemIDorLink)
  if not M.RequireML() then return end
  if M.session then
    Z.Print("A roll is already running — finish or /zl cr first.")
    return
  end
  local itemID = Z.Util.ItemID(itemIDorLink)
  if not itemID then Z.Print("Usage: /zl roll <itemlink|itemID>") return end
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
  if not M.session then return end
  -- ROLL_ANS:<session>:<name>:<rollType> — auto-roll path confirmation.
  local sid = tonumber(string.match(msg, "ROLL_ANS:(%d+):") or "")
  if sid ~= M.session.id then return end
  -- Auto answer counts as intent; real /roll still decides the number.
end

function M.OnSystemRoll(player, roll, minR, maxR)
  if not M.session then return end
  local sess = M.session
  -- First-roll-only.
  for i = 1, Z.Util.ArrayCount(sess.rolls) do
    if sess.rolls[i].name == player then return end
  end
  local rtype = "MS"
  if maxR == Z.Caps.OS then rtype = "OS"
  elseif maxR == Z.Caps.TMOG then rtype = "TMOG" end
  if minR == 1 and maxR == Z.Caps.SR then
    -- SR-range; keep MS label unless sheet says SR (resolver decides).
    rtype = "SR"
  end
  table.insert(sess.rolls, { name = player, roll = roll, type = rtype })
  -- Flag already-won rollers so the live list shows them as excluded.
  local excluded = false
  if Z.DB.sheet and Z.SRData.HasWon then
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

function M.FinishEarly() M.Finish(true) end
function M.Cancel()
  if not M.session then Z.Print("No active session.") return end
  local wasSilent = M.session.silent
  local itemID = M.session.itemID
  local sessionID = M.session.id
  M.pendingAwardMenu = nil
  M.session = nil
  Z.Print("Roll cancelled.")
  if Z.LootWindow and itemID then Z.LootWindow.MarkOpen(itemID) end
  -- An open rolling detail drops back to pick (re-roll / choose / close).
  if Z.LootWindow and Z.LootWindow.detail
      and Z.LootWindow.detail.itemID == itemID
      and Z.LootWindow.detail.sessionID == sessionID then
    Z.LootWindow.detail.phase = "pick"
    Z.LootWindow.detail.sessionID = nil
    Z.LootWindow.detail.rolls = {}
    Z.LootWindow.detail.menu = nil
    Z.LootWindow.detail.status = "open"
    Z.LootWindow.RefreshDetail()
  end
  if Z.RaiderLootUI then Z.RaiderLootUI.Hide() end
  -- A cancelled sim item returns to the queue head for a re-roll.
  if wasSilent and Z.Sim and Z.Sim.Requeue then Z.Sim.Requeue(itemID) end
end

-- Returns "tie" (session left open for re-rolls), "awaiting" (sim awards
-- pending ML confirmation), or "closed". Live callers ignore the result.
function M.Finish(manual)
  local sess = M.session
  if not sess then Z.Print("No active session.") return "closed" end
  local sheet = Z.DB.sheet
  local openRoll = sess.mode == "OPEN" or sess.mode == "RAID" or sess.mode == "SIM-OPEN"
  local res = Z.Resolver.ResolveItem(sheet or { items = {}, won = {} }, sess.itemID, sess.rolls,
    { cap = Z.Caps.SR, requireSR = (not openRoll and sheet ~= nil), itemCount = sess.itemCount })
  M.AnnounceResult(sess, res)
  if Z.Util.ArrayCount(res.tied) > 0 then
    Z.Print("Tie at top — tied players re-roll.")
    return "tie" -- keep session open for tie re-rolls (extra rolls ignored for others)
  end
  local data = M.BuildAwardMenu(sess, res)
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
    if M.session then return "awaiting" end
    return "closed"
  end
  M.ShowAwardMenu(sess, data)
  -- Session stays open ("awaiting"): the ML's menu choice closes it
  -- (AwardChosen) or it is cancelled. Callers must check M.session.
  return "awaiting"
end

function M.AnnounceResult(sess, res)
  local parts = {}
  for i = 1, Z.Util.ArrayCount(res.ranked) do
    local e = res.ranked[i]
    local s = e.name .. " " .. e.base
    if e.sr_plus and e.sr_plus > 0 then s = s .. "(+" .. e.sr_plus .. "=" .. e.effective .. ")" end
    table.insert(parts, s)
  end
  if Z.Util.ArrayCount(res.missrolls) > 0 then
    local mm = {}
    for i = 1, Z.Util.ArrayCount(res.missrolls) do table.insert(mm, res.missrolls[i].name) end
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
      local s = e.name .. " " .. tostring(e.base)
      if e.sr_plus and e.sr_plus > 0 then s = s .. "(+" .. e.sr_plus .. "=" .. (e.effective or e.base) .. ")" end
      table.insert(xm, s .. " [already won]")
    end
    table.insert(parts, "excluded: " .. table.concat(xm, ", "))
  end
  local resultText = "ZugLoot result [" .. sess.itemLink .. "]: " .. table.concat(parts, " | ")
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
      local s = tag .. " winner: " .. e.name .. " (" .. tostring(e.effective) .. ")"
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
    local line = "TMOG winner: " .. e.name .. " (" .. tostring(e.effective) .. ")"
    if Z.Comm and Z.Comm.WarnGroup then Z.Comm.WarnGroup(line) else Z.Print(line) end
  end
  if Z.Util.ArrayCount(res.winners) > 0 then
    local w = {}
    for i = 1, Z.Util.ArrayCount(res.winners) do table.insert(w, res.winners[i].name .. " (" .. res.winners[i].effective .. ")") end
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
  if Z.DB.sheet and Z.SRData.RecordRolls then
    -- Item rolled but never SR'd: stub it onto the sheet so it shows at the
    -- bottom, flagged as not SR'd. Only when rolls actually happened.
    if Z.Util.ArrayCount(res.entries or {}) > 0 and Z.SRData.EnsureUnreserved then
      local q = nil
      if GetItemInfo then
        local _, _, qq = GetItemInfo(tonumber(sess.itemID))
        q = qq
      end
      if Z.SRData.EnsureUnreserved(Z.DB.sheet, sess.itemID, q) then
        Z.Print("Note: " .. tostring(sess.itemLink or sess.itemID) .. " was not on the SR sheet — added below, marked not SR'd.")
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
function M.RosterClasses()
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
    table.insert(out, { name = names[i], class = classes[names[i]] })
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
  table.insert(lines, "Award " .. tostring(data.itemLink or ("item:" .. tostring(data.itemID))) .. " to?")
  -- Each kind judged by itself (ranges: SR 100, MS 100, OS 99, TMOG 98).
  for _, gt in ipairs({ "SR", "MS", "OS", "TMOG" }) do
    local row = (data.perType or {})[gt]
    if row and row.entry then
      local e = row.entry
      table.insert(lines, "  " .. gt .. " winner: " .. e.name .. " (" .. tostring(e.effective) .. ")")
      for t = 1, Z.Util.ArrayCount(row.tied or {}) do
        table.insert(lines, "    tied: " .. row.tied[t].name .. " (" .. tostring(row.tied[t].effective) .. ")")
      end
    end
  end
  for i = 1, Z.Util.ArrayCount(data.winners or {}) do
    local w = data.winners[i]
    table.insert(lines, "  overall: " .. w.name .. " (" .. tostring(w.rollType) .. " " .. tostring(w.effective) .. ")")
  end
  for _, gt in ipairs({ "SR", "MS", "OS", "TMOG" }) do
    local g = (data.groups or {})[gt] or {}
    for j = 1, Z.Util.ArrayCount(g) do
      table.insert(lines, "  " .. gt .. ": " .. g[j].name .. " (" .. tostring(g[j].effective) .. ")")
    end
  end
  if data.none then table.insert(lines, "  (no eligible rolls — pick anyone or cancel)") end
  local cands = data.candidates or {}
  local names = {}
  for i = 1, Z.Util.ArrayCount(cands) do
    local c = cands[i]
    table.insert(names, c.name .. (c.class and (" [" .. c.class .. "]") or ""))
  end
  if Z.Util.ArrayCount(names) > 0 then
    table.insert(lines, "  candidates: " .. table.concat(names, ", "))
  end
  return lines
end

-- Show the award menu (RollFor finish-popup equivalent). Client builds the
-- frame with winner buttons + roll-type rows + candidate grid; headless and
-- text clients (tests, /zl text UIs) get the same rows printed so the ML
-- can answer with /zl award <name>. Stores the pending menu for AwardChosen.
function M.ShowAwardMenu(sess, data)
  M.pendingAwardMenu = { sess = sess, data = data }
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
    string.format("Award %s to %s?", display, tostring(winnerName))
  StaticPopupDialogs["ZUGLOOT_AWARD"].itemLink = itemLink
  StaticPopupDialogs["ZUGLOOT_AWARD"].OnAccept = onAccept or function() end
  StaticPopup_Show("ZUGLOOT_AWARD")
  return true
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
  if Z.LootWindow then Z.LootWindow.MarkDone(itemID) end
end

-- Award core: marks won, broadcasts, logs, prints. No UI.
function M.DoAward(itemID, itemLink, winnerName, source)
  if not Z.DB.sheet then Z.DB.sheet = Z.SRData.NewSheet() end
  source = source or "raid"
  Z.SRData.MarkWon(Z.DB.sheet, itemID, winnerName)
  if Z.Comm then Z.Comm.BroadcastAward(itemID, winnerName) end
  if Z.DropLog then Z.DropLog.Add(itemID, itemLink, source, "award", winnerName) end
  Z.Print("Awarded " .. tostring(itemLink) .. " to " .. winnerName)
  if Z.SRView then Z.SRView.Refresh() end
end

-- Sim award flow: the ML picks one row of the award menu for each winner
-- slot. Headless (tests): the menu stays pending and the harness plays
-- the ML via AwardChosen.
M.pendingAwardMenu = nil -- { sess, data } while the ML decides

function M.HandleSimAward(sess, data)
  M.pendingAwardMenu = { sess = sess, data = data }
  local winners = data.winners or {}
  if Z.Util.ArrayCount(winners) == 0 then
    -- Nobody eligible: record the empty round and move on.
    M.pendingAwardMenu = nil
    M.session = nil
    if Z.Sim and Z.Sim.afterAwards then Z.Sim.afterAwards() end
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
function M.AwardChosen(choice)
  local pend = M.pendingAwardMenu
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
  if Z.LootWindow then Z.LootWindow.MarkDone(sess.itemID) end
  if Z.Sim and sess.silent then
    -- Snapshot the finished row: queue rebuilds may drop it from the
    -- window before SyncLootWindow re-appends it.
    Z.Sim.doneRows = Z.Sim.doneRows or {}
    local prev = Z.LootWindow and Z.LootWindow.Find(sess.itemID)
    if prev then
      -- Full resolved row so the re-append keeps name/texture/badge.
      Z.Sim.doneRows[sess.itemID] = {
        itemID = sess.itemID, link = prev.link or link, name = prev.name,
        texture = prev.texture, quality = prev.quality,
        quantity = prev.quantity, badge = prev.badge,
        status = "done", source = "sim" }
    else
      Z.Sim.doneRows[sess.itemID] = { itemID = sess.itemID, link = link,
        status = "done", source = "sim" }
    end
  end
  showAwardPopup(link, name, function()
    M.DoAward(sess.itemID, link, name, source)
    closeFinishedDetail()
    M.pendingAwardMenu = nil
    M.session = nil
    if sess.silent then
      if Z.Sim and Z.Sim.afterAwards then Z.Sim.afterAwards() end
    elseif Z.RaiderLootUI and Z.RaiderLootUI.Hide then
      Z.RaiderLootUI.Hide()
    end
  end)
  -- Headless (tests): no popup API — the award above already applied via
  -- DoAward inside... only when the popup fires. Without a client there is
  -- no OnAccept, so apply directly.
  if not (StaticPopupDialogs and StaticPopup_Show) then
    if Z.LootWindow then Z.LootWindow.MarkDone(sess.itemID) end
    if Z.Sim and sess.silent then
      Z.Sim.doneRows = Z.Sim.doneRows or {}
      local prev = Z.LootWindow and Z.LootWindow.Find(sess.itemID)
      if prev then
        Z.Sim.doneRows[sess.itemID] = {
          itemID = sess.itemID, link = prev.link or link, name = prev.name,
          texture = prev.texture, quality = prev.quality,
          quantity = prev.quantity, badge = prev.badge,
          status = "done", source = "sim" }
      else
        Z.Sim.doneRows[sess.itemID] = { itemID = sess.itemID, link = link,
          status = "done", source = "sim" }
      end
    end
    M.DoAward(sess.itemID, link, name, source)
    closeFinishedDetail()
    M.pendingAwardMenu = nil
    M.session = nil
    if sess.silent then
      if Z.Sim and Z.Sim.afterAwards then Z.Sim.afterAwards() end
    end
  end
end

-- Legacy entry point (pre-menu auto-award). Kept for compatibility:
-- routes through the menu choice so the ML still confirms.
function M.Award(itemID, itemLink, winnerEntry)
  local sess = M.session
  if sess and sess.itemID == itemID then
    M.pendingAwardMenu = { sess = sess, data = M.BuildAwardMenu(sess,
      Z.Resolver.ResolveItem(Z.DB.sheet or { items = {}, won = {} },
        sess.itemID, sess.rolls, { cap = Z.Caps.SR, requireSR = true, itemCount = sess.itemCount })) }
  else
    M.pendingAwardMenu = { sess = { itemID = itemID, itemLink = itemLink, id = 0, silent = false, itemCount = 1 },
      data = { winners = {}, groups = { SR = {}, MS = {}, OS = {}, TMOG = {} },
        candidates = {}, perType = {}, none = false, itemID = itemID, itemLink = itemLink } }
  end
  M.AwardChosen({ name = winnerEntry.name, via = "winner" })
end

-- RollFor-style: when a boss is looted, the master looter picks it up.
-- Scans the corpse loot for roll-worthy items (quality threshold), shows
-- the sheet window, announces each item, and starts the first session.
-- Further items go through /rf (or the sim loot window in sim).
function M.OnLootOpened()
  if not Z.SRSecurity or not M.RequireML() then return end
  if M.session then return end -- already rolling
  if not GetNumLootItems or not GetLootSlotLink then return end
  local threshold = (Z.DB and Z.DB.minLootQuality) or 3
  local found = {}
  local n = GetNumLootItems()
  for slot = 1, n do
    local link = GetLootSlotLink(slot)
    if link then
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
      if (q or 0) >= threshold then
        table.insert(found, { link = link, quality = q or 0,
          texture = tex, quantity = qty, slot = slot, name = slotName })
      end
    end
  end
  if Z.Util.ArrayCount(found) == 0 then return end
  if Z.MainWindow and Z.MainWindow.Show then Z.MainWindow.Show("sheet") end
  for i = 1, Z.Util.ArrayCount(found) do
    local f = found[i]
    Z.Comm.WarnGroup("ZugLoot loot: " .. f.link)
    if Z.DropLog then Z.DropLog.Add(Z.Util.ItemID(f.link), f.link, "loot", "seen", nil) end
  end
  -- RollFor-style loot window: the ML works each row from the list.
  if Z.LootWindow then
    local rows = {}
    for i = 1, Z.Util.ArrayCount(found) do
      local id = Z.Util.ItemID(found[i].link)
      local badge = ""
      if Z.DB.sheet and id and Z.SRData.ReserveBadge then
        badge = Z.SRData.ReserveBadge(Z.DB.sheet, id)
      end
      table.insert(rows, { itemID = id, link = found[i].link,
        name = found[i].name, texture = found[i].texture,
        quality = found[i].quality, quantity = found[i].quantity,
        slot = found[i].slot, badge = badge })
    end
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
