-- tests/test_srdata.lua
-- SRData tests: line format, raidres transform (all srPlus spellings), won marks.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then
    T.fail = T.fail + 1
    table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else
    T.pass = T.pass + 1
  end
end

local function ok(v, msg)
  if not v then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else T.pass = T.pass + 1 end
end

ZugLoot = {}
dofile("Util.lua")
dofile("ClassColors.lua")
dofile("SRData.lua")
local SRData = ZugLoot.SRData

-- 1. Line format parse.
local text = [[
# comment
Blackfang; 17063:2+20, 19137:1
Carbon; 18646:1+60
HARDRES; 17782, 18564
]]
local sheet, err = SRData.ParseLineFormat(text)
ok(sheet ~= nil, "line parse ok: " .. tostring(err))
eq(sheet.items[17063].rollers[1].name, "Blackfang", "roller name")
eq(sheet.items[17063].rollers[1].rolls, 2, "rolls x2")
eq(sheet.items[17063].rollers[1].sr_plus, 20, "sr+ 20")
eq(sheet.items[19137].rollers[1].sr_plus, nil, "no sr+ is nil")
eq(sheet.items[18646].rollers[1].sr_plus, 60, "carbon sr+ 60")
ok(sheet.hardres[17782] ~= nil, "hardres parsed")

-- 2. Bad line rejected, nothing half-imported (returns nil).
local bad, berr = SRData.ParseLineFormat("NoSemicolonHere\n")
ok(bad == nil and berr ~= nil, "bad line rejected")

-- 3. New raidres format: srPlus object, isValid=false still counts.
local data = {
  metadata = { id = "X1", origin = "raidres", instances = { "Molten Core" } },
  reservations = {
    { character = { name = "Carbon", class = "Priest" }, raidItemId = 6724, srPlus = { value = 10, isValid = true } },
    { character = { name = "Zizz", class = "Druid" }, raidItemId = 6724, srPlus = { value = 50, isValid = false } },
    { character = { name = "NoBonus", class = "Mage" }, raidItemId = 6724 },
    { character = { name = "Flat", class = "War" }, raidItemId = 6725, srPlus = 30 },
    { character = { name = "Str", class = "War" }, raidItemId = 6726, srPlus = "5" },
  },
  hardreserves = { { id = 17782, quality = 5 } },
}
local s2 = SRData.TransformRaidRes(data)
local byName = {}
for _, r in ipairs(s2.items[6724].rollers) do byName[r.name] = r end
eq(byName["Carbon"].sr_plus, 10, "object srPlus valid")
eq(byName["Zizz"].sr_plus, 50, "object srPlus isValid=false still counts")
ok(byName["NoBonus"].sr_plus == nil, "missing srPlus is nil")
eq(s2.items[6725].rollers[1].sr_plus, 30, "flat number srPlus")
eq(s2.items[6726].rollers[1].sr_plus, 5, "string srPlus coerced")
ok(s2.hardres[17782] ~= nil, "hardres from export")
eq(s2.meta.raidID, "X1", "raid id kept")
eq(s2.meta.raidName, "Molten Core", "raid name from instances[1]")
-- instance fallback (name or id) when no instances array:
local s2b = SRData.TransformRaidRes({ metadata = { id = "Y", instance = "Blackwing Lair" }, softreserves = {} })
eq(s2b.meta.raidName, "Blackwing Lair", "raid name from instance")
local s2c = SRData.TransformRaidRes({ metadata = { id = "Z" }, softreserves = {} })
ok(s2c.meta.raidName == nil, "no instance info -> nil raid name")

