-- tests/test_dropsync.lua
-- Drop sync: when the ML records rolls/won on the sheet, the raid sees
-- the same sheet. Roll sessions broadcast live at finish (ROLLLOG);
-- won marks ride AWARD; full history (sessions + won) rides every SHEET
-- sync (WON + ROLLH lines). MTU discipline holds throughout.
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
dofile("ClassColors.lua")
dofile("SRData.lua")
dofile("Resolver.lua")
dofile("Timer.lua")

ZugLoot.Caps = ZugLoot.Caps or { SR = 100, MS = 100, OS = 99, TMOG = 98 }
local printed = {}
ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
ZugLoot.DropLog = { Add = function() end }
ZugLoot.MainWindow = nil
ZugLoot.SRView = nil
time = time or os.time
GetTime = GetTime or os.time

local grouping = "raid"
ZugLoot.SRSecurity = {
  IsInRaid = function() return grouping == "raid" end,
  IsInParty = function() return grouping == "party" end,
  IsInGroup = function() return grouping ~= "solo" end,
  IsSolo = function() return grouping == "solo" end,
  AmML = function() return true end,
  CanBroadcast = function() return true end,
  CanAcceptFrom = function(sender) return sender == "MasterLou" end,
}
UnitName = function() return "MasterLou" end

local sent = {}
SendAddonMessage = function(prefix, msg, channel)
  if string.len(msg) > 254 then
    error("MTU VIOLATION: " .. string.len(msg) .. " bytes: " .. string.sub(msg, 1, 60))
  end
  table.insert(sent, { prefix = prefix, msg = msg, channel = channel })
end

ZugLoot.RaidArchive = { ArchiveActive = function() end, SyncActive = function() end }
dofile("SRImport.lua")
dofile("Comm.lua")
dofile("MasterLootUI.lua")
local Comm = ZugLoot.Comm
local SRData = ZugLoot.SRData
local RI = ZugLoot.SRImport
local ML = ZugLoot.MasterLootUI
SendChatMessage = function(msg, chan) table.insert(printed, "[" .. tostring(chan) .. "] " .. tostring(msg)) end

local function makeSheet()
  local s = SRData.NewSheet()
  s.items[1001] = { quality = 4, rollers = {
    { name = "Aaa", rolls = 1, sr_plus = 10 },
    { name = "Bbb", rolls = 1, sr_plus = nil },
  } }
  s.meta = { raidID = "R1", raidName = "Molten Core", importedBy = "MasterLou",
    importedAt = 1000, source = "paste" }
  return s
end

local function makeSession()
  return { t = 1234, mode = "SR", winners = { "Aaa" }, entries = {
    { name = "Aaa", base = 90, effective = 100, rollType = "SR", sr_plus = 10 },
    { name = "Bbb", base = 80, effective = 80, rollType = "MS", sr_plus = 0,
      missroll = nil, excludedWon = nil, overCap = nil },
  } }
end

