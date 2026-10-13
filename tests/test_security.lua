-- tests/test_security.lua
-- SRSecurity solo/group gating: solo may load locally but never broadcast;
-- in-group import stays ML/leader-only. Needs mocked WoW group APIs.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else T.pass = T.pass + 1 end
end
local function ok(v, msg)
  if not v then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else T.pass = T.pass + 1 end
end

ZugLoot = {}
dofile("Util.lua")
dofile("ClassColors.lua")

-- Mock group state: upvalues the security module reads via globals.
local raidMembers, partyMembers = 0, 0
local meIsPartyLeader = false
local raidRoster = {} -- { {name, rank} }

GetNumRaidMembers = function() return raidMembers end
GetNumPartyMembers = function() return partyMembers end
IsPartyLeader = function() return meIsPartyLeader end
IsRaidLeader = function() return false end
IsRaidOfficer = function() return false end
GetLootMethod = function() return nil end
GetLootMaster = function() return nil end
UnitName = function() return "SoloPlayer" end
GetRaidRosterInfo = function(i)
  local r = raidRoster[i]
  if not r then return nil end
  return r[1], r[2]
end

dofile("SRSecurity.lua")
dofile("Comm.lua")
local Sec = ZugLoot.SRSecurity
local Comm = ZugLoot.Comm

-- 1. Solo: allowed to import (local preview), never broadcast, no channel.
raidMembers, partyMembers = 0, 0
ok(Sec.IsSolo(), "solo detected")
ok(Sec.CanImport(), "solo can import locally")
ok(not Sec.CanBroadcast(), "solo cannot broadcast")
eq(Comm.Channel(), nil, "solo has no channel")
eq(Sec.RoleLabel(), "Solo (preview)", "solo role label")

-- 2. In raid as plain raider: cannot import or broadcast.
raidMembers = 40
raidRoster = {}
for i = 1, 40 do raidRoster[i] = { "Player" .. i, 0 } end
ok(not Sec.IsSolo(), "raider not solo")
ok(not Sec.CanImport(), "raider cannot import")
ok(not Sec.CanBroadcast(), "raider cannot broadcast")
eq(Comm.Channel(), "RAID", "raid channel")

-- 3. Raid assistant (rank 1) may import + broadcast.
raidRoster[1] = { "SoloPlayer", 1 }
ok(Sec.CanImport(), "assistant can import")
ok(Sec.CanBroadcast(), "assistant can broadcast")

-- 4. Party leader may import + broadcast on PARTY.
raidMembers = 0
raidRoster = {}
partyMembers = 4
meIsPartyLeader = true
ok(not Sec.IsSolo(), "party member not solo")
ok(Sec.CanImport(), "party leader can import")
ok(Sec.CanBroadcast(), "party leader can broadcast")
eq(Comm.Channel(), "PARTY", "party channel")

-- 5. Party non-leader cannot.
meIsPartyLeader = false
ok(not Sec.CanImport(), "party non-leader cannot import")

return T