-- 4. Legacy format: sr_plus number/string, rollBonus, max-not-sum on dupes.
local leg = {
  metadata = { id = "L" },
  softreserves = {
    { name = "PlayerA", role = "Hunter", items = { { id = 100, quality = 4 }, { id = 100, quality = 4, sr_plus = 20 } } },
    { name = "PlayerB", role = "Mage", items = { { id = 101, quality = 4, rollBonus = 15 } } },
    { name = "PlayerC", role = "Priest", items = { { id = 102, quality = 4, sr_plus = "7" } } },
  },
}
local s3 = SRData.TransformRaidRes(leg)
eq(s3.items[100].rollers[1].rolls, 2, "dupes count rolls")
eq(s3.items[100].rollers[1].sr_plus, 20, "max sr+ kept (not summed)")
eq(s3.items[101].rollers[1].sr_plus, 15, "rollBonus accepted")
eq(s3.items[102].rollers[1].sr_plus, 7, "string sr_plus coerced")

-- 5. Won marks.
SRData.MarkWon(s2, 6724, "Carbon")
ok(SRData.HasWon(s2, 6724, "Carbon"), "won marked")
ok(not SRData.HasWon(s2, 6724, "Zizz"), "other not won")
SRData.ClearWon(s2)
ok(not SRData.HasWon(s2, 6724, "Carbon"), "won cleared")