-- 1. Session encode/decode round-trip (unit level).
local tail = RI.EncodeSession(1001, makeSession())
ok(tail ~= nil, "session encodes")
ok(not string.find(tail, "|", 1, true), "session tail has no bare pipe")
local rid, back = RI.DecodeSession(tail)
eq(rid, 1001, "session item id decodes")
eq(back.t, 1234, "session time decodes")
eq(back.mode, "SR", "session mode decodes")
eq(#back.winners, 1, "session winners decode")
eq(back.winners[1], "Aaa", "session winner decodes")
eq(#back.entries, 2, "session entries decode")
eq(back.entries[1].name, "Aaa", "entry name decodes")
eq(back.entries[1].effective, 100, "entry effective decodes")
eq(back.entries[1].rollType, "SR", "entry kind decodes")
eq(back.entries[1].sr_plus, 10, "entry sr+ decodes")
eq(back.entries[2].rollType, "MS", "second entry kind decodes")
ok(RI.DecodeSession("garbage") == nil, "malformed tail refused")
ok(RI.DecodeSession("abc,1,SR,-") == nil, "non-numeric item refused")

-- 2. Full sheet round-trip carries drops (sessions + won).
local s = makeSheet()
SRData.RecordRolls(s, 1001, makeSession())
SRData.MarkWon(s, 1001, "Aaa", 4)
local wire = RI.SerializeSheet(s)
ok(string.find(wire, "WON;", 1, true) ~= nil, "WON line serialized")
ok(string.find(wire, "ROLLH;", 1, true) ~= nil, "ROLLH line serialized")
local s2, serr = SRData.ParseLineFormat((string.gsub(wire, "|", "\n")))
ok(s2 ~= nil, "wire lines parse: " .. tostring(serr))
ok(SRData.HasWon(s2, 1001, "Aaa"), "won mark survives sync")
eq(SRData.RollCount(s2, 1001), 1, "session survives sync")
local rs = SRData.GetRolls(s2, 1001)[1]
eq(rs.winners[1], "Aaa", "synced session winner")
eq(#rs.entries, 2, "synced session entries")
eq(rs.entries[1].effective, 100, "synced entry effective")
eq(rs.entries[1].rollType, "SR", "synced entry kind")
-- Hand-written collision guard: players named Won/Rollh/Unsr still parse
-- as players (their reservations are never eaten by the wire heads).
-- The bare-id trap: Rollh;1001,1002,1003,1004 is four reservations —
-- field 3 is numeric, genuine session modes always contain a letter.
local ps, perr = SRData.ParseLineFormat("Won;1001:1\nRollh;1001,1002,1003,1004\nUnsr;1001:1\n")
ok(ps ~= nil, "name collision parses: " .. tostring(perr))
eq(#SRData.GetRollers(ps, 1001), 3, "players Won/Rollh/Unsr share item 1001")
eq(#SRData.GetRollers(ps, 1004), 1, "Rollh bare-id tail intact")
eq(SRData.GetRollers(ps, 1004)[1].name, "Rollh", "Rollh bare ids named")
ok(not SRData.HasWon(ps, 1001, "Won"), "no phantom won mark")
eq(SRData.RollCount(ps, 1001), 0, "no phantom session")
ok(ps.items[1001] == nil or ps.items[1001].unsr ~= true, "no phantom stub")

-- 3. ROLLLOG live path: ML records a finish, raider applies it.
sent = {}
Comm.BroadcastRollSession(s, 1001, makeSession())
ok(#sent >= 1, "session broadcast sends")
ok(string.sub(sent[1].msg, 1, 8) == "ROLLLOG:", "single-packet session message")
-- Raider side: same raid, trusted sender.
local rs2 = makeSheet()
ZugLoot.DB = { sheet = rs2 }
Comm.OnMessage(sent[1].msg, "MasterLou")
eq(SRData.RollCount(rs2, 1001), 1, "raider appends the session")
eq(SRData.GetRolls(rs2, 1001)[1].winners[1], "Aaa", "raider sees the winner")
eq(SRData.GetRolls(rs2, 1001)[1].entries[2].name, "Bbb", "raider sees every roll")
-- Wrong raid: ignored.
local other = makeSheet()
other.meta.raidID = "R2"
ZugLoot.DB = { sheet = other }
Comm.OnMessage(sent[1].msg, "MasterLou")
eq(SRData.RollCount(other, 1001), 0, "other-raid sheet untouched")
-- Untrusted sender: ignored with the usual message.
ZugLoot.DB = { sheet = rs2 }
printed = {}
Comm.OnMessage(sent[1].msg, "RandomRaider")
eq(SRData.RollCount(rs2, 1001), 1, "untrusted session refused (no double-append)")
ok(string.find(printed[#printed] or "", "not ML/leader", 1, true) ~= nil, "untrusted refusal explains itself")
-- Solo: nothing goes on the wire.
grouping = "solo"
sent = {}
Comm.BroadcastRollSession(s, 1001, makeSession())
eq(#sent, 0, "solo broadcasts nothing")
grouping = "raid"
-- Non-broadcaster (raider client recording locally): nothing sent.
ZugLoot.SRSecurity.CanBroadcast = function() return false end
sent = {}
Comm.BroadcastRollSession(s, 1001, makeSession())
eq(#sent, 0, "non-ML records locally only")
ZugLoot.SRSecurity.CanBroadcast = function() return true end

-- 4. Big session chunks + reassembles within MTU.
local big = { t = 2000, mode = "SR", winners = { "Winner1" }, entries = {} }
for i = 1, 30 do
  table.insert(big.entries, { name = "Raider" .. i, base = i,
    effective = i, rollType = (i % 2 == 0) and "MS" or "SR", sr_plus = i })
end
sent = {}
Comm.BroadcastRollSession(s, 1001, big)
ok(#sent > 1, "big session chunked")
for i = 1, #sent do
  ok(string.len(sent[i].msg) <= 254, "chunk " .. i .. " within MTU")
  ok(string.sub(sent[i].msg, 1, 10) == "ROLLLOG_C:", "chunk header")
end
local rs3 = makeSheet()
ZugLoot.DB = { sheet = rs3 }
for i = 1, #sent do Comm.OnMessage(sent[i].msg, "MasterLou") end
eq(SRData.RollCount(rs3, 1001), 1, "chunked session reassembled")
eq(#SRData.GetRolls(rs3, 1001)[1].entries, 30, "all 30 rolls land")

-- 5. Finish-time trigger: recording a session pushes it to the raid.
local rec = makeSheet()
ZugLoot.DB = { sheet = rec }
local link1001 = "|cffa335ee|Hitem:1001:::::::::::|h[Eye of Divinity]|h|r"
local roll = { itemID = 1001, itemLink = link1001, mode = "SR", rolls = {} }
local res = ZugLoot.Resolver.ResolveItem(rec, 1001,
  { { name = "Aaa", roll = 90, min = 1, max = 100 },
    { name = "Bbb", roll = 80, min = 1, max = 100 } }, {})
sent = {}
ML.AnnounceResult(roll, res)
eq(SRData.RollCount(rec, 1001), 1, "finish records the session")
ok(#sent >= 1, "finish pushes the session to the raid")
ok(string.sub(sent[1].msg, 1, 8) == "ROLLLOG:", "push is a session message")
-- ...and a raider on the same raid lands it on their sheet.
local follower = makeSheet()
ZugLoot.DB = { sheet = follower }
for i = 1, #sent do Comm.OnMessage(sent[i].msg, "MasterLou") end
eq(SRData.RollCount(follower, 1001), 1, "follower records what was rolled")
eq(SRData.GetRolls(follower, 1001)[1].winners[1], "Aaa", "follower sees the winner")

-- 6. Redelivered sessions never duplicate (double event frame, retry).
local dup = makeSheet()
ZugLoot.DB = { sheet = dup }
Comm.OnMessage(sent[1].msg, "MasterLou")
Comm.OnMessage(sent[1].msg, "MasterLou")
eq(SRData.RollCount(dup, 1001), 1, "redelivery does not stack a duplicate")
-- ...while a genuinely new session still appends.
local sess2 = { t = 9999, mode = "SR", winners = { "Bbb" }, entries = {
  { name = "Bbb", base = 70, effective = 70, rollType = "MS", sr_plus = 0 },
} }
Comm.BroadcastRollSession(dup, 1001, sess2)
Comm.OnMessage(sent[#sent].msg, "MasterLou")
eq(SRData.RollCount(dup, 1001), 2, "distinct session still appends")

-- 7. Non-SR items cross to raiders: stub item + session + won mark.
local prog = makeSheet()
prog.items[2002] = nil
SRData.EnsureUnreserved(prog, 2002, 4)
local stubSess = { t = 2222, mode = "SR", winners = { "Ccc" }, entries = {
  { name = "Ccc", base = 55, effective = 55, rollType = "MS", sr_plus = 0 },
} }
SRData.RecordRolls(prog, 2002, stubSess)
SRData.MarkWon(prog, 2002, "Ccc", 4)
-- Live delta path: stub materializes so the session has a card.
local rsStub = makeSheet()
ZugLoot.DB = { sheet = rsStub }
sent = {}
Comm.BroadcastRollSession(prog, 2002, stubSess)
for i = 1, #sent do Comm.OnMessage(sent[i].msg, "MasterLou") end
ok(rsStub.items[2002] ~= nil, "stub item materializes on the raider")
ok(rsStub.items[2002].unsr == true, "stub flagged unreserved")
eq(SRData.RollCount(rsStub, 2002), 1, "stub session lands")
-- Full sheet path: stub survives serialize with its quality.
local wireU = RI.SerializeSheet(prog)
ok(string.find(wireU, "UNSR;", 1, true) ~= nil, "UNSR line serialized")
local backU, berrU = SRData.ParseLineFormat((string.gsub(wireU, "|", "\n")))
ok(backU ~= nil, "stub wire parses: " .. tostring(berrU))
ok(backU.items[2002] ~= nil and backU.items[2002].unsr == true, "stub survives sync")
eq(backU.items[2002].quality, 4, "stub quality survives sync")
ok(SRData.HasWon(backU, 2002, "Ccc"), "stub won mark survives sync")
eq(SRData.RollCount(backU, 2002), 1, "stub session survives sync")
-- Hand-written collision guard: a player named Unsr keeps her line
-- (colon-count form is player syntax; stubs need the :q marker).
local pu, perrU = SRData.ParseLineFormat("Unsr;1001:1\n")
ok(pu ~= nil, "Unsr name parses: " .. tostring(perrU))
eq(#SRData.GetRollers(pu, 1001), 1, "player Unsr keeps her reservation")
ok(pu.items[1001].unsr ~= true, "Unsr line makes no stub")

-- 8. Full SHEET sync carries drops end to end (late joiner path).
local full = makeSheet()
SRData.RecordRolls(full, 1001, makeSession())
SRData.MarkWon(full, 1001, "Aaa", 4)
sent = {}
Comm.lastBroadcastTime = 0
Comm.BroadcastSheet(full, "R1")
ok(#sent >= 1, "sheet broadcast sends")
local late = SRData.NewSheet()
ZugLoot.DB = { sheet = late }
for i = 1, #sent do Comm.OnMessage(sent[i].msg, "MasterLou") end
ok(ZugLoot.DB.sheet ~= nil and ZugLoot.DB.sheet ~= late, "late joiner lands the sheet")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa"), "late joiner sees who won")
eq(SRData.RollCount(ZugLoot.DB.sheet, 1001), 1, "late joiner sees what was rolled")
eq(SRData.GetRolls(ZugLoot.DB.sheet, 1001)[1].winners[1], "Aaa", "late joiner sees the winner")

return T
