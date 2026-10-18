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

-- PlayerLink: clickable + class-colored chat link.
eq(CC.PlayerLink("SheetPal", sheet),
  "|cFFF58CBA|Hplayer:SheetPal|h[SheetPal]|h|r", "paladin link")
eq(CC.PlayerLink("Nobody", sheet),
  "|cFFFFFFFF|Hplayer:Nobody|h[Nobody]|h|r", "unknown class links white")
eq(CC.PlayerLink(nil, sheet), "", "nil safe")
eq(CC.PlayerLink("", sheet), "", "empty safe")
-- Defensive: already-linked/colored input never nests.
eq(CC.PlayerLink("|cFFF58CBASheetPal|r", sheet),
  "|cFFF58CBA|Hplayer:SheetPal|h[SheetPal]|h|r", "color wrap peeled")
eq(CC.PlayerLink("|cFFF58CBA|Hplayer:SheetPal|h[SheetPal]|h|r", sheet),
  "|cFFF58CBA|Hplayer:SheetPal|h[SheetPal]|h|r", "link idempotent")
-- Sheet class colors the link (Priest reads white — still linked).
local linkSheet = SRData.NewSheet()
SRData.SetPlayerClass(linkSheet, "LinkBoth", "PaladinHoly")
eq(CC.PlayerLink("LinkBoth", linkSheet),
  "|cFFF58CBA|Hplayer:LinkBoth|h[LinkBoth]|h|r", "sheet class colors the link")

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

-- 9. Role icons: spec-aware when the raw value carries it, class
-- default otherwise; unknown classes give no icon.
eq(CC.RoleOf("PaladinProtection"), "tank", "prot paladin tanks")
eq(CC.RoleOf("WarriorProtection"), "tank", "prot warrior tanks")
eq(CC.RoleOf("DruidGuardian"), "tank", "guardian druid tanks")
eq(CC.RoleOf("PriestShadow"), "ranged", "shadow priest DPSes, never heals")
eq(CC.RoleOf("RogueDaggers"), "melee", "daggers rogue melees")
eq(CC.RoleOf("WarlockAffliction"), "ranged", "affliction ranges")
eq(CC.RoleOf("MageArcane"), "ranged", "arcane ranges")
eq(CC.RoleOf("PriestDiscipline"), "healer", "discipline heals")
eq(CC.RoleOf("ShamanRestoration"), "healer", "resto shaman heals")
eq(CC.RoleOf("PaladinHoly"), "healer", "holy paladin heals")
eq(CC.RoleOf("ShamanEnhancement"), "melee", "enh shaman melees")
eq(CC.RoleOf("DruidFeral"), "melee", "feral druid melees")
eq(CC.RoleOf("Hunter"), "ranged", "hunter ranges")
eq(CC.RoleOf("MageFrost"), "ranged", "frost mage ranges")
eq(CC.RoleOf("Warlock"), "ranged", "warlock ranges")
eq(CC.RoleOf("Priest"), "healer", "priest heals")
eq(CC.RoleOf("Paladin"), "healer", "paladin defaults heal")
eq(CC.RoleOf("Druid"), "healer", "druid defaults heal")
eq(CC.RoleOf("Shaman"), "healer", "shaman defaults heal")
eq(CC.RoleOf("Warrior"), "melee", "warrior melees")
eq(CC.RoleOf("Rogue"), "melee", "rogue melees")
eq(CC.RoleOf("NotAClass"), nil, "unknown class, no role")
eq(CC.RoleOf(nil), nil, "nil safe")
local bowIcon, bowRole = CC.RoleIcon("Hunter")
eq(bowRole, "ranged", "bow role")
ok(bowIcon and string.find(bowIcon, "Bow", 1, true) ~= nil, "bow texture")
local swordIcon, swordRole = CC.RoleIcon("Warrior")
eq(swordRole, "melee", "sword role")
ok(swordIcon and string.find(swordIcon, "Sword", 1, true) ~= nil, "sword texture")
local bookIcon, bookRole = CC.RoleIcon("Priest")
eq(bookRole, "healer", "book role")
ok(bookIcon and string.find(bookIcon, "Book", 1, true) ~= nil, "book texture")
local shieldIcon, shieldRole = CC.RoleIcon("WarriorProtection")
eq(shieldRole, "tank", "shield role")
ok(shieldIcon and string.find(shieldIcon, "Shield", 1, true) ~= nil, "shield texture")
-- RawClassOf keeps the spec suffix ClassOf normalizes away.
local roleSheet = SRData.NewSheet()
SRData.SetPlayerClass(roleSheet, "HolyPal", "PaladinHoly")
eq(CC.RawClassOf("HolyPal", roleSheet), "PaladinHoly", "raw keeps spec")
eq(CC.ClassOf("HolyPal", roleSheet), "Paladin", "canonical normalizes")
eq(CC.RoleOf(CC.RawClassOf("HolyPal", roleSheet)), "healer", "spec resolves role")
-- Sheet spec beats the live roster's bare class (regression: grouped
-- clients report bare "Paladin", hiding a Protection spec behind the
-- healer default — Pysanka showed book instead of shield).
SRData.SetPlayerClass(roleSheet, "ProtPal", "PaladinProtection")
local liveRoster = { ProtPal = "Paladin" } -- bare, like GetRaidRosterInfo
ZugLoot.DB = { sheet = roleSheet }
eq(CC.RawClassOf("ProtPal", nil, liveRoster), "PaladinProtection", "sheet spec beats bare roster")
eq(CC.RoleOf(CC.RawClassOf("ProtPal", nil, liveRoster)), "tank", "prot paladin tanks in raid")
-- Roster-only names (sheet never saw them) still resolve bare.
eq(CC.RawClassOf("RosterOnly", nil, { RosterOnly = "Warrior" }), "Warrior", "roster fallback")
ZugLoot.DB = nil
-- SpecName: human-readable spec only, nil when bare/unknown.
eq(CC.SpecName("PaladinProtection"), "Protection", "prot reads")
eq(CC.SpecName("HunterBeastMastery"), "Beast Mastery", "two-word spec splits")
eq(CC.SpecName("RogueDaggers"), "Daggers", "weapon spec reads")
eq(CC.SpecName("WarlockAffliction"), "Affliction", "lock spec reads")
eq(CC.SpecName("PriestHoly"), "Holy", "holy reads")
eq(CC.SpecName("Priest"), nil, "bare class, no spec")
eq(CC.SpecName("NotAClass"), nil, "unknown, no spec")
eq(CC.SpecName(nil), nil, "nil safe")

return T