-- 5b. Spent SRs: SRHolders lists live holders only; badge + names
-- follow, so a re-drop with only won SRs shows no SR indication.
local sW = SRData.NewSheet()
sW.items[700] = { quality = 4, rollers = {
  { name = "A", rolls = 2, sr_plus = 10 },
  { name = "B", rolls = 1, sr_plus = nil },
} }
eq(#SRData.SRHolders(sW, 700), 2, "both holders live")
eq(SRData.ReserveBadge(sW, 700), "SR:2", "badge counts live holders")
eq(table.concat(SRData.SRNames(sW, 700), ","), "A,B", "names list live holders")
SRData.MarkWon(sW, 700, "A", 4)
eq(#SRData.SRHolders(sW, 700), 1, "spent holder drops out")
eq(SRData.SRHolders(sW, 700)[1].name, "B", "live holder remains")
eq(SRData.ReserveBadge(sW, 700), "SR", "badge recounts")
eq(table.concat(SRData.SRNames(sW, 700), ","), "B", "names recount")
SRData.MarkWon(sW, 700, "B", 4)
eq(#SRData.SRHolders(sW, 700), 0, "no live holders left")
eq(SRData.ReserveBadge(sW, 700), "", "all spent: no badge")
eq(#SRData.SRNames(sW, 700), 0, "all spent: no names")
-- HR still wins over spent SRs; unknown items stay empty.
sW.hardres[700] = { quality = 5 }
eq(SRData.ReserveBadge(sW, 700), "HR", "hardres beats spent")
eq(#SRData.SRHolders(sW, 9999), 0, "unknown item: no holders")

-- 6. Example file parses through the REAL import path (the same
-- ParseAnyImport dispatch LoadFromFile + paste use). The example is a
-- base64 raidres RollFor export, not line format, so it must route to
-- ParseRaidResExport — never to ParseLineFormat ("missing ';'").
-- Minimal shims so SRImport loads outside the client.
ZugLoot.Util = ZugLoot.Util or {}
ZugLoot.SRData = SRData
ZugLoot.SRSecurity = { CanImport = function() return true end,
  CanBroadcast = function() return false end }
ZugLoot.SRView = { Refresh = function() end }
ZugLoot.DropLog = { Add = function() end }
ZugLoot.Print = function() end
ZugLoot.DB = {}
ZugLoot.Comm = {}
dofile("SRImport.lua")
local f = io.open("CustomData_example/ZugLoot_SR.txt", "r")
if f then
  local ex = f:read("*a") f:close()
  local se, seerr = ZugLoot.SRImport.ParseAnyImport(ex)
  ok(se ~= nil, "example file parses: " .. tostring(seerr))
  if se then
    ok(ZugLoot.Util.TableCount(se.items) > 0, "example file has items")
    ok(se.meta and se.meta.raidID ~= nil, "example file keeps raid id")
    ok(not ZugLoot.SRData.SheetIsEmpty(se), "example file is not empty")
  end
else
  T.fail = T.fail + 1 table.insert(T.errors, "FAIL example file missing")
end

-- 6b. CSV import is DISABLED: the parser is defused (refuses with the
-- RollFor-only rule), the tripwire still recognizes CSV headers, and
-- preamble above base64 is dropped; garbage still rejected.
local defS, defErr = SRData.ParseCSVFormat("Player,ItemID\nAaa,1001\n")
ok(defS == nil, "defused CSV parser refuses even valid input")
ok(string.find(tostring(defErr), "only RollFor export", 1, true) ~= nil,
  "defused CSV refusal names the RollFor export")
ok(SRData.HasCSVHeader("Player,ItemID\nAaa,1001\n"), "csv tripwire still recognizes header")
ok(not SRData.HasCSVHeader("Aaa;1001:1\n"), "line format is not CSV")
-- Preamble above base64 is dropped; garbage still rejected.
local b64pre = "copy below this line:\neyJtZXRhZGF0YSI6eyJpZCI6IlIxIn0sInJlc2VydmF0aW9ucyI6W119\n"
local pb, pberr = SRData.ParseRaidResExport(b64pre)
ok(pb ~= nil, "base64 preamble dropped: " .. tostring(pberr))
if pb then eq(pb.meta.raidID, "R1", "preamble body intact") end

-- 8. Real-world dispatch checks (SRImport loaded with shims in section 6).
-- Synthesize a raidres-style base64 blob: {"softreserves":[...]} minimal.
-- (Full export decode is covered by section 3; here we check dispatch.)
local b64blob = "eyJtZXRhZGF0YSI6eyJpZCI6IlIxIn0sInJlc2VydmF0aW9ucyI6W119"
local expSheet, expErr = ZugLoot.SRImport.ParseAnyImport(b64blob)
ok(expSheet ~= nil, "ParseAnyImport accepts RollFor export: " .. tostring(expErr))
local badSheet, badErr = ZugLoot.SRImport.ParseAnyImport("not a sheet at all !!!")
ok(badSheet == nil and badErr ~= nil, "ParseAnyImport rejects garbage")
-- CSV is disabled: CSV input (incl. preamble above the header) is
-- refused with the RollFor-only rule, never dispatched to the parser.
local csvPre, csvPreErr = ZugLoot.SRImport.ParseAnyImport("ID,Item,Attendee\n1,Choker,Aaa\n")
ok(csvPre == nil, "ParseAnyImport refuses CSV")
ok(string.find(tostring(csvPreErr), "only RollFor export", 1, true) ~= nil,
  "CSV refusal names the RollFor export")
ok(string.find(tostring(csvPreErr), "missing ';'", 1, true) == nil,
  "CSV error is not the line-format fallthrough")
-- Failed raidres blobs report the REAL error, never the line-format
-- fallthrough. (';' is not valid base64, so "missing ';'" is always
-- the wrong message for a RollFor copy.) Non-base64 input (a truncated
-- copy whose length is no longer a multiple of 4) is refused as "not a
-- RollFor export"; a WELL-FORMED base64 copy whose JSON is cut off is
-- refused as "truncated import data".
local truncS, truncErr = ZugLoot.SRImport.ParseAnyImport("eyJtZXRhZGF0YSI6eyJpZCI6IlIxIn0sInJlc2Vyd")
ok(truncS == nil, "truncated RollFor refused")
ok(string.find(tostring(truncErr), "RollFor export", 1, true) ~= nil,
  "truncated RollFor names the RollFor export: " .. tostring(truncErr))
ok(string.find(tostring(truncErr), "missing ';'", 1, true) == nil,
  "truncated RollFor error is not the line-format fallthrough")
-- Well-formed base64, JSON cut off: truncation error (re-copy pointer).
local cutS, cutErr = ZugLoot.SRImport.ParseAnyImport("eyJtZXRhZGF0YSI6eyJpZCI6IlIxIn0sInNvZnRyZXNlcnZlcyI6W3sibmFtZSI6IkFhYSI=")
ok(cutS == nil, "cut RollFor refused")
ok(string.find(tostring(cutErr), "truncated", 1, true) ~= nil,
  "cut RollFor names truncation: " .. tostring(cutErr))
local fragS, fragErr = ZugLoot.SRImport.ParseAnyImport("eyJtZXRhZGF0YSI6eyJ")
ok(fragS == nil, "short RollFor fragment refused")
ok(string.find(tostring(fragErr), "missing ';'", 1, true) == nil,
  "short fragment error is not the line-format fallthrough: " .. tostring(fragErr))
-- Static line format still dispatches.
local lineSheet, lineErr = ZugLoot.SRImport.ParseAnyImport("Aaa;1001:1\n")
ok(lineSheet ~= nil, "ParseAnyImport accepts line format: " .. tostring(lineErr))

-- 7. SortedItemIDs ascending.
local ids = SRData.SortedItemIDs(s2)
ok(ids[1] < ids[2], "sorted ascending")

-- 9. Same-raid updates keep the raidID and apply by revision, never by
-- import order. Regression: re-importing/syncing an update kept the
-- raidID but tripped the "raidID <= live raidID" stale guard, so every
-- update was ignored as stale.
time = function() return 5000 end -- deterministic "now"
ZugLoot.RaidArchive = { ArchiveActive = function() end, SyncActive = function() end }
ZugLoot.SRSecurity = { CanBroadcast = function() return false end }
local RI = ZugLoot.SRImport
-- Live sheet: raid R1 at revision 4000.
local live = SRData.NewSheet()
live.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
live.meta = { raidID = "R1", raidName = "Molten Core", importedAt = 4000,
  importedBy = "ML", source = "paste" }
ZugLoot.DB = { sheet = live }
-- Paste re-import of an UPDATED export (same raidID, newer stamp 4500):
-- applies, keeps the ID, archives nothing stale.
local upd = SRData.NewSheet()
upd.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 }, { name = "Bbb", rolls = 1 } } }
upd.meta = { raidID = "R1", raidName = "Molten Core", importedAt = 4500, source = "paste" }
local okUpd = RI.ApplySheet(upd, "paste", "ML")
ok(okUpd ~= false, "same-raid update applies")
eq(ZugLoot.DB.sheet.meta.raidID, "R1", "update keeps the raid id")
eq(#ZugLoot.DB.sheet.items[1001].rollers, 2, "update content applied")
ok(not RI.SheetIsStale(live, ZugLoot.DB.sheet), "newer revision not stale")
-- Re-importing the OLD export (revision 4000) over the update: refused,
-- live progress untouched.
local old = SRData.NewSheet()
old.items[1001] = { quality = 4, rollers = { { name = "Aaa", rolls = 1 } } }
old.meta = { raidID = "R1", raidName = "Molten Core", importedAt = 4000, source = "paste" }
ok(RI.SheetIsStale(ZugLoot.DB.sheet, old), "older revision is stale")
local okOld = RI.ApplySheet(old, "paste", "ML")
eq(okOld, false, "stale re-import refused")
eq(#ZugLoot.DB.sheet.items[1001].rollers, 2, "live update kept")
-- Line-format re-import (no export time): stamps now (5000) — newer than
-- anything applied, so it applies as a same-raid refresh.
local lf, lferr = SRData.ParseLineFormat("Ccc;1001:1\n")
ok(lf ~= nil, "line import parses: " .. tostring(lferr))
lf.meta.raidID = "R1"
local okLf = RI.ApplySheet(lf, "file", "ML")
ok(okLf ~= false, "line-format refresh applies")
eq(ZugLoot.DB.sheet.meta.raidID, "R1", "refresh keeps the raid id")
eq(ZugLoot.DB.sheet.meta.importedAt, 5000, "refresh stamped now")
-- Different raid always applies (no stale comparison across raids).
local other = SRData.NewSheet()
other.items[1002] = { quality = 4, rollers = { { name = "Bbb", rolls = 1 } } }
other.meta = { raidID = "R2", raidName = "BWL", importedAt = 100, source = "paste" }
ok(not RI.SheetIsStale(ZugLoot.DB.sheet, other), "other raid never stale")
local okOther = RI.ApplySheet(other, "paste", "ML")
ok(okOther ~= false, "other raid applies")
eq(ZugLoot.DB.sheet.meta.raidID, "R2", "raid switched")

-- 10. Import guards: truncated payloads fail FAST with a message
-- (regression: importing a truncated CustomData file hung the client —
-- JsonDecode ran on a partial payload).
-- Non-base64 input is refused as "not a RollFor export" (strict
-- Base64Decode never garbage-decodes).
local trunc, truncErr2 = SRData.ParseRaidResExport("eyJtZXRhZGF0YSI6eyJ")
ok(trunc == nil and truncErr2 ~= nil, "truncated base64 refused")
ok(string.find(tostring(truncErr2), "RollFor export", 1, true) ~= nil, "not-an-export message")
-- Well-formed base64 but JSON-cut payload also refuses cleanly.
local cutJson = "eyJhIjox" -- base64('{"a":1' ...) -> decodes, tail isn't }/]
local cut = SRData.ParseRaidResExport(cutJson)
ok(cut == nil, "cut JSON refused (no hang, no sheet)")

-- 11. Empty-content guards (regression: a thin CSV import — header OK
-- but every row skipped, e.g. names instead of numeric IDs — applied a
-- 0-item sheet, broadcast it, and receivers landed on "(sheet is
-- empty)" while printing "Sheet received").
-- CSV is disabled: any CSV-looking input is refused at dispatch with
-- the RollFor-only rule (never parsed, never a line-format fallthrough).
local thin = "ID,Item,Attendee\nChoker of the Fire Lord,Choker,Pysanka\nBoots,Boots,Joblesspally\n"
local thinS, thinErr = ZugLoot.SRImport.ParseAnyImport(thin)
ok(thinS == nil and thinErr ~= nil, "thin CSV refused")
ok(string.find(tostring(thinErr), "only RollFor export", 1, true) ~= nil, "thin CSV refusal names the RollFor export")
ok(string.find(tostring(thinErr), "missing ';'", 1, true) == nil, "thin CSV error is not the line-format fallthrough")
-- Good CSV still parses through the same dispatch.
ok(SRData.HasCSVHeader(thin), "thin CSV still recognized as CSV")
ok(not SRData.HasCSVHeader("Aaa;1001:1\n"), "line format is not CSV")
-- SheetIsEmpty: items or hardres count as content.
ok(SRData.SheetIsEmpty(SRData.NewSheet()), "blank sheet is empty")
local hrOnly = SRData.NewSheet()
hrOnly.hardres[17782] = { quality = 5 }
ok(not SRData.SheetIsEmpty(hrOnly), "hardres-only sheet is content")
-- ApplySheet refuses empties BEFORE archiving/stamping: live kept.
local liveBefore = ZugLoot.DB.sheet
local printed = {}
ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
local okEmpty = RI.ApplySheet(SRData.NewSheet(), "paste", "ML")
eq(okEmpty, false, "empty apply refused")
ok(ZugLoot.DB.sheet == liveBefore, "live sheet kept on empty import")
ok(string.find(printed[#printed] or "", "no reservations", 1, true) ~= nil, "empty apply explains itself")
-- Broadcast side: empty sheets never go on the wire.
local sentWire = {}
ZugLoot.Comm = { BroadcastSheet = function() table.insert(sentWire, true) end }
ZugLoot.SRSecurity = { CanBroadcast = function() return true end }
RI.ApplySheet(hrOnly, "paste", "ML") -- hardres-only applies + broadcasts
ok(#sentWire == 1, "content sheet broadcasts")
sentWire = {}
local empty2 = SRData.NewSheet()
empty2.meta = { raidID = "Rempty", importedAt = 99999 }
RI.ApplySheet(empty2, "paste", "ML")
ok(#sentWire == 0, "empty sheet never broadcasts")
eq(ZugLoot.DB.sheet.meta.raidID, hrOnly.meta.raidID, "empty import kept live raid")

return T
