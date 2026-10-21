-- tests/test_reset.lua
-- Roll-log reset: DoResetRollLog clears history + won marks but keeps SR data;
-- CanResetRollLog gates solo-open vs ML/leader-only in group.
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
dofile("SRData.lua")
dofile("Resolver.lua")

-- Mock group state (same shape as test_security.lua).
-- Mock group state: ML rigged via GetLootMethod index (RollFor parity).
-- lootId 0 = me, N = raid/party slot N. Leader rank is irrelevant.
local raidMembers, partyMembers = 0, 0
local lootMethod, lootId = nil, nil
local raidRoster = {}
local partyNames = {}

GetNumRaidMembers = function() return raidMembers end
GetNumPartyMembers = function() return partyMembers end
GetLootMethod = function() return lootMethod, lootId end
UnitName = function(unit)
  if unit == "player" or unit == nil then return "SoloPlayer" end
  if type(unit) == "string" then
    local slot = string.match(unit, "^party(%d+)$")
    if slot then return partyNames[tonumber(slot)] end
  end
  return nil
end
GetRaidRosterInfo = function(i)
  local r = raidRoster[i]
  if not r then return nil end
  return r[1], r[2]
end

-- No StaticPopup API outside the client: RequestResetRollLog must take the
-- direct path (still permission-gated).
StaticPopupDialogs = nil
StaticPopup_Show = nil

local printed = {}
ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
ZugLoot.DB = {}
ZugLoot.MainWindow = nil
ZugLoot.SRView = nil

dofile("SRSecurity.lua")
dofile("SRImport.lua")
local SRData = ZugLoot.SRData
local RI = ZugLoot.SRImport

local function makeUsedSheet()
  local s = SRData.NewSheet()
  s.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1, sr_plus = 10 } } }
  s.items[1002] = { quality = 4, rollers = { { name = "Bbb", rolls = 2, sr_plus = nil } } }
  SRData.RecordRolls(s, 1001, { t = 1, mode = "SR", winners = { "Aaa" }, entries = {} })
  SRData.RecordRolls(s, 1001, { t = 2, mode = "SR", winners = { "Aaa" }, entries = {} })
  SRData.RecordRolls(s, 1002, { t = 3, mode = "SIM", winners = { "Bbb" }, entries = {} })
  SRData.MarkWon(s, 1001, "Aaa")
  SRData.MarkWon(s, 1002, "Bbb")
  return s
end

-- 1. DoResetRollLog clears rolls + won, keeps SR entries, reports counts.
ZugLoot.DB = { sheet = makeUsedSheet() }
local c = RI.DoResetRollLog()
eq(c.rolls, 3, "reset reports 3 sessions cleared")
eq(c.won, 2, "reset reports 2 won marks cleared")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 0, "rolls cleared (1001)")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1002), 0, "rolls cleared (1002)")
ok(not SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "won cleared")
eq(#ZugLoot.DB.sheet.items[1001].rollers, 1, "SR rollers kept")
eq(ZugLoot.DB.sheet.items[1001].rollers[1].sr_plus, 10, "SR+ kept")
-- Unreserved stubs are pruned so the sheet returns to imported state:
ZugLoot.DB = { sheet = makeUsedSheet() }
SRData.EnsureUnreserved(ZugLoot.DB.sheet, 7777, 4)
RI.DoResetRollLog()
ok(ZugLoot.DB.sheet.items[7777] == nil, "reset prunes unreserved stubs")
ok(ZugLoot.DB.sheet.items[1001] ~= nil, "reset keeps SR items")

-- 2. No sheet: safe, zero counts.
ZugLoot.DB = {}
local c0 = RI.DoResetRollLog()
eq(c0.rolls, 0, "no sheet: 0 rolls")
eq(c0.won, 0, "no sheet: 0 won")

-- 3. Solo: allowed.
raidMembers, partyMembers = 0, 0
lootMethod, lootId = nil, nil
ok(RI.CanResetRollLog(), "solo can reset")

-- 4. Raid raider (not ML): blocked. ML is slot 7, leader rank on slot 1
-- confers nothing.
raidMembers = 40
raidRoster = {}
for i = 1, 40 do raidRoster[i] = { "Player" .. i, 0 } end
raidRoster[1] = { "Player1", 1 }
lootMethod, lootId = "master", 7
ok(not RI.CanResetRollLog(), "raid raider blocked")

-- 5. Raid ML (index 0): allowed.
lootMethod, lootId = "master", 0
ok(RI.CanResetRollLog(), "raid ML allowed")

-- 6. Raid leader rank WITHOUT the ML index: still blocked.
lootMethod, lootId = "master", 7
ok(not RI.CanResetRollLog(), "raid leader-without-ML blocked")

-- 7. Party ML: allowed; party non-ML: blocked.
raidMembers = 0
raidRoster = {}
partyMembers = 4
partyNames = { "P1", "P2", "P3", "P4" }
lootMethod, lootId = "master", 0
ok(RI.CanResetRollLog(), "party ML allowed")
lootMethod, lootId = "master", 2
ok(not RI.CanResetRollLog(), "party non-ML blocked")

-- 8. RequestResetRollLog without popup API: gated path still applies.
-- Blocked raider gets the denial message and data is untouched.
raidMembers = 40
partyMembers = 0
raidRoster = {}
for i = 1, 40 do raidRoster[i] = { "Player" .. i, 0 } end
lootMethod, lootId = "master", 3 -- ML is Player3, not me
ZugLoot.DB = { sheet = makeUsedSheet() }
printed = {}
RI.RequestResetRollLog()
ok(string.find(printed[#printed], "Only the master looter"), "blocked request denied")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 2, "blocked request leaves data alone")

-- 9. Allowed request (solo) performs the reset directly without popup API.
raidMembers, partyMembers = 0, 0
printed = {}
RI.RequestResetRollLog()
ok(string.find(printed[#printed], "Roll log cleared"), "solo request resets")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 0, "solo request cleared rolls")

-- 10. /zl reset path (ResetWon) shares the gate + core.
raidMembers = 40
partyMembers = 0
raidRoster = {}
for i = 1, 40 do raidRoster[i] = { "Player" .. i, 0 } end
lootMethod, lootId = "master", 3 -- ML is Player3, not me
ZugLoot.DB = { sheet = makeUsedSheet() }
printed = {}
RI.ResetWon()
ok(string.find(printed[#printed], "Only the master looter"), "slash reset blocked for raider")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 2, "slash reset leaves data alone for raider")
lootMethod, lootId = "master", 0
RI.ResetWon()
ok(string.find(printed[#printed], "cleared"), "slash reset works for ML")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 0, "slash reset cleared for ML")
lootMethod, lootId = "master", 7

-- Leave no ML behind: later files run in the same state and most rig
-- their own loot method (nil = solo/group default, like the client
-- with no group). A leaked ("master", id) would force every later
-- award down the master-loot handoff.
lootMethod, lootId = nil, nil

return T
