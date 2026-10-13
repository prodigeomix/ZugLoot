-- tests/test_raids.lua
-- RaidArchive: snapshots isolate live data, dedupe by raidID, cap enforced,
-- restore round-trips won/rolls, ApplySheet archives the outgoing raid.
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
dofile("RaidArchive.lua")
local SRData = ZugLoot.SRData
local RA = ZugLoot.RaidArchive

local function makeSheet(raidID, by, raidName)
  local s = SRData.NewSheet()
  s.meta = { raidID = raidID, raidName = raidName, importedAt = 1000, importedBy = by or "ML", source = "paste" }
  s.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1, sr_plus = 10 } } }
  s.items[1002] = { quality = 4, rollers = { { name = "Bbb", rolls = 2, sr_plus = nil } } }
  return s
end

-- 1. Snapshot records summary counts.
local s1 = makeSheet("R1")
SRData.RecordRolls(s1, 1001, { t = 1, mode = "SR", winners = { "Aaa" }, entries = {} })
SRData.MarkWon(s1, 1001, "Aaa")
local snap = RA.SnapshotSheet(s1, 2000)
eq(snap.raidID, "R1", "snapshot raid id")
eq(snap.importedBy, "ML", "snapshot importer")
eq(snap.nItems, 2, "snapshot item count")
eq(snap.nRollers, 2, "snapshot roller count")
eq(snap.nSessions, 1, "snapshot session count")
eq(snap.nWon, 1, "snapshot won count")
eq(snap.archivedAt, 2000, "snapshot archive time")
-- raid name flows into snapshot + rows (nil when the sheet has none):
local sNamed = makeSheet("RN", "ML", "Onyxia's Lair")
local snapNamed = RA.SnapshotSheet(sNamed, 2000)
eq(snapNamed.raidName, "Onyxia's Lair", "snapshot carries raid name")
ok(snap.raidName == nil, "snapshot raid name nil when unknown")

-- 2. Snapshot is isolated: later live edits don't leak in.
s1.items[1003] = { quality = 4, rollers = {} }
SRData.MarkWon(s1, 1002, "Bbb")
eq(snap.nItems, 2, "snapshot frozen (items)")
eq(snap.nWon, 1, "snapshot frozen (won)")
ok(snap.data.items[1003] == nil, "snapshot data frozen")

