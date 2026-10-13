-- ZugLoot/SRSecurity.lua
-- Role checks: ML / raid leader / assistant. Gates imports + sheet broadcasts.
ZugLoot = ZugLoot or {}
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
    -- Party: leader check via party.
    if IsPartyLeader and IsPartyLeader() and player == UnitName("player") then return true end
    return false
  else
    -- Solo: leader of nothing.
    return false
  end
end

function M.AmML() return M.IsML() end
function M.AmLeader() return M.IsLeader() end

-- May this client load a sheet locally (import = parse + store + view/sim)?
-- Solo (out of party/raid) is always allowed: there is no raid to protect
-- and no one to broadcast to; it is preview-only (see CanBroadcast).
-- In a group, only the ML or raid leader/assistant may import.
function M.CanImport()
  if M.IsSolo() then return true end
  return M.AmML() or M.AmLeader()
end

-- May this client push the sheet to the group? Never solo (no channel),
-- otherwise ML or raid leader/assistant only.
function M.CanBroadcast()
  if M.IsSolo() then return false end
  return M.AmML() or M.AmLeader()
end

-- Should we accept a sheet from this sender? Receiver-side guard.
function M.CanAcceptFrom(sender)
  if not sender then return false end
  return M.IsML(sender) or M.IsLeader(sender)
end

function M.RoleLabel()
  if M.IsSolo() then return "Solo (preview)" end
  if M.AmML() then return "Master Looter" end
  if M.AmLeader() then return "Raid Leader" end
  return "Raider"
end
