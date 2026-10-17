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

-- 2. In raid as plain raider: anyone may import (local view), but only
-- ML/leader may broadcast; sync trust stays ML/leader-only.
raidMembers = 40
raidRoster = {}
for i = 1, 40 do raidRoster[i] = { "Player" .. i, 0 } end
ok(not Sec.IsSolo(), "raider not solo")
ok(Sec.CanImport(), "anyone can import locally")
ok(not Sec.CanBroadcast(), "raider cannot broadcast")
eq(Comm.Channel(), "RAID", "raid channel")
ok(not Sec.CanAcceptFrom("Player3"), "plain raider sheet untrusted")

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

-- 5. Party non-leader: may import locally, never broadcast.
meIsPartyLeader = false
ok(Sec.CanImport(), "party non-leader can import locally")
ok(not Sec.CanBroadcast(), "party non-leader cannot broadcast")

-- 5b. Party leader recognition, SELF and REMOTE. Regression: the old
-- code ran IsPartyLeader() (self-only) for every sender, so a real
-- party leader's sheet arrived as "not ML / leader" and was refused.
UnitIsPartyLeader = function(unit)
  if unit == "party1" then return 1 end
  return nil
end
local _partyRosterP = { "PartyMe", "LeadGal" }
UnitName = function(unit)
  if unit == "player" then return "PartyMe" end
  if unit == "party1" then return "LeadGal" end
  return nil
end
GetNumPartyMembers = function() return 1 end
raidMembers = 0
partyMembers = 1
meIsPartyLeader = false
ok(not Sec.IsLeader("PartyMe"), "non-leader self not leader")
ok(Sec.IsLeader("LeadGal"), "remote party leader recognized")
ok(Sec.CanAcceptFrom("LeadGal"), "party leader sheet trusted")
ok(not Sec.CanAcceptFrom("PartyMe"), "plain member sheet refused")
ok(not Sec.CanAcceptFrom("Stranger"), "off-roster name refused")
-- Self-as-leader still works through the no-arg call.
meIsPartyLeader = true
ok(Sec.IsLeader("PartyMe"), "self leader via IsPartyLeader()")
meIsPartyLeader = false
-- Fail closed: no per-unit API means remote leaders are unknowable.
UnitIsPartyLeader = nil
ok(not Sec.IsLeader("LeadGal"), "no unit API: remote leader refused")
ok(not Sec.CanAcceptFrom("LeadGal"), "no unit API: sheet refused")
-- Restore the STOCK mock shapes (5b overrode UnitName/UnitIsPartyLeader
-- with unit-dispatching versions; later sections need the plain ones).
UnitName = function() return "SoloPlayer" end
GetNumPartyMembers = function() return partyMembers end
UnitIsPartyLeader = function(unit) return nil end
-- Restore raid-shaped roster fns (5b overrode the unit/global fns).
GetNumRaidMembers = function() return raidMembers end
GetRaidRosterInfo = function(i)
  local r = raidRoster[i]
  if not r then return nil end
  return r[1], r[2]
end
UnitName = function() return "SoloPlayer" end
UnitIsPartyLeader = function(unit) return nil end

-- 6. SHEET_REQ answer policy: ML answers, leader only when no ML sheet
-- exists, raiders never. Needs sheet + timer + comm shims.
dofile("Timer.lua")
local sent = {}
SendAddonMessage = function(prefix, msg, channel)
  table.insert(sent, { prefix = prefix, msg = msg, channel = channel })
