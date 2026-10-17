-- ZugLoot/Comm.lua
-- Addon-message transport + receiver-side sheet guard.
-- Prefix ZugLoot. Types: SHEET / ROLL_REQ / VER_REQ / VER_ANS / AWARD / LOG.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.Comm = M

local function send(msg, channel)
  channel = channel or M.Channel() or "RAID"
  if ChatThrottleLib and ChatThrottleLib.SendAddonMessage then
    ChatThrottleLib:SendAddonMessage("NORMAL", Z.PREFIX, msg, channel)
  elseif SendAddonMessage then
    SendAddonMessage(Z.PREFIX, msg, channel)
  end
end

M.CHUNK_SIZE = 160 -- Safe headroom under the 254-byte MTU limit
M.DEBOUNCE_INTERVAL = 1.5
M.lastBroadcastTime = 0
M.lastSheetReqTime = 0
M.lastVerReqTime = 0
M.chunkBuffers = {}

function M.Channel()
  if Z.SRSecurity and Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo() then return nil end
  if Z.SRSecurity and Z.SRSecurity.IsInRaid() then return "RAID" end
  return "PARTY"
end

-- SHEET_REQ: ask the group for the current sheet. Only the ML answers
-- with a sheet they actually hold (AnySheet), else the raid leader /
-- assistant with theirs — priority ML > leader, never anyone else.
-- SHEET:<ver>:<raidID>:<payload>. Payload encoding: base64-wrapped when
-- the encoder exists, else escape-quoted raw. NEVER raw: the line format
-- uses "|" as its row separator and ChatThrottleLib (bundled with other
-- addons on this client) rejects bare pipes in chat/addon traffic with
-- "Invalid escape code in chat message" (ChatThrottleLib.lua:261).
-- Escape scheme (both directions, see DeserializeSheet): "%" -> "%P",
-- "|" -> "%B"; base64 output needs no escaping (A-Za-z0-9+/= only).
-- Solo: no one to send to — skip silently (local preview only).
function M.EncodeSheetPayload(sheet)
  local raw = Z.SRImport.SerializeSheet(sheet)
  if Base64Encode then
    local ok, enc = pcall(Base64Encode, raw)
    if ok and enc and enc ~= "" then return "B64" .. enc end
  end
  -- NOTE: gsub REPLACEMENTS escape % too: "%P" must be written "%%P"
  -- or lua reads %P as a (nonexistent) capture ("invalid use of %").
  local esc = string.gsub(tostring(raw), "%%", "%%P")
  esc = string.gsub(esc, "|", "%%B")
  return "ESC" .. esc
end

function M.BroadcastSheet(sheet, raidID, targetChannel)
  if Z.SRSecurity and Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo() then return end
  local channel = targetChannel or M.Channel()
  if not channel then return end
  local now = (GetTime and GetTime()) or (time and time()) or 0
  if (now - (M.lastBroadcastTime or 0)) < M.DEBOUNCE_INTERVAL then return end
  M.lastBroadcastTime = now
  local ver = 1
  local payload = M.EncodeSheetPayload(sheet)
  local plen = string.len(payload)
  if plen <= M.CHUNK_SIZE then
    send("SHEET:" .. ver .. ":" .. tostring(raidID) .. ":" .. payload, channel)
  else
    local total = math.floor((plen + M.CHUNK_SIZE - 1) / M.CHUNK_SIZE)
    for seq = 1, total do
      local startIdx = (seq - 1) * M.CHUNK_SIZE + 1
      local endIdx = seq * M.CHUNK_SIZE
      local chunk = string.sub(payload, startIdx, endIdx)
      send("SHEET_C:" .. ver .. ":" .. tostring(raidID) .. ":" .. seq .. ":" .. total .. ":" .. chunk, channel)
    end
  end
end

function M.SendRollReq(itemID, itemLink, mode)
  send("ROLL_REQ:" .. tostring(itemID) .. ":" .. tostring(itemLink) .. ":" .. tostring(mode), M.Channel())
end

function M.RequestVersions()
  local c = M.Channel()
  if not c then return end
  local now = (GetTime and GetTime()) or (time and time()) or 0
  if (now - (M.lastVerReqTime or 0)) < M.DEBOUNCE_INTERVAL then return end
  M.lastVerReqTime = now
  send("VER_REQ", c)
end

