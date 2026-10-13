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

function M.StartRoll(linkText, mode)
  if not M.RequireML() then return end
  local itemID = Z.Util.ItemID(linkText)
  if not itemID then Z.Print("Usage: /zl rf <itemlink>") return end
  sessionSeq = sessionSeq + 1
  local itemCount = 1
  if mode == "TWO" then itemCount = 2 end
  M.session = { id = sessionSeq, itemID = itemID, itemLink = linkText, mode = mode, rolls = {}, t = 0, itemCount = itemCount }
  local label = linkText
  if mode == "OPEN" then label = label .. " (open roll)"
  elseif mode == "RAID" then label = label .. " (raid roll)"
  elseif mode == "TWO" then label = label .. " (2 top win)" end
  SendChatMessage("ZugLoot rolling: " .. label .. " — /roll (" .. Z.DB.rollTime .. "s)", "RAID_WARNING")
  Z.Comm.SendRollReq(sessionSeq, linkText, mode)
  Z.RaiderLootUI.ShowItem(linkText, Z.DB.rollTime)
  Z.Print("Roll started (" .. mode .. ") session #" .. sessionSeq)
  if Z.AutoRoll.AllGreenAndAuto() then
    Z.Print("All SR rollers on auto — will auto-resolve on ROLL_ANS.")
  end
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
  Z.RaiderLootUI.OnRoll(player, roll, rtype, excluded)
end

function M.FinishEarly() M.Finish(true) end
function M.Cancel()
  if not M.session then Z.Print("No active session.") return end
  M.session = nil
  Z.Print("Roll cancelled.")
  Z.RaiderLootUI.Hide()
end

function M.Finish(manual)
  local sess = M.session
  if not sess then Z.Print("No active session.") return end
  local sheet = Z.DB.sheet
  local openRoll = sess.mode == "OPEN" or sess.mode == "RAID"
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
  SendChatMessage("ZugLoot result [" .. sess.itemLink .. "]: " .. table.concat(parts, " | "), "RAID")
  if Z.Util.ArrayCount(res.winners) > 0 then
    local w = {}
    for i = 1, Z.Util.ArrayCount(res.winners) do table.insert(w, res.winners[i].name .. " (" .. res.winners[i].effective .. ")") end
    SendChatMessage("Winner: " .. table.concat(w, ", "), "RAID_WARNING")
  end
  -- Persist the session into per-item roll history (survives the session).
  -- Same shape the sim writes (Resolver.ToHistoryEntry).
  if Z.DB.sheet and Z.SRData.RecordRolls then
    Z.SRData.RecordRolls(Z.DB.sheet, sess.itemID,
      Z.Resolver.ToHistoryEntry(res, sess.mode, (time and time()) or 0))
    if Z.MainWindow then Z.MainWindow.Refresh() end
  end
end

function M.Award(itemID, itemLink, winnerEntry)
  -- Confirmation popup (1.12 StaticPopup).
  StaticPopupDialogs["ZUGLOOT_AWARD"] = StaticPopupDialogs["ZUGLOOT_AWARD"] or {
    text = "Award %s to %s?",
    button1 = "Award", button2 = "Cancel",
    OnAccept = function() end, timeout = 0, whileDead = 1,
  }
  local dlg = StaticPopup_Show("ZUGLOOT_AWARD")
  -- Skeleton: award immediately + confirm text (full popup wiring is UI polish).
  if not Z.DB.sheet then Z.DB.sheet = Z.SRData.NewSheet() end
  Z.SRData.MarkWon(Z.DB.sheet, itemID, winnerEntry.name)
  Z.Comm.BroadcastAward(itemID, winnerEntry.name)
  Z.DropLog.Add(itemID, itemLink, "raid", "award", winnerEntry.name)
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
