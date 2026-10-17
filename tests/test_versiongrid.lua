-- tests/test_versiongrid.lua
-- VersionGrid: solo shows only me (no group API touch, no extra client
-- return values leaking into table.insert); grid = group first, then
-- SR-sheet players not in the group (grey). Status: GREEN = in group +
-- on sheet, RED = in group + no SR, AMBER = outdated addon, GREY =
-- sheet but not here. Self seeds into seen on Request (solo sends
-- nothing, so the grid must not claim we lack the addon).
-- Regression: this client's name APIs can carry extra returns
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
dofile("SRData.lua")
dofile("VersionGrid.lua")
local VG = ZugLoot.VersionGrid
local SRData = ZugLoot.SRData

ZugLoot.VERSION = "1.0"
local printed = {}
ZugLoot.Print = function(m) table.insert(printed, m) end
ZugLoot.Comm = { RequestVersions = function() end }
ZugLoot.DB = { sheet = nil }

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

-- Sheet with two SR'd players: me + an absentee.
local sheet = SRData.NewSheet()
sheet.items[1001] = { quality = 4, rollers = {
  { name = "SoloPlayer", rolls = 1 },
  { name = "AbsentRaider", rolls = 1 },
} }
ZugLoot.DB.sheet = sheet

-- 1. Solo lists only me — one row, no error from the extra return.
local soloOK, soloNames = pcall(VG.RosterNames)
ok(soloOK, "solo RosterNames does not error")
eq(#(soloNames or {}), 1, "solo shows exactly one row")
eq(soloNames and soloNames[1], "SoloPlayer", "solo row is me")
ok(not string.find(tostring(soloNames and soloNames[1]), "EXTRA"),
  "no extra return leaks into the name")

-- 2. Self seeds on Request: solo sends nothing, grid still knows us.
VG.seen = {}
VG.Request()
ok(VG.seen["SoloPlayer"] ~= nil, "Request seeds self into seen")
eq(VG.seen["SoloPlayer"].version, "1.0", "seeded self version is ours")

-- 3. Statuses: me GREEN (group + sheet), absentee GREY (sheet, not here).
local grid = VG.GridNames()
eq(#grid, 2, "grid = me + 1 sheet absentee")
eq(grid[1].name, "SoloPlayer", "group first")
eq(grid[1].inGroup, true, "me flagged in group")
eq(grid[2].name, "AbsentRaider", "absentee appended")
eq(grid[2].inGroup, false, "absentee flagged out of group")
eq(VG.StatusFor("SoloPlayer", true), "GREEN", "SR'd raider is green")
eq(VG.StatusFor("AbsentRaider", false), "GREY", "sheet absentee is grey")

-- 4. RenderRows keeps name + color + group flag (full-name rectangles).
local rows = VG.RenderRows(VG.GridNames())
eq(#rows, 2, "two rectangles rendered")
eq(rows[1].name, "SoloPlayer", "first rectangle names me fully")
eq(rows[1].color, "GREEN", "my rectangle is green")
eq(rows[2].color, "GREY", "absentee rectangle is grey")

-- 5. In group but NOT on the sheet: RED. Outdated addon: AMBER.
eq(VG.StatusFor("Stranger", true), "RED", "unsheeted raider is red")
VG.OnVersion("SoloPlayer", "0.5")
eq(VG.StatusFor("SoloPlayer", true), "AMBER", "outdated addon beats sheet green")
VG.OnVersion("SoloPlayer", "1.0")
eq(VG.StatusFor("SoloPlayer", true), "GREEN", "current again after update")

-- 6. Party lists me + members; extra returns still truncated.
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

-- 7. Raid lists the roster (loc info first return only).
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

-- 8. Back to solo: only me again (group APIs must not leak rows in).
grouping = "solo"
local backOK, backNames = pcall(VG.RosterNames)
ok(backOK, "solo again does not error")
eq(#(backNames or {}), 1, "solo again shows only me")

-- 9. StreamOf: major.minor of a version; unparseable -> nil.
eq(VG.StreamOf("0.2.0"), "0.2", "stream of 0.2.0 is 0.2")
eq(VG.StreamOf("0.2.7"), "0.2", "patch stays on its stream")
eq(VG.StreamOf("1.0"), "1.0", "two-part version is its own stream")
eq(VG.StreamOf("abc"), nil, "garbage version has no stream")
eq(VG.StreamOf(nil), nil, "nil version has no stream")

-- 10. Stream mismatch warns on the console, once per sender+stream;
-- same-stream (patch) answers stay silent. Ours is "1.0" here.
VG.warned = {}
local before = #printed
VG.OnVersion("StreamStranger", "9.9")
eq(#printed, before + 1, "other stream prints a mismatch warning")
ok(string.find(printed[#printed], "9.9") ~= nil,
  "warning names the other version")
VG.OnVersion("StreamStranger", "9.9")
eq(#printed, before + 1, "repeat from same stream does not re-warn")
VG.OnVersion("StreamOther", "9.9")
eq(#printed, before + 2, "new sender on other stream warns again")
VG.OnVersion("StreamPal", "1.0.3")
eq(#printed, before + 2, "same-stream patch is silent")
VG.OnVersion("Garbled", "???")
eq(#printed, before + 2, "unparseable version is silent")

return T
