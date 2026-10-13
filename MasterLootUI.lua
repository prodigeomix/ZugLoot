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
end

function M.FinishEarly() M.Finish(true) end
function M.Cancel()
  if not M.session then Z.Print("No active session.") return end
  M.session = nil
  Z.Print("Roll cancelled.")
  if Z.RaiderLootUI then Z.RaiderLootUI.Hide() end
end

function M.Finish(manual)
  local sess = M.session
  if not sess then Z.Print("No active session.") return end
  local sheet = Z.DB.sheet
  local openRoll = sess.mode == "OPEN" or sess.mode == "RAID" or sess.mode == "SIM-OPEN"
  local res = Z.Resolver.ResolveItem(sheet or { items = {}, won = {} }, sess.itemID, sess.rolls,
    { cap = Z.Caps.SR, requireSR = (not openRoll and sheet ~= nil), itemCount = sess.itemCount })
  M.AnnounceResult(sess, res)
  if Z.Util.ArrayCount(res.tied) > 0 then
    Z.Print("Tie at top — tied players re-roll.")
    return -- keep session open for tie re-rolls (extra rolls ignored for others)
  end
  if Z.Util.ArrayCount(res.winners) > 0 then
    for i = 1, Z.Util.ArrayCount(res.winners) do
      M.Award(sess.itemID, sess.itemLink, res.winners[i])
    end
  else
    Z.Print("No eligible rolls.")
  end
  M.session = nil
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
  if Z.Util.ArrayCount(res.winners) > 0 then
    local w = {}
    for i = 1, Z.Util.ArrayCount(res.winners) do table.insert(w, res.winners[i].name .. " (" .. res.winners[i].effective .. ")") end
    if Z.Comm and Z.Comm.WarnGroup then
      Z.Comm.WarnGroup("Winner: " .. table.concat(w, ", "))
    else
      Z.Print("Winner: " .. table.concat(w, ", "))
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

function M.Award(itemID, itemLink, winnerEntry)
  -- Confirmation popup (1.12 StaticPopup). Skipped outside the client.
  -- The text is pre-formatted here (proven pattern on this client, cf.
  -- Bagshui): relying on the client to fill %s from Show args crashes in
  -- StaticPopup.lua with "bad argument #2".
  if StaticPopupDialogs and StaticPopup_Show then
    StaticPopupDialogs["ZUGLOOT_AWARD"] = StaticPopupDialogs["ZUGLOOT_AWARD"] or {
      text = "",
      button1 = "Award", button2 = "Cancel",
      OnAccept = function() end, timeout = 0, whileDead = 1,
    }
    StaticPopupDialogs["ZUGLOOT_AWARD"].text =
      string.format("Award %s to %s?", tostring(itemLink), tostring(winnerEntry.name))
    StaticPopup_Show("ZUGLOOT_AWARD")
  end
  -- Skeleton: award immediately + confirm text (full popup wiring is UI polish).
  if not Z.DB.sheet then Z.DB.sheet = Z.SRData.NewSheet() end
  -- Sim sessions log their own source; live rolls log "raid".
  local source = "raid"
  if M.session and (M.session.mode == "SIM" or M.session.mode == "SIM-OPEN") then
    source = "sim"
  end
  Z.SRData.MarkWon(Z.DB.sheet, itemID, winnerEntry.name)
  if Z.Comm then Z.Comm.BroadcastAward(itemID, winnerEntry.name) end
  if Z.DropLog then Z.DropLog.Add(itemID, itemLink, source, "award", winnerEntry.name) end
  Z.Print("Awarded " .. tostring(itemLink) .. " to " .. winnerEntry.name)
  if Z.SRView then Z.SRView.Refresh() end
end

function M.OnEvent(event, a1, a2)
  if event == "CHAT_MSG_SYSTEM" and M.session then
    -- "Name rolls 42 (1-100)"
    local player, roll, minR, maxR = string.match(tostring(a1 or ""), "(.+) rolls (%d+) %((%d+)%-(%d+)%)")
    if player then M.OnSystemRoll(player, tonumber(roll), tonumber(minR), tonumber(maxR)) end
  end
end
