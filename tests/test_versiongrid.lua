-- tests/test_versiongrid.lua
-- VersionGrid roster: solo shows only me (no group API touch, no extra
-- client return values leaking into table.insert); raid/party list the
-- group. Regression: this client's name APIs can carry extra returns
-- (cf. UnitExists -> guid); a bare UnitName() as table.insert's last arg
-- propagates them (3-arg insert -> "number expected, got string").
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
dofile("Constants.lua")
dofile("VersionGrid.lua")
local VG = ZugLoot.VersionGrid

ZugLoot.VERSION = "1.0"
local printed = {}
ZugLoot.Print = function(m) table.insert(printed, m) end

-- Grouping knob: "solo" | "party" | "raid".
local grouping = "solo"
ZugLoot.SRSecurity = { IsSolo = function() return grouping == "solo" end }

-- Solo: UnitName carries an extra return on this client (the crash shape).
UnitName = function(unit)
  if unit == "player" then return "SoloPlayer", "EXTRA-GUID-JUNK" end
  return nil
end
GetNumRaidMembers = function() return 0 end
GetNumPartyMembers = nil
GetRaidRosterInfo = nil

-- 1. Solo lists only me — one row, no error from the extra return.
local soloOK, soloNames = pcall(VG.RosterNames)
ok(soloOK, "solo RosterNames does not error")
eq(#(soloNames or {}), 1, "solo shows exactly one row")
eq(soloNames and soloNames[1], "SoloPlayer", "solo row is me")
ok(not string.find(tostring(soloNames and soloNames[1]), "EXTRA"),
  "no extra return leaks into the name")

-- 2. Solo render: me red with no addon seen, green once I answer.
VG.seen = {}
local rows = VG.RenderRows(VG.RosterNames())
eq(#rows, 1, "solo renders one row")
eq(rows[1].color, "RED", "unseen solo self is red (no addon)")
VG.OnVersion("SoloPlayer", "1.0")
eq(VG.ColorFor("SoloPlayer"), "GREEN", "current self is green")

-- 3. Party lists me + members; extra returns still truncated.
grouping = "party"
GetNumPartyMembers = function() return 1 end
local oldUnitName = UnitName
UnitName = function(unit)
  if unit == "player" then return "PartyMe", "JUNK" end
  if unit == "party1" then return "PartyPal", "JUNK" end
  return nil
end
local partyOK, partyNames = pcall(VG.RosterNames)
ok(partyOK, "party RosterNames does not error")
eq(#(partyNames or {}), 2, "party lists me + 1")
eq(partyNames[1], "PartyMe", "party first row is me")
UnitName = oldUnitName
GetNumPartyMembers = nil

-- 4. Raid lists the roster (loc info first return only), solo-shape intact.
grouping = "raid"
GetNumRaidMembers = function() return 2 end
GetRaidRosterInfo = function(i)
  if i == 1 then return "RaidA", 0, 1 end
  if i == 2 then return "RaidB", 0, 1 end
end
local raidOK, raidNames = pcall(VG.RosterNames)
ok(raidOK, "raid RosterNames does not error")
eq(#(raidNames or {}), 2, "raid lists two rows")
GetNumRaidMembers = function() return 0 end
GetRaidRosterInfo = nil

-- 5. Back to solo: only me again (group APIs must not leak rows in).
grouping = "solo"
local backOK, backNames = pcall(VG.RosterNames)
ok(backOK, "solo again does not error")
eq(#(backNames or {}), 1, "solo again shows only me")

return T
