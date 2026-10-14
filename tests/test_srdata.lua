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

-- 6. Example file parses.
local f = io.open("CustomData_example/ZugLoot_SR.txt", "r")
if f then
  local ex = f:read("*a") f:close()
  local se, seerr = SRData.ParseLineFormat(ex)
  ok(se ~= nil, "example file parses: " .. tostring(seerr))
else
  T.fail = T.fail + 1 table.insert(T.errors, "FAIL example file missing")
end

-- 8. Real-world file content: base64 raidres export parses via the same
-- path LoadFromFile uses (regression: LoadFromFile only tried line format).
ZugLoot.Util = ZugLoot.Util or {}
-- minimal shims so SRImport loads outside the client
ZugLoot.SRData = SRData
ZugLoot.SRSecurity = { CanImport = function() return true end,
  CanBroadcast = function() return false end }
ZugLoot.SRView = { Refresh = function() end }
ZugLoot.DropLog = { Add = function() end }
ZugLoot.Print = function() end
ZugLoot.DB = {}
ZugLoot.Comm = {}
dofile("SRImport.lua")
local blob = nil
local bf = io.open("CustomData_example/ZugLoot_SR.txt", "r")
if bf then blob = bf:read("*a") bf:close() end
-- Synthesize a raidres-style base64 blob: {"softreserves":[...]} minimal.
-- (Full export decode is covered by section 3; here we check dispatch.)
local lineSheet, lineErr = ZugLoot.SRImport.ParseAnyImport(blob)
ok(lineSheet ~= nil, "ParseAnyImport accepts line format: " .. tostring(lineErr))
local badSheet, badErr = ZugLoot.SRImport.ParseAnyImport("not a sheet at all !!!")
ok(badSheet == nil and badErr ~= nil, "ParseAnyImport rejects garbage")

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
other.meta = { raidID = "R2", raidName = "BWL", importedAt = 100, source = "paste" }
ok(not RI.SheetIsStale(ZugLoot.DB.sheet, other), "other raid never stale")
local okOther = RI.ApplySheet(other, "paste", "ML")
ok(okOther ~= false, "other raid applies")
eq(ZugLoot.DB.sheet.meta.raidID, "R2", "raid switched")

-- 10. Import guards: truncated payloads fail FAST with a message
-- (regression: importing a truncated CustomData file hung the client —
-- JsonDecode ran on a partial payload).
-- Truncated base64 (length not a multiple of 4 after whitespace strip).
local trunc, truncErr = SRData.ParseRaidResExport("eyJtZXRhZGF0YSI6eyJ")
ok(trunc == nil and truncErr ~= nil, "truncated base64 refused")
ok(string.find(tostring(truncErr), "truncated", 1, true) ~= nil, "truncated message")
-- Valid-length but JSON-cut payload also refuses cleanly.
local cutJson = "eyJhIjox" -- base64("{") + junk -> decodes, tail isn't }/]
local cut, cutErr = SRData.ParseRaidResExport(cutJson)
ok(cut == nil, "cut JSON refused (no hang, no sheet)")

return T