-- Strip a player link to its bare name: "|cFF...Name|r" (class-colored
-- chat link, possibly with an |Hplayer:...|h wrapper) -> "Name".
-- Anything without color markup passes through trimmed. Pure helper.
function M.StripPlayerLink(s)
  s = tostring(s or "")
  -- |Hplayer:Name|h[Name]|h form (possibly itself color-wrapped):
  -- prefer the bracket display.
  local disp = string.match(s, "|Hplayer:[^|]*|h%[(.-)%]|h")
  if disp and disp ~= "" then
    -- Recurse: the display itself may carry color markup.
    local inner = string.match(disp, "^|c%x%x%x%x%x%x%x%x(.-)|r$")
    if inner then disp = inner end
    return Z.Util.Trim(disp)
  end
  -- Bare color wrap |cXXXXXXXXName|r.
  local inner = string.match(s, "^|c%x%x%x%x%x%x%x%x(.-)|r$")
  if inner then return Z.Util.Trim(inner) end
  return Z.Util.Trim(s)
end

-- Ask the group for the SR sheet (Members tab button, /zl sheetreq).
-- Solo: nobody to ask. Everyone hears it; only the ML (or the leader
-- when no ML sheet exists) answers — see OnMessage/SHEET_REQ.
function M.RequestSheet()
  local c = M.Channel()
  if not c then
    Z.Print("No group to ask — solo has no sheet source.")
    return
  end
  local now = (GetTime and GetTime()) or (time and time()) or 0
  if (now - (M.lastSheetReqTime or 0)) < M.DEBOUNCE_INTERVAL then return end
  M.lastSheetReqTime = now
  local me = (UnitName and UnitName("player")) or "?"
  send("SHEET_REQ", c)
  Z.Print("Sheet requested from the master looter (" .. tostring(me) .. " asked).")
end

-- Ask ONE player for their sheet (/zl sync <name>): targeted request.
-- Anyone may hold a sheet worth syncing (imports are open to all), but
-- the RECEIVE side still only trusts ML/leader sheets (CanAcceptFrom) —
-- a raider's answer arrives and is refused with the usual message.
-- Name accepts player links (color-coded [Name]) as well as bare names.
function M.RequestSheetFrom(rawName)
  local c = M.Channel()
  if not c then
    Z.Print("No group to ask — solo has no sheet source.")
    return
  end
  local name = M.StripPlayerLink(rawName)
  if not name or name == "" then
    Z.Print("Usage: /zl sync <name>")
    return
  end
  send("SHEET_REQ:" .. name, c)
  Z.Print("Sheet requested from " .. name .. ".")
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