-- 3. ArchiveActive pushes newest-first, dedupes same raidID.
local db = {}
ok(RA.ArchiveActive(db, 2000) == nil, "nothing to archive on empty db")
db.sheet = makeSheet("R1")
RA.ArchiveActive(db, 2000)
eq(#RA.GetArchive(db), 1, "one archived")
db.sheet = makeSheet("R2")
RA.ArchiveActive(db, 2001)
eq(#RA.GetArchive(db), 2, "two archived")
eq(RA.GetArchive(db)[1].raidID, "R2", "newest first")
-- Re-archive R1 (updated progress): replaces, moves to front, no duplicate.
db.sheet = makeSheet("R1")
SRData.RecordRolls(db.sheet, 1001, { t = 9, mode = "SR", winners = {}, entries = {} })
RA.ArchiveActive(db, 2002)
eq(#RA.GetArchive(db), 2, "dedupe keeps two")
eq(RA.GetArchive(db)[1].raidID, "R1", "re-archived raid moves to front")
eq(RA.GetArchive(db)[1].nSessions, 1, "re-archive carries new progress")

-- 4. Cap enforced.
for i = 3, 30 do
  db.sheet = makeSheet("RX" .. i)
  RA.ArchiveActive(db, 2000 + i)
end
eq(#RA.GetArchive(db), RA.MAX_KEPT, "archive capped")
ok(RA.Find(db, "R1") == nil, "oldest evicted past cap")

-- 5. ListSummaries: latest raid at top by import time, with active flag.
db = {}
db.sheet = makeSheet("Rlive")
db.sheet.meta.importedAt = 1000 -- older raid
RA.ArchiveActive(db, 3000)
db.sheet = makeSheet("Rold", "ML", "Molten Core")
db.sheet.meta.importedAt = 2000 -- newer raid (name sorts either way)
RA.ArchiveActive(db, 3001)
local rows = RA.ListSummaries(db)
eq(#rows, 2, "two summaries")
eq(rows[1].raidID, "Rold", "latest raid first by import time")
eq(rows[1].raidName, "Molten Core", "row carries raid name")
-- Rold is live now (we archived Rlive, then set Rold live? no: db.sheet IS Rold)
ok(rows[1].active, "live sheet flagged active")
ok(not rows[2].active, "other not active")
eq(rows[1].raidTime, 2000, "row carries raid time")

-- 5b. Re-archiving an old raid never shuffles it above newer raids.
-- (Archive position changes; ListSummaries order must not.)
db.sheet = makeSheet("Rlive")
db.sheet.meta.importedAt = 1000
RA.ArchiveActive(db, 4000) -- archived NOW, but raid itself is older
local rows5b = RA.ListSummaries(db)
eq(#rows5b, 2, "still two summaries")
eq(rows5b[1].raidID, "Rold", "newer raid stays on top despite re-archive")
eq(rows5b[2].raidID, "Rlive", "re-archived old raid stays below")

-- 6. Restore round-trips won + rolls + items; archive copy stays frozen.
local back, err = RA.RestoreSheet(db, "Rlive")
ok(back ~= nil, "restore ok: " .. tostring(err))
ok(SRData.HasWon(back, 1001, "Aaa") == false, "Rlive had no won marks")
eq(#back.items[1001].rollers, 1, "rollers restored")
-- mutate restored copy, archive unchanged:
back.items[9999] = { quality = 4, rollers = {}, unsr = true }
ok(RA.Find(db, "Rlive").data.items[9999] == nil, "archive frozen after restore")
local miss, merr = RA.RestoreSheet(db, "nope")
ok(miss == nil and merr ~= nil, "unknown raid errors")

-- 7. ApplySheet archives the outgoing raid (integration through SRImport).
ZugLoot.Print = function() end
ZugLoot.DB = { sheet = makeSheet("Rold-live") }
ZugLoot.SRView = nil
ZugLoot.DropLog = nil
ZugLoot.Comm = nil
ZugLoot.SRSecurity = nil -- absent: solo-style local path, no broadcast
ZugLoot.MainWindow = nil
dofile("SRImport.lua")
local fresh = makeSheet("Rnew-live")
ZugLoot.SRImport.ApplySheet(fresh, "paste", "ML2")
eq(ZugLoot.DB.sheet.meta.raidID, "Rnew-live", "new sheet active")
eq(#RA.GetArchive(ZugLoot.DB), 2, "outgoing archived + new live synced")
ok(RA.Find(ZugLoot.DB, "Rold-live") ~= nil, "outgoing raid archived")
ok(RA.Find(ZugLoot.DB, "Rnew-live") ~= nil, "new live raid listed")

-- 8. ActivateArchivedRaid switches live sheet, keeps history, archives outgoing.
ZugLoot.MainWindow = { Refresh = function() end }
SRData.RecordRolls(fresh, 1001, { t = 5, mode = "SR", winners = { "Aaa" }, entries = {} })
SRData.MarkWon(fresh, 1001, "Aaa")
ZugLoot.SRImport.ActivateArchivedRaid("Rold-live")
eq(ZugLoot.DB.sheet.meta.raidID, "Rold-live", "activated old raid")
eq(#RA.GetArchive(ZugLoot.DB), 2, "outgoing progress archived on switch")
local cur = RA.Find(ZugLoot.DB, "Rnew-live")
ok(cur ~= nil and cur.nSessions == 1, "outgoing progress kept in archive")
ok(SRData.HasWon(ZugLoot.DB.sheet, 1001, "Aaa") == false, "activated sheet has its own won state")

-- 8b. RaidTime prefers import time, falls back to archive time.
eq(RA.RaidTime({ importedAt = 1500, archivedAt = 9999 }), 1500, "import time wins")
eq(RA.RaidTime({ importedAt = 0, archivedAt = 777 }), 777, "archive fallback")
eq(RA.RaidTime({}), 0, "empty snapshot -> 0")

-- 9. Freshly loaded sheet lists immediately, even though never unloaded.
local db2 = { sheet = makeSheet("Rfresh") }
eq(#RA.GetArchive(db2), 0, "no archive yet")
local synced = RA.SyncActive(db2, 4000)
ok(synced ~= nil and synced.raidID == "Rfresh", "sync snapshots live sheet")
eq(#RA.GetArchive(db2), 1, "live raid listed after sync")
local rows2 = RA.ListSummaries(db2, 4000)
eq(#rows2, 1, "one row")
eq(rows2[1].raidID, "Rfresh", "live raid in list")
ok(rows2[1].active, "live raid flagged active")
-- Progress after load flows into the same row (no duplicate).
SRData.RecordRolls(db2.sheet, 1001, { t = 9, mode = "SR", winners = {}, entries = {} })
local rows2b = RA.ListSummaries(db2, 4001)
eq(#rows2b, 1, "still one row after progress")
eq(rows2b[1].nSessions, 1, "row counts update in place")
-- SyncActive with no live sheet is a safe no-op.
ok(RA.SyncActive({}, 4000) == nil, "sync with no sheet is nil")

-- 10. ApplySheet lists the new raid right away (live, never unloaded).
ZugLoot.DB = {}
ZugLoot.SRImport.ApplySheet(makeSheet("Rbrandnew"), "paste", "ML2")
local rows3 = RA.ListSummaries(ZugLoot.DB, 5000)
local foundNew = false
for i = 1, #rows3 do if rows3[i].raidID == "Rbrandnew" then foundNew = true end end
ok(foundNew, "just-imported raid listed")

return T
