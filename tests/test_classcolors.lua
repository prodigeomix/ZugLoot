-- tests/test_classcolors.lua
-- Class-colored names: normalize (incl. class+spec roles), roster-first
-- resolution with sheet fallback, display coloring, sheet plumbing
-- (import -> serialize -> deserialize -> archive round-trip).
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
local CC = ZugLoot.ClassColors
local SRData = ZugLoot.SRData

-- WoW API absent here: ClassColors must stay nil-safe throughout.
GetNumRaidMembers = nil
GetNumPartyMembers = nil
UnitName = nil
UnitClass = nil
GetRaidRosterInfo = nil

-- 1. Normalize: canonical, file names, abbreviations, class+spec roles.
eq(CC.NormalizeClass("Paladin"), "Paladin", "canonical")
eq(CC.NormalizeClass("paladin"), "Paladin", "lowercase")
eq(CC.NormalizeClass("PALADIN"), "Paladin", "file name")
eq(CC.NormalizeClass("War"), "Warrior", "abbreviation")
eq(CC.NormalizeClass("PaladinHoly"), "Paladin", "class+spec -> class (pink, not spec)")
eq(CC.NormalizeClass("MageFrost"), "Mage", "spec suffix ignored")
eq(CC.NormalizeClass("WarlockAffliction"), "Warlock", "longer class wins")
eq(CC.NormalizeClass(""), nil, "empty -> nil")
eq(CC.NormalizeClass(nil), nil, "nil -> nil")
eq(CC.NormalizeClass("NotAClass"), nil, "garbage -> nil")
eq(CC.NormalizeClass("Holy"), nil, "bare spec is not a class")

-- 2. Canonical colors: Paladin pink etc.
eq(CC.COLORS["Paladin"], "FFF58CBA", "paladin pink")
eq(CC.ClassColorHex("PaladinHoly"), "FFF58CBA", "role colors as its class")

-- 3. Roster first, sheet fallback. No client APIs here -> roster empty.
local sheet = SRData.NewSheet()
SRData.SetPlayerClass(sheet, "SheetPal", "PaladinHoly")
eq(SRData.PlayerClass(sheet, "SheetPal"), "Paladin", "sheet stores canonical")
eq(CC.ClassOf("SheetPal", sheet), "Paladin", "sheet fallback resolves")
eq(CC.ClassOf("Nobody", sheet), nil, "unknown -> nil")
eq(CC.ColoredName("SheetPal", sheet), "|cFFF58CBASheetPal|r", "colored display")
eq(CC.ColoredName("Nobody", sheet), "Nobody", "unknown stays plain")
eq(CC.ColoredName(nil, sheet), "", "nil safe")

-- 4. Roster beats the sheet when both know the name.
local roster = { Both = "MAGE" }
local sheet2 = SRData.NewSheet()
SRData.SetPlayerClass(sheet2, "Both", "Priest")
eq(CC.ClassOf("Both", sheet2, roster), "Mage", "roster wins over sheet")

-- 5. Raidres import captures classes: new character.class + legacy role.
local data = {
  metadata = { id = "C1" },
  reservations = {
    { character = { name = "NewPala", class = "PaladinHoly" }, raidItemId = 100 },
  },
  softreserves = {
    { name = "LegMage", role = "Mage", items = { { id = 101 } } },
    { name = "LegDruid", role = "DruidResto", items = { { id = 102 } } },
  },
}
local s3 = SRData.TransformRaidRes(data)
eq(SRData.PlayerClass(s3, "NewPala"), "Paladin", "new format class+spec")
eq(SRData.PlayerClass(s3, "LegMage"), "Mage", "legacy role")
eq(SRData.PlayerClass(s3, "LegDruid"), "Druid", "legacy role+spec")

-- 6. Serialize -> deserialize round-trips classes (broadcast path).
ZugLoot.Util = ZugLoot.Util or dofile("Util.lua")
ZugLoot.SRSecurity = { CanImport = function() return true end,
  CanBroadcast = function() return false end }
ZugLoot.SRView = { Refresh = function() end }
ZugLoot.DropLog = { Add = function() end }
ZugLoot.Print = function() end
ZugLoot.DB = {}
ZugLoot.Comm = {}
dofile("SRImport.lua")
local payload = ZugLoot.SRImport.SerializeSheet(s3)
ok(string.find(payload, "PLAYERS;", 1, true) ~= nil, "players line serialized")
local back, berr = ZugLoot.SRImport.DeserializeSheet(payload)
ok(back ~= nil, "round-trip parses: " .. tostring(berr))
eq(SRData.PlayerClass(back, "NewPala"), "Paladin", "class survives broadcast")
eq(SRData.PlayerClass(back, "LegDruid"), "Druid", "role survives broadcast")

-- 6b. Wire encoding: serialized sheets never carry a bare "|" (the
-- ChatThrottleLib:261 "Invalid escape code" crash) and decode back
-- losslessly — both with and without a base64 encoder present.
dofile("Comm.lua")
ZugLoot.Comm = ZugLoot.Comm
local wire = ZugLoot.Comm.EncodeSheetPayload(s3)
ok(not string.find(wire, "|", 1, true), "wire payload has no bare pipe")
local backW, berrW = ZugLoot.SRImport.DeserializeSheet(wire)
ok(backW ~= nil, "wire payload parses: " .. tostring(berrW))
eq(SRData.PlayerClass(backW, "NewPala"), "Paladin", "class survives wire")
-- Percent edge: a name holding "%B" must not decode into a pipe.
local tricky = SRData.NewSheet()
tricky.items[7] = { quality = 4, rollers = { { name = "Pct%BName", rolls = 1 } } }
local wireT = ZugLoot.Comm.EncodeSheetPayload(tricky)
local backT, berrT = ZugLoot.SRImport.DeserializeSheet(wireT)
ok(backT ~= nil, "tricky payload parses: " .. tostring(berrT))
local foundTricky = false
for _, r in pairs((backT.items[7] or {}).rollers or {}) do
  if r.name == "Pct%BName" then foundTricky = true end
end
ok(foundTricky, "%B in a name survives the escape round-trip")
-- Base64 path when the encoder exists (alphabet needs no escaping).
Base64Encode = function(s) return "QUI=" end -- stub: decodes to "AB"
Base64Decode = function(s) if s == "QUI=" then return "X;1:1" end end
local wireB = ZugLoot.Comm.EncodeSheetPayload(s3)
eq(string.sub(wireB, 1, 3), "B64", "base64 path tagged")
local backB = ZugLoot.SRImport.DeserializeSheet(wireB)
ok(backB ~= nil and backB.items[1] ~= nil, "base64 wire decodes")
Base64Encode = nil
Base64Decode = nil

-- 7. Archive snapshot + restore keep classes (Raids tab activate path).
local db = { sheet = s3, raidArchive = {} }
ZugLoot.RaidArchive.ArchiveActive(db, 1000)
local snap = db.raidArchive[1]
ok(snap.data.players ~= nil, "snapshot carries players")
local restored, rerr = ZugLoot.RaidArchive.RestoreSheet(db, snap.raidID)
ok(restored ~= nil, "restore ok: " .. tostring(rerr))
eq(SRData.PlayerClass(restored, "NewPala"), "Paladin", "class survives archive")

-- 8. NewSheet always carries the players table (old snapshots may lack it).
local fresh = SRData.NewSheet()
ok(fresh.players ~= nil, "players table present")
eq(SRData.PlayerClass(fresh, "X"), nil, "no crash on empty")

return T
