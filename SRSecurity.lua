-- ZugLoot/SRSecurity.lua
-- Role checks: ML / raid leader / assistant. Gates imports + sheet broadcasts.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
ZugLoot.SRSecurity = M

function M.IsInRaid()
  if GetNumRaidMembers and GetNumRaidMembers() > 0 then return true end
  return false
end

function M.IsInParty()
  if GetNumPartyMembers and GetNumPartyMembers() > 0 then return true end
  return false
end

function M.IsInGroup()
  return M.IsInRaid() or M.IsInParty()
end

-- Out of party/raid (solo): no one to broadcast to, but local
-- preview/sim must still work (see CanImport/CanBroadcast).
function M.IsSolo()
  return not M.IsInGroup()
end

function M.LootMethod()
  if GetLootMethod then return GetLootMethod() end
  return nil
end

function M.IsML(player)
  player = player or (UnitName and UnitName("player"))
  if not player then return false end
  -- Master loot: compare against loot master.
  if M.LootMethod() == "master" and GetLootMaster then
    local ml = GetLootMaster()
    if ml and ml == player then return true end
  end
  -- Fallback: raid leader with master loot intent also counts for import rights
  -- only via IsLeader; IsML stays strict.
  return false
end

function M.IsLeader(player)
  player = player or (UnitName and UnitName("player"))
  if M.IsInRaid() then
    if IsRaidLeader and IsRaidLeader() and player == UnitName("player") then return true end
    if IsRaidOfficer and IsRaidOfficer() and player == UnitName("player") then return true end
    -- Remote player check: scan roster for leader/assistant flags.
    if GetNumRaidMembers and GetRaidRosterInfo then
      for i = 1, GetNumRaidMembers() do
        local name, rank = GetRaidRosterInfo(i)
        if name == player and rank and rank >= 1 then return true end
      end
    end
    return false
  elseif M.IsInParty() then
    -- Party: self check via the no-arg client call, REMOTE senders via
    -- per-unit scan (IsPartyLeader() only ever answers for "player" —
    -- the old code compared every sender against it, so a real party
    -- leader's sheet was refused as "not ML / leader").
    local me = UnitName and UnitName("player") or nil
    if player == me then
      if IsPartyLeader and IsPartyLeader() then return true end
      return false
    end
    if UnitIsPartyLeader then
      if UnitIsPartyLeader("player") == 1 and me == player then return true end
      if GetNumPartyMembers and UnitName then
        for i = 1, GetNumPartyMembers() do
          local n = UnitName("party" .. i)
          if n == player then
            local ok, v = pcall(UnitIsPartyLeader, "party" .. i)
            if ok and (v == 1 or v == true) then return true end
            return false
          end
        end
      end
      return false
    end
    -- No per-unit API: only the group leader could have sent... unknown.
    -- Refuse (fail closed) — trust must be positive, never assumed.
    return false
  else
    -- Solo: leader of nothing.
    return false
  end
end

function M.AmML() return M.IsML() end
function M.AmLeader() return M.IsLeader() end

-- May this client load a sheet locally (import = parse + store + view/sim)?
-- ALWAYS: anyone can import for their own view (raiders want to see the
-- sheet too). Importing never pushes anything (see CanBroadcast) and
-- never overwrites trust: synced sheets still only come from ML/leader
-- (see CanAcceptFrom). Kept as a function (not a constant) so callers
-- and tests keep working.
function M.CanImport()
  return true
end

-- May this client push the sheet to the group? Never solo (no channel),
-- otherwise ML or raid leader/assistant only.
function M.CanBroadcast()
  if M.IsSolo() then return false end
  return M.AmML() or M.AmLeader()
end

-- Should we accept a sheet from this sender? Receiver-side guard.
-- ONLY the master looter or the raid leader/assistant — never anyone
-- else, no matter what the message claims.
function M.CanAcceptFrom(sender)
  if not sender then return false end
  return M.IsML(sender) or M.IsLeader(sender)
end

-- Do we hold a sheet worth answering a SHEET_REQ with? Any loaded sheet
-- counts (imported or received — both passed the trust rules on the way
-- in, so re-serving them is safe).
function M.AnySheet()
  return Z.DB and Z.DB.sheet or nil
end

-- Name of the group's master looter (nil when loot isn't master loot or
-- the client can't tell). The requester never needs this — the answer
-- side uses it to decide whether the ML exists at all.
function M.MasterLooterName()
  if M.LootMethod() ~= "master" then return nil end
  if GetLootMaster then
    local ml = GetLootMaster()
    if ml and ml ~= "" then return ml end
  end
  return nil
end

-- SHEET_REQ answer policy (called on every group member that hears the
-- request; Comm routes here). Priority: the ML answers at once when they
-- hold a sheet. The raid leader/assistant answers after a short delay,
-- but ONLY when no ML sheet exists to wait for (no master loot, no ML
-- name visible, or the ML isn't in the group — i.e. ML can't answer).
-- The delay gives the ML's broadcast time to land; a SHEET arriving
-- meanwhile cancels the pending leader reply (see Comm SHEET handler).
-- Returns "ml" / "leader" / nil (pure decision, testable); the
-- Comm-side wrapper below performs the send.
function M.SheetReqAnswer()
  if M.IsSolo() then return nil end
  if M.AnySheet() == nil then return nil end -- nothing to share
  if M.AmML() then return "ml" end
  if not M.AmLeader() then return nil end -- raiders never answer
  -- Leader path: answer only when the ML cannot (no master loot, or the
  -- ML is unknown/absent so no ML answer can be expected).
  local ml = M.MasterLooterName()
  if ml == nil then return "leader" end
  local me = UnitName and UnitName("player") or nil
  if ml == me then return "ml" end -- ML by name, API missed the flag
  -- An ML exists somewhere: is THEY here? Absent ML => leader answers.
  if M.IsInRaid() then
    if GetNumRaidMembers and GetRaidRosterInfo then
      for i = 1, GetNumRaidMembers() do
        local name = GetRaidRosterInfo(i)
        if name == ml then return nil end -- ML present: defer to them
      end
    end
    return "leader"
  end
  if M.IsInParty() then
    if GetNumPartyMembers and UnitName then
      for i = 1, GetNumPartyMembers() do
        local n = UnitName("party" .. i)
        if n == ml then return nil end -- ML present: defer to them
      end
    end
    return "leader"
  end
  return nil
end

M._pendingSheetReply = nil -- leader-delayed reply handle (Timer)

-- Comm calls this on SHEET_REQ. Sends at once (ML) or after the leader
-- delay; prints what happened so the requester sees who answered.
-- targeted = true for "/zl sync <name>" requests: the named player
-- answers DIRECTLY when they hold a sheet (anyone may hold one) — no
-- role check, no delay. Trust stays on RECEIVE (CanAcceptFrom).
function M.ShouldAnswerSheetReq(requester, targeted)
  if targeted then
    if M.AnySheet() == nil then return nil end
    M.AnswerSheetReq("direct")
    return "direct"
  end
  local role = M.SheetReqAnswer()
  if role == "ml" then
    M.AnswerSheetReq("ml")
  elseif role == "leader" then
    -- Delay the leader reply; cancel any earlier pending one first.
    if Z.Timer and Z.Timer.Cancel and M._pendingSheetReply then
      Z.Timer.Cancel(M._pendingSheetReply)
    end
    if Z.Timer and Z.Timer.After then
      M._pendingSheetReply = Z.Timer.After(5, function()
        M._pendingSheetReply = nil
        M.AnswerSheetReq("leader")
      end)
    else
      M.AnswerSheetReq("leader")
    end
  end
  return role
end

-- Perform the approved answer: broadcast our sheet to the group.
-- role "direct" = named /zl sync answer (no role needed, sheet only).
function M.AnswerSheetReq(role)
  local sheet = M.AnySheet()
  if not sheet then return false end
  if role ~= "ml" and role ~= "leader" and role ~= "direct" then return false end
  if Z.Comm and Z.Comm.BroadcastSheet then
    local raidID = sheet.meta and sheet.meta.raidID or "sheet"
    Z.Comm.BroadcastSheet(sheet, raidID)
    local me = (UnitName and UnitName("player")) or "?"
    Z.Print("Sheet sent to the group by " .. tostring(me)
      .. " (" .. tostring(role) .. ").")
    return true
  end
  return false
end

-- A sheet landed (ours or anyone's): a pending leader reply is now
-- redundant — cancel it so the group never gets two competing sheets.
function M.NoteSheetArrived()
  if Z.Timer and Z.Timer.Cancel and M._pendingSheetReply then
    Z.Timer.Cancel(M._pendingSheetReply)
    M._pendingSheetReply = nil
  end
end

function M.RoleLabel()
  if M.IsSolo() then return "Solo (preview)" end
  if M.AmML() then return "Master Looter" end
  if M.AmLeader() then return "Raid Leader" end
  return "Raider"
end