-- Shared chat fan-out for ALL roll traffic (live, sim, rehearsal):
-- master loot in raid -> RAID (RAID_WARNING when warn=true), master
-- loot in party -> PARTY, everything else (solo, group/need/greed,
-- sim echoes) -> local chat frame only (the ZugLoot log). Callers never
-- touch SendChatMessage directly: one router, one channel policy.
-- echo=true marks ML-local fake traffic (sim/rehearsal rolls print on
-- the ML's own frame even in a group — the group never sees fakes).
function M.Say(msg, warn, echo)
  if echo or localLoot() then Z.Print(msg) return end
  if Z.SRSecurity and Z.SRSecurity.IsInRaid and Z.SRSecurity.IsInRaid() then
    if SendChatMessage then
      SendChatMessage(tostring(msg), warn and "RAID_WARNING" or "RAID")
    end
  elseif Z.SRSecurity and Z.SRSecurity.IsInGroup and Z.SRSecurity.IsInGroup() then
    -- No raid warnings in a party: plain party message instead.
    if SendChatMessage then SendChatMessage(tostring(msg), "PARTY") end
  else
    Z.Print(msg)
  end
end

-- Group-aware chat for roll traffic. Master loot in raid -> RAID /
-- RAID_WARNING, master loot in party -> PARTY, everything else (solo,
-- group/need/greed etc.) -> local chat frame (Z.Print).
function M.SayGroup(msg)
  M.Say(msg, false, false)
end

function M.WarnGroup(msg)
  M.Say(msg, true, false)
end

function M.ApplyReceivedSheet(_ver, raidID, payload, sender)
  -- A sheet landed: cancel any pending leader reply (the ML answered
  -- first — the group must never get two competing sheets).
  if Z.SRSecurity and Z.SRSecurity.NoteSheetArrived then
    Z.SRSecurity.NoteSheetArrived()
  end
  -- SECURITY: only ML or raid leader/assistant may push sheets.
  if not Z.SRSecurity.CanAcceptFrom(sender) then
    Z.Print("Ignored sheet from " .. tostring(sender) .. " (not ML/leader).")
    return
  end
  local sheet, err = Z.SRImport.DeserializeSheet(payload)
  if not sheet then Z.Print("Sheet import failed: " .. tostring(err)) return end
  -- Envelope (META line) carries the raid identity; the message raidID
  -- and the trusted sender fill gaps it leaves (legacy senders send no
  -- META at all). Sender always wins: we know who pushed it.
  sheet.meta = sheet.meta or {}
  if not sheet.meta.raidID or sheet.meta.raidID == "" then
    sheet.meta.raidID = raidID
  end
  sheet.meta.importedBy = sender
  -- Stale guard: same raid compares content revision (importedAt from
  -- the META envelope), not the raidID string — a re-sent update keeps
  -- its raidID but carries a NEWER stamp and must apply. Refuse BEFORE
  -- archiving (archiving first would snapshot progress, then drop it).
  if Z.SRImport and Z.SRImport.SheetIsStale
      and Z.SRImport.SheetIsStale(Z.DB and Z.DB.sheet, sheet) then
    Z.Print("Ignored stale sheet " .. tostring(sheet.meta.raidID)
      .. " (a newer update is already applied).")
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
end

function M.OnEvent(event, a1, a2, a3, a4)
  if event == "CHAT_MSG_ADDON" then
    local prefix, msg, channel, sender = a1, a2, a3, a4
    if prefix ~= Z.PREFIX then return end
    M.OnMessage(tostring(msg or ""), sender, channel)
  end
end

function M.OnMessage(msg, sender, channel)
  local tag = string.match(msg, "^(%S+):")
  -- Sheet request: answer ONLY when entitled, ML first. The ML answers
  -- at once when they hold a sheet; the raid leader/assistant answers
  -- after a short delay — but ONLY when no ML sheet exists in the group
  -- (no ML in the group, ML has no sheet/addon). The delay lets the ML's
  -- answer arrive first; a SHEET landing meanwhile cancels the leader's
  -- reply so the client never gets two competing sheets. Nobody else
  -- answers, ever — receivers only trust ML/leader sheets (CanAcceptFrom).
  if msg == "SHEET_REQ" or tag == "SHEET_REQ" then
    -- Targeted form "SHEET_REQ:<name>": only answer when WE are the
    -- named player (exact name match after link-strip). Anyone may be
    -- asked (imports are open); trust is enforced on RECEIVE.
    local target = string.match(msg, "^SHEET_REQ:(.+)$")
    if target then
      local me = UnitName and UnitName("player") or nil
      if not me or Z.Comm.StripPlayerLink(target) ~= me then return end
    end
    if Z.SRSecurity and Z.SRSecurity.ShouldAnswerSheetReq then
      Z.SRSecurity.ShouldAnswerSheetReq(sender, target and true or false, channel)
    end
    return
  end
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
  if string.sub(msg, 1, 6) == "AWARD:" then
    local itemID, winner = string.match(msg, "AWARD:(%d+):(.+)$")
    if itemID and Z.DB and Z.DB.sheet and Z.SRData then
      -- Sheet log floor (sender-side parity): a known below-rare award
      -- leaves no won mark. Unknown quality proceeds (unclassifiable).
      local q = nil
      if GetItemInfo then
        local _, _, qq = GetItemInfo(tonumber(itemID))
        q = qq
      end
      Z.SRData.MarkWon(Z.DB.sheet, tonumber(itemID), winner, q)
      if Z.MainWindow then Z.MainWindow.Refresh() end
      if Z.SRView then Z.SRView.Refresh() end
    end
    return
  end
  if string.sub(msg, 1, 8) == "SHEET_C:" then
    local ver, raidID, seqStr, totStr, chunk = string.match(msg, "^SHEET_C:(%d+):([^:]+):(%d+):(%d+):(.*)$")
    local seq = tonumber(seqStr)
    local total = tonumber(totStr)
    if not (seq and total and chunk) then
      Z.Print("Bad sheet chunk from " .. tostring(sender))
      return
    end
    if not Z.SRSecurity.CanAcceptFrom(sender) then
      Z.Print("Ignored sheet chunk from " .. tostring(sender) .. " (not ML/leader).")
      return
    end
    local now = (GetTime and GetTime()) or (time and time()) or 0
    M.chunkBuffers = M.chunkBuffers or {}
    local buf = M.chunkBuffers[raidID]
    if not buf or (now - (buf.t or 0) > 15) then
      buf = { total = total, chunks = {}, count = 0, t = now, sender = sender }
      M.chunkBuffers[raidID] = buf
    end
    if not buf.chunks[seq] then
      buf.chunks[seq] = chunk
      buf.count = buf.count + 1
    end
    if buf.count == total then
      local parts = {}
      for i = 1, total do table.insert(parts, buf.chunks[i] or "") end
      local fullPayload = table.concat(parts, "")
      M.chunkBuffers[raidID] = nil
      M.ApplyReceivedSheet(tonumber(ver) or 1, raidID, fullPayload, sender)
    end
    return
  end
  if string.sub(msg, 1, 6) == "SHEET:" then
    local ver, raidID, payload = string.match(msg, "SHEET:(%d+):([^:]+):(.+)$")
    if not payload then Z.Print("Bad sheet message from " .. tostring(sender)) return end
    M.ApplyReceivedSheet(tonumber(ver) or 1, raidID, payload, sender)
    return
  end
end
