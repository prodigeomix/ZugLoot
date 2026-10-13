-- ZugLoot/Comm.lua
-- Addon-message transport + receiver-side sheet guard.
-- Prefix ZugLoot. Types: SHEET / ROLL_REQ / ROLL_ANS / VER_REQ / VER_ANS / AWARD / LOG.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.Comm = M

local function send(msg, channel)
  if SendAddonMessage then
    SendAddonMessage(Z.PREFIX, msg, channel or "RAID")
  end
end

function M.Channel()
  if Z.SRSecurity and Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo() then return nil end
  if Z.SRSecurity and Z.SRSecurity.IsInRaid() then return "RAID" end
  return "PARTY"
end

-- SHEET:<ver>:<raidID>:<payload(base64 json of normalized sheet)|raw>
-- Solo: no one to send to — skip silently (local preview only).
function M.BroadcastSheet(sheet, raidID)
  if Z.SRSecurity and Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo() then return end
  local channel = M.Channel()
  if not channel then return end
  local ver = 1
  local payload = Z.SRImport.SerializeSheet(sheet)
  send("SHEET:" .. ver .. ":" .. tostring(raidID) .. ":" .. payload, channel)
end

function M.SendRollReq(sessionID, itemLink, mode)
  send("ROLL_REQ:" .. tostring(sessionID) .. ":" .. tostring(itemLink) .. ":" .. tostring(mode), M.Channel())
end

function M.SendRollAns(sessionID, rollType)
  send("ROLL_ANS:" .. tostring(sessionID) .. ":" .. UnitName("player") .. ":" .. tostring(rollType), M.Channel())
end

function M.RequestVersions()
  local c = M.Channel()
  if not c then return end
  send("VER_REQ", c)
end
function M.AnnounceVersion()
  local c = M.Channel()
  if not c then return end
  send("VER_ANS:" .. tostring(Z.VERSION), c)
end
function M.BroadcastAward(itemID, winner)
  local c = M.Channel()
  if not c then return end
  send("AWARD:" .. tostring(itemID) .. ":" .. tostring(winner), c)
end

-- Local loot channel: solo or non-master loot methods stay on the local
-- chat frame (no one else's chat to coordinate); master loot in a group
-- uses group chat like before. Used by live rolls and sim alike.
local function localLoot()
  if Z.SRSecurity and Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo() then return true end
  if Z.SRSecurity and Z.SRSecurity.LootMethod then
    local m = Z.SRSecurity.LootMethod()
    if m and m ~= "master" then return true end
  end
  return false
end

-- Group-aware chat for roll traffic. Master loot in raid -> RAID /
-- RAID_WARNING, master loot in party -> PARTY, everything else (solo,
-- group/need/greed etc.) -> local chat frame (Z.Print).
function M.SayGroup(msg)
  if localLoot() then Z.Print(msg) return end
  if Z.SRSecurity and Z.SRSecurity.IsInRaid and Z.SRSecurity.IsInRaid() then
    if SendChatMessage then SendChatMessage(tostring(msg), "RAID") end
  elseif Z.SRSecurity and Z.SRSecurity.IsInGroup and Z.SRSecurity.IsInGroup() then
    if SendChatMessage then SendChatMessage(tostring(msg), "PARTY") end
  else
    Z.Print(msg)
  end
end

function M.WarnGroup(msg)
  if localLoot() then Z.Print(msg) return end
  if Z.SRSecurity and Z.SRSecurity.IsInRaid and Z.SRSecurity.IsInRaid() then
    if SendChatMessage then SendChatMessage(tostring(msg), "RAID_WARNING") end
  elseif Z.SRSecurity and Z.SRSecurity.IsInGroup and Z.SRSecurity.IsInGroup() then
    -- No raid warnings in a party: plain party message instead.
    if SendChatMessage then SendChatMessage(tostring(msg), "PARTY") end
  else
    Z.Print(msg)
  end
end

function M.OnEvent(event, a1, a2, a3, a4)
  if event == "CHAT_MSG_ADDON" then
    local prefix, msg, channel, sender = a1, a2, a3, a4
    if prefix ~= Z.PREFIX then return end
    M.OnMessage(tostring(msg or ""), sender)
  end
end

function M.OnMessage(msg, sender)
  local tag = string.match(msg, "^(%S+):")
  -- Version traffic is open to all.
  if string.sub(msg, 1, 7) == "VER_REQ" then
    M.AnnounceVersion()
    return
  end
  if string.sub(msg, 1, 7) == "VER_ANS" then
    if Z.VersionGrid then Z.VersionGrid.OnVersion(sender, string.match(msg, "VER_ANS:(.*)$")) end
    return
  end
  if string.sub(msg, 1, 9) == "ROLL_REQ:" then
    if Z.RaiderLootUI then Z.RaiderLootUI.OnRollReq(msg, sender) end
    return
  end
  if string.sub(msg, 1, 9) == "ROLL_ANS:" then
    if Z.MasterLootUI then Z.MasterLootUI.OnRollAns(msg, sender) end
    return
  end
  if string.sub(msg, 1, 6) == "AWARD:" then
    local itemID, winner = string.match(msg, "AWARD:(%d+):(.+)$")
    if itemID and Z.DB and Z.DB.sheet and Z.SRData then
      Z.SRData.MarkWon(Z.DB.sheet, tonumber(itemID), winner)
      if Z.MainWindow then Z.MainWindow.Refresh() end
      if Z.SRView then Z.SRView.Refresh() end
    end
    return
  end
  if string.sub(msg, 1, 6) == "SHEET:" then
    -- SECURITY: only ML or raid leader/assistant may push sheets.
    if not Z.SRSecurity.CanAcceptFrom(sender) then
      Z.Print("Ignored sheet from " .. tostring(sender) .. " (not ML/leader).")
      return
    end
    local ver, raidID, payload = string.match(msg, "SHEET:(%d+):([^:]+):(.+)$")
    if not payload then Z.Print("Bad sheet message from " .. tostring(sender)) return end
    local sheet, err = Z.SRImport.DeserializeSheet(payload)
    if not sheet then Z.Print("Sheet import failed: " .. tostring(err)) return end
    sheet.meta.raidID = raidID
    sheet.meta.importedBy = sender
    -- Stale guard: never overwrite a newer raidID.
    if Z.DB.sheet and Z.DB.sheet.meta.raidID and raidID <= Z.DB.sheet.meta.raidID then
      Z.Print("Ignored stale sheet " .. tostring(raidID))
      return
    end
    if Z.RaidArchive then
      Z.RaidArchive.ArchiveActive(Z.DB, (time and time()) or 0)
    end
    Z.DB.sheet = sheet
    if Z.RaidArchive then
      Z.RaidArchive.SyncActive(Z.DB, (time and time()) or 0)
    end
    Z.Print("Sheet received from " .. tostring(sender) .. " (" .. tostring(raidID) .. ")")
    if Z.MainWindow then Z.MainWindow.Refresh() end
    if Z.SRView then Z.SRView.Refresh() end
    return
  end
end