end
ZugLoot.PREFIX = "ZugLoot"
ZugLoot.Timer = ZugLoot.Timer
ZugLoot.Print = function() end
-- Comm/SRSecurity captured `local Z = ZugLoot` at load: Z.DB must live
-- on that same table. Establish it once here (later sections mutate
-- .sheet in place, never rebind).
ZugLoot.DB = { sheet = nil }
ZugLoot.SRImport = { SerializeSheet = function() return "A;1:1" end }
local _meIsML = false
GetLootMethod = function() return "master" end
GetLootMaster = function() return "MasterLou" end
-- Raid of 3: ML present, me plain raider, leader present.
raidMembers = 3
raidRoster = { { "MasterLou", 0 }, { "SoloPlayer", 0 }, { "LeadGal", 2 } }
partyMembers = 0
ZugLoot.DB.sheet = { items = {}, meta = {} }
-- Plain raider WITH a sheet still never answers.
eq(Sec.SheetReqAnswer(), nil, "raider never answers sheetreq")
-- Trust: raider sheet is refused even if one arrived.
ok(not Sec.CanAcceptFrom("SoloPlayer"), "raider sheet untrusted")
ok(Sec.CanAcceptFrom("MasterLou"), "ML sheet trusted")
ok(Sec.CanAcceptFrom("LeadGal"), "leader sheet trusted")
-- ML (by loot master) answers at once.
raidRoster[2] = { "MasterLou", 0 } -- me == ML now via name match below
local oldName = UnitName
UnitName = function() return "MasterLou" end
eq(Sec.SheetReqAnswer(), "ml", "ML answers sheetreq")
UnitName = oldName
-- Leader with ML present defers (nil); ML absent => leader answers.
raidRoster[1] = { "MasterLou", 0 }
raidRoster[2] = { "SoloPlayer", 0 }
raidRoster[3] = { "LeadGal", 2 }
UnitName = function() return "LeadGal" end
eq(Sec.SheetReqAnswer(), nil, "leader defers while ML present")
raidRoster[1] = { "GoneGuy", 0 } -- ML left the raid
raidRoster[2] = { "SoloPlayer", 0 }
eq(Sec.SheetReqAnswer(), "leader", "leader answers when ML absent")
-- Non-master loot: no ML exists, leader answers.
GetLootMethod = function() return "group" end
eq(Sec.SheetReqAnswer(), "leader", "leader answers under group loot")
GetLootMethod = function() return "master" end
-- No sheet held: nobody answers, not even the ML.
ZugLoot.DB.sheet = nil
UnitName = function() return "MasterLou" end
eq(Sec.SheetReqAnswer(), nil, "no sheet: ML stays silent")
UnitName = oldName
-- Leader reply is delayed (timer) and cancelled by an arriving sheet.
ZugLoot.DB.sheet = { items = {}, meta = {} }
local oldName2 = UnitName
UnitName = function() return "LeadGal" end
raidRoster = { { "SoloPlayer", 0 }, { "LeadGal", 2 } }
GetLootMaster = function() return "NobodyHere" end
sent = {}
Comm.OnMessage("SHEET_REQ", "SoloPlayer")
eq(ZugLoot.Timer.Pending(), 1, "leader reply delayed, not instant")
eq(#sent, 0, "nothing sent yet")
Comm.OnMessage("SHEET:1:r1:A;1:1", "MasterLou") -- ML answered first
eq(ZugLoot.Timer.Pending(), 0, "ML sheet cancels leader reply")
ZugLoot.Timer.Update(10)
eq(#sent, 0, "leader never double-sent")
UnitName = oldName2

-- 7. Raid identity survives the broadcast: META envelope carries the
-- raid name + import stamp, the receiver's header shows them (not "—").
-- Needs the real SRImport/SRData (shimmed above) + archive shims.
dofile("SRData.lua")
dofile("SRImport.lua")
local SRData = ZugLoot.SRData
local RI = ZugLoot.SRImport
ZugLoot.RaidArchive = { ArchiveActive = function() end, SyncActive = function() end }
ZugLoot.MainWindow = nil
ZugLoot.SRView = nil
local raidSheet = SRData.NewSheet()
raidSheet.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
raidSheet.meta.raidID = "LeadGal-1234"
raidSheet.meta.raidName = "Molten Core"
raidSheet.meta.importedBy = "LeadGal"
raidSheet.meta.importedAt = 1234
raidSheet.meta.source = "paste"
local wirePayload = RI.SerializeSheet(raidSheet)
ok(string.find(wirePayload, "META;", 1, true) ~= nil, "META envelope serialized")
-- Full receive path through Comm (trusted sender, raid channel).
raidMembers = 3
raidRoster = { { "SoloPlayer", 0 }, { "LeadGal", 2 }, { "Other", 0 } }
partyMembers = 0
GetLootMethod = function() return "master" end
GetLootMaster = function() return "NobodyHere" end
ZugLoot.DB.sheet = nil
Comm.OnMessage("SHEET:1:LeadGal-1234:" .. wirePayload, "LeadGal")
ok(ZugLoot.DB.sheet ~= nil, "sheet received")
eq(ZugLoot.DB.sheet.meta.raidName, "Molten Core", "raid name survives sync")
eq(ZugLoot.DB.sheet.meta.raidID, "LeadGal-1234", "raid id survives sync")
eq(ZugLoot.DB.sheet.meta.importedAt, 1234, "import stamp survives sync")
eq(ZugLoot.DB.sheet.meta.importedBy, "LeadGal", "sender stamped")
ok(ZugLoot.DB.sheet.items[1001] ~= nil, "items survive sync")
-- META escaping: commas in names survive the envelope.
local commaSheet = SRData.NewSheet()
commaSheet.items[7] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
commaSheet.meta.raidName = "Ahn'Qiraj, Temple"
local wireC = RI.SerializeSheet(commaSheet)
local backC = RI.DeserializeSheet(wireC)
eq(backC.meta.raidName, "Ahn'Qiraj, Temple", "comma in raid name survives")
-- Legacy sender (no META line): receiver still stamps id + sender.
ZugLoot.DB.sheet = nil
Comm.OnMessage("SHEET:1:legacy-9:A;1:1", "LeadGal")
ok(ZugLoot.DB.sheet ~= nil, "legacy sheet received")
eq(ZugLoot.DB.sheet.meta.raidID, "legacy-9", "legacy raid id stamped")
eq(ZugLoot.DB.sheet.meta.importedBy, "LeadGal", "legacy sender stamped")

-- 8. Sync updates: same raidID + newer META stamp applies; same raidID +
-- older stamp is refused (never rolls the raid back).
ZugLoot.DB.sheet = nil
Comm.OnMessage("SHEET:1:LeadGal-1234:" .. wirePayload, "LeadGal")
ok(ZugLoot.DB.sheet ~= nil, "base sync lands")
eq(#ZugLoot.DB.sheet.items[1001].rollers, 1, "base content")
-- Build an update: same raid, newer stamp, extra roller.
local updSheet = SRData.NewSheet()
updSheet.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 }, { name = "Bbb", rolls = 1 } } }
updSheet.meta.raidID = "LeadGal-1234"
updSheet.meta.raidName = "Molten Core"
updSheet.meta.importedBy = "LeadGal"
updSheet.meta.importedAt = 9999
updSheet.meta.source = "paste"
Comm.OnMessage("SHEET:1:LeadGal-1234:" .. RI.SerializeSheet(updSheet), "LeadGal")
eq(#ZugLoot.DB.sheet.items[1001].rollers, 2, "sync update applies (keeps id)")
eq(ZugLoot.DB.sheet.meta.raidID, "LeadGal-1234", "sync update keeps raid id")
eq(ZugLoot.DB.sheet.meta.raidName, "Molten Core", "sync update keeps raid name")
-- Stale re-send (older stamp): refused, live update kept.
local staleSheet = SRData.NewSheet()
staleSheet.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
staleSheet.meta.raidID = "LeadGal-1234"
staleSheet.meta.raidName = "Molten Core"
staleSheet.meta.importedBy = "LeadGal"
staleSheet.meta.importedAt = 1234
staleSheet.meta.source = "paste"
Comm.OnMessage("SHEET:1:LeadGal-1234:" .. RI.SerializeSheet(staleSheet), "LeadGal")
eq(#ZugLoot.DB.sheet.items[1001].rollers, 2, "stale sync refused, update kept")

-- 9. Targeted sync (/zl sync <name>): only the named player answers,
-- directly (anyone holding a sheet may answer); trust stays on RECEIVE.
-- (Restore the SRImport shim: section 7 loaded the real module above.)
ZugLoot.SRImport = { SerializeSheet = function() return "A;1:1" end }
UnitName = function() return "SoloPlayer" end
raidMembers = 3
raidRoster = { { "MasterLou", 0 }, { "SoloPlayer", 0 }, { "LeadGal", 2 } }
partyMembers = 0
GetLootMethod = function() return "master" end
GetLootMaster = function() return "MasterLou" end
ZugLoot.DB.sheet = { items = {}, meta = {} }
-- Link-strip: color-coded [Name] links reduce to bare names.
eq(Comm.StripPlayerLink("|cFFF58CBASoloPlayer|r"), "SoloPlayer", "color link stripped")
eq(Comm.StripPlayerLink("|cFFF58CBA|Hplayer:SoloPlayer|h[SoloPlayer]|h|r"), "SoloPlayer", "player link stripped")
eq(Comm.StripPlayerLink("SoloPlayer"), "SoloPlayer", "bare name passes through")
-- Requester side: targeted request goes out addressed.
sent = {}
Comm.RequestSheetFrom("|cFFF58CBA|Hplayer:LeadGal|h[LeadGal]|h|r")
eq(#sent, 1, "targeted request sent")
ok(string.find(sent[1].msg, "SHEET_REQ:LeadGal", 1, true) ~= nil, "request addressed to LeadGal")
Comm.RequestSheetFrom("")
eq(#sent, 1, "empty name sends nothing (usage)")
-- Answer side (as LeadGal): targeted request answered directly even
-- though LeadGal is not ML and the ML is present (role policy bypass).
sent = {}
UnitName = function() return "LeadGal" end
Comm.OnMessage("SHEET_REQ:LeadGal", "SoloPlayer")
eq(#sent, 1, "named player answers directly")
ok(string.find(sent[1].msg, "SHEET:", 1, true) ~= nil, "answer is a sheet")
-- Wrong name: silence (not us, don't answer).
sent = {}
Comm.OnMessage("SHEET_REQ:SomebodyElse", "SoloPlayer")
eq(#sent, 0, "wrong name stays silent")
-- No sheet held: silence even when named.
ZugLoot.DB.sheet = nil
sent = {}
Comm.OnMessage("SHEET_REQ:LeadGal", "SoloPlayer")
eq(#sent, 0, "sheetless named player stays silent")
UnitName = oldName

return T
