-- ZugLoot/ClassColors.lua
-- Class-colored character names. PURE + nil-safe: no WoW API at load, every
-- client global is checked at call time so it also runs under stock lua.
-- Resolution order for a name's class:
--   1. live party/raid member list (raid roster first, then party units),
--   2. fallback: the class stored on the SR sheet at import time
--      (sheet.players, from raidres character.class / legacy role).
-- Role strings carry class+spec (e.g. "PaladinHoly"): the class prefix is
-- what colors the name, the spec is ignored.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.ClassColors = M

-- Canonical classes + Blizzard class colors (Paladin pink etc.).
M.CLASSES = {
  "Warrior", "Paladin", "Hunter", "Rogue", "Priest",
  "Shaman", "Mage", "Warlock", "Druid",
}

M.COLORS = {
  ["Warrior"] = "FFC79C6E",
  ["Paladin"] = "FFF58CBA",
  ["Hunter"]  = "FFABD473",
  ["Rogue"]   = "FFFFF569",
  ["Priest"]  = "FFFFFFFF",
  ["Shaman"]  = "FF0070DE",
  ["Mage"]    = "FF69CCF0",
  ["Warlock"] = "FF9482C9",
  ["Druid"]   = "FFFF7D0A",
}

-- Abbreviations seen in the wild (raidres exports use "War" etc.).
-- Full-string match only, so these can never misfire on real class names.
local ABBR = {
  war = "Warrior", warr = "Warrior",
  pala = "Paladin", pal = "Paladin", pally = "Paladin",
  hunt = "Hunter",
  rog = "Rogue",
  prie = "Priest",
  sham = "Shaman",
  mag = "Mage",
  lock = "Warlock", wl = "Warlock",
  dru = "Druid",
}

local function trim(s)
  s = tostring(s or "")
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Normalize anything class-like to a canonical class name, or nil.
-- Accepts: canonical ("Paladin"), file names ("PALADIN"), abbreviations
-- ("War"), and class+spec roles ("PaladinHoly" -> "Paladin").
function M.NormalizeClass(s)
  s = trim(s)
  if s == "" then return nil end
  local lower = string.lower(s)
  -- 1. exact canonical match (case-insensitive: "paladin", "PALADIN").
  for i = 1, 9 do
    if lower == string.lower(M.CLASSES[i]) then return M.CLASSES[i] end
  end
  -- 2. known abbreviation ("War" -> "Warrior").
  if ABBR[lower] then return ABBR[lower] end
  -- 3. class+spec prefix ("PaladinHoly" -> "Paladin"). Longest first so a
  -- longer class name always wins over a shorter one sharing a stem.
  local best = nil
  for i = 1, 9 do
    local canon = string.lower(M.CLASSES[i])
    if string.sub(lower, 1, string.len(canon)) == canon then
      if not best or string.len(canon) > string.len(string.lower(best)) then
        best = M.CLASSES[i]
      end
    end
  end
  return best
end

-- Live name -> raw class map: raid roster first, then party units + self.
-- Values are whatever the client reports (class or file name); callers
-- normalize via NormalizeClass. Nil-safe: {} with no client APIs.
function M.RosterMap()
  local map = {}
  if GetNumRaidMembers and GetNumRaidMembers() > 0 and GetRaidRosterInfo then
    for i = 1, GetNumRaidMembers() do
      local name, _, _, _, _, class = GetRaidRosterInfo(i)
      if name and name ~= "" then map[name] = class end
    end
  elseif GetNumPartyMembers and GetNumPartyMembers() > 0 and UnitName then
    local me = UnitName("player")
    if me and me ~= "" then
      local cls = nil
      if UnitClass then local _, c = UnitClass("player") cls = c end
      if cls then map[me] = cls end
    end
    for i = 1, GetNumPartyMembers() do
      local n = UnitName("party" .. i)
      if n and n ~= "" then
        local cls = nil
        if UnitClass then local _, c = UnitClass("party" .. i) cls = c end
        if cls then map[n] = cls end
      end
    end
  end
  if UnitName then
    local me = UnitName("player")
    if me and me ~= "" and not map[me] then
      local cls = nil
      if UnitClass then local _, c = UnitClass("player") cls = c end
      if cls then map[me] = cls end
    end
  end
  return map
end

local function sheetOf(sheet)
  if sheet then return sheet end
  if Z and Z.DB and Z.DB.sheet then return Z.DB.sheet end
  return nil
end

-- Canonical class for a name (roster first, sheet fallback), or nil.
-- roster: optional prebuilt map (tests); otherwise built live.
function M.ClassOf(name, sheet, roster)
  if not name or tostring(name) == "" then return nil end
  name = tostring(name)
  roster = roster or M.RosterMap()
  if roster and roster[name] then
    local c = M.NormalizeClass(roster[name])
    if c then return c end
  end
  local sh = sheetOf(sheet)
  if sh and sh.players and sh.players[name] then
    local p = sh.players[name]
    if type(p) ~= "table" then return M.NormalizeClass(p) end
    return M.NormalizeClass(p.class)
  end
  return nil
end

-- RAW class/spec string for a name (roster first, sheet fallback) —
-- feeds RoleOf so spec suffixes survive (ClassOf normalizes them away).
-- Nil-safe: nil with no client APIs (headless).
-- Roster entries carry BARE classes (no spec suffix) and therefore can
-- only ever resolve to class defaults; check the SHEET first so a
-- spec'd import value (PaladinProtection) wins over the roster's bare
-- class (Paladin). The roster only fills names the sheet never saw.
function M.RawClassOf(name, sheet, roster)
  if not name or tostring(name) == "" then return nil end
  name = tostring(name)
  local sh = sheetOf(sheet)
  if sh and sh.players and sh.players[name] then
    local p = sh.players[name]
    -- Prefer the raw import value (spec suffix intact for RoleOf).
    if type(p) == "table" and p.raw and p.raw ~= "" then return tostring(p.raw) end
    if type(p) == "table" and p.class then return tostring(p.class) end
    if type(p) == "string" and p ~= "" then return p end
  end
  roster = roster or M.RosterMap()
  if roster and roster[name] and roster[name] ~= "" then
    return tostring(roster[name])
  end
  return nil
end

-- Hex (no "|c") for a class, white fallback.
function M.ClassColorHex(class)
  return M.COLORS[M.NormalizeClass(class)] or "FFFFFFFF"
end

-- Combat role for the member-tab role icon: "ranged" (bow+arrow),
-- "melee" (sword), "healer" (holy book), "tank" (shield). Spec-aware
-- when the raw value carries it (PaladinHoly, DruidResto, ShamanEnh...);
-- otherwise the classic class default (Priest/Druid-heavy classes heal,
-- hunters + casters range, the rest melee). Nil when unknown.
-- Pure (headless-testable): raw class/spec string in, role out.
local HEAL_SPECS = {
  holy = true, disc = true, discipline = true, resto = true,
  restoration = true, mist = true, mistweaver = true,
}
local TANK_SPECS = {
  prot = true, protection = true, guardian = true, blood = true,
  brewmaster = true,
}
-- NOTE: mage specs (frost/fire/arcane) are NOT here — mages range
-- regardless of spec. Hunter specs likewise range (see RoleOf).
local MELEE_SPECS = {
  arms = true, fury = true,
  ret = true, retribution = true, enh = true, enhancement = true,
  feral = true, combat = true, assassination = true,
  subtlety = true, sub = true, unholy = true,
  windwalker = true,
}
-- DPS caster specs: explicit ranged (shadow priests DPS — never healers).
local RANGED_SPECS = {
  shadow = true, affliction = true, demonology = true, destruction = true,
  arcane = true, fire = true, frost = true, balance = true,
  elemental = true,
}
-- Rogue specs: all melee (incl. daggers builds).
local ROGUE_SPECS = {
  daggers = true, swords = true, maces = true, fists = true,
}
function M.RoleOf(raw)
  local canon = M.NormalizeClass(raw)
  if not canon then return nil end
  local lower = string.lower(tostring(raw or ""))
  local spec = string.sub(lower, string.len(string.lower(canon)) + 1)
  -- Spec suffix decides first ("PaladinHoly" heals, "ShamanEnh" melees).
  -- Hunters/mages/warlocks range in EVERY spec (incl. survival) — their
  -- suffixes never flip them to melee.
  if canon == "Hunter" or canon == "Mage" or canon == "Warlock" then
    return "ranged"
  end
  if spec ~= "" then
    if HEAL_SPECS[spec] then return "healer" end
    if TANK_SPECS[spec] then return "tank" end
    if MELEE_SPECS[spec] then return "melee" end
    if RANGED_SPECS[spec] then return "ranged" end
    if ROGUE_SPECS[spec] then return "melee" end
    -- Unknown suffix: fall to class default below.
  end
  if canon == "Priest" then return "healer" end
  if canon == "Paladin" then return "healer" end
  if canon == "Druid" then return "healer" end
  if canon == "Shaman" then return "healer" end
  if canon == "Hunter" or canon == "Mage" or canon == "Warlock" then
    return "ranged"
  end
  return "melee" -- Warrior, Rogue
end

-- Icon texture per role (stock 1.12 paths): bow, sword, holy book, shield.
M.ROLE_ICONS = {
  ranged = "Interface\\Icons\\INV_Weapon_Bow_07",
  melee = "Interface\\Icons\\INV_Sword_04",
  healer = "Interface\\Icons\\INV_Misc_Book_09",
  tank = "Interface\\Icons\\INV_Shield_04",
}
function M.RoleIcon(raw)
  local role = M.RoleOf(raw)
  if role and M.ROLE_ICONS[role] then return M.ROLE_ICONS[role], role end
  return nil, nil
end

-- Human-readable spec from a raw class/spec string: "PaladinProtection"
-- -> "Protection", "HunterBeastMastery" -> "Beast Mastery",
-- "Priest" -> nil (no spec known, nothing to show). Pure
-- (headless-testable): raw string in, display string-or-nil out.
local SPEC_WORDS = {
  beastmastery = "Beast Mastery", marksmanship = "Marksmanship",
  survival = "Survival", protection = "Protection", arms = "Arms",
  fury = "Fury", retribution = "Retribution", holy = "Holy",
  restoration = "Restoration", resto = "Restoration",
  enhancement = "Enhancement", enh = "Enhancement",
  elemental = "Elemental", feral = "Feral", guardian = "Guardian",
  balance = "Balance", shadow = "Shadow", discipline = "Discipline",
  disc = "Discipline", frost = "Frost", fire = "Fire", arcane = "Arcane",
  affliction = "Affliction", demonology = "Demonology",
  destruction = "Destruction", assassination = "Assassination",
  combat = "Combat", subtlety = "Subtlety", sub = "Subtlety",
  daggers = "Daggers", swords = "Swords", blood = "Blood",
  unholy = "Unholy", brewmaster = "Brewmaster",
  windwalker = "Windwalker", mistweaver = "Mistweaver",
  mist = "Mistweaver", beastmaster = "Beast Mastery",
  beast = "Beast Mastery", marks = "Marksmanship",
  ret = "Retribution", prot = "Protection", fists = "Fists",
  maces = "Maces",
}
function M.SpecName(raw)
  local canon = M.NormalizeClass(raw)
  if not canon then return nil end
  local lower = string.lower(tostring(raw or ""))
  local spec = string.sub(lower, string.len(string.lower(canon)) + 1)
  if spec == "" then return nil end
  if SPEC_WORDS[spec] then return SPEC_WORDS[spec] end
  -- Unknown suffix: title-case it so something readable still shows
  -- ("FooBar" -> "Bar").
  return string.upper(string.sub(spec, 1, 1)) .. string.sub(spec, 2)
end

-- Display name in class color ("|cHEXname|r"), plain name when the class is
-- unknown. Display boundary only: stored data + addon messages stay raw.
function M.ColoredName(name, sheet)
  name = tostring(name or "")
  if name == "" then return "" end
  local c = M.ClassOf(name, sheet)
  if not c then return name end
  return "|c" .. (M.COLORS[c] or "FFFFFFFF") .. name .. "|r"
end

-- Clickable player link for CHAT ("|Hplayer:Name|h[Name]|h"), wrapped
-- in the class color so the eye reads class AND the mouse reads
-- player: click -> whisper menu, color -> class, same as Blizzard's
-- own chat name rendering. Unknown class: uncolored but still linked.
-- Defensive: an already-linked/colored input is stripped to the bare
-- name first so links never nest. Stored data stays raw — link at the
-- print/send boundary only. Nil-safe (headless): returns "" on empty.
function M.PlayerLink(name, sheet)
  local bare = tostring(name or "")
  -- Peel an |Hplayer wrapper: prefer the bracket display.
  local disp = string.match(bare, "|Hplayer:[^|]*|h%[(.-)%]|h")
  if disp and disp ~= "" then bare = disp end
  -- Peel a color wrap (|cXXXXXXXXName|r).
  local inner = string.match(bare, "^|c%x%x%x%x%x%x%x%x(.-)|r$")
  if inner then bare = inner end
  bare = tostring(bare or "")
  if bare == "" then return "" end
  local c = M.ClassOf(bare, sheet)
  local hex = (c and M.COLORS[c]) or "FFFFFFFF"
  return "|c" .. hex .. "|Hplayer:" .. bare .. "|h[" .. bare .. "]|h|r"
end

-- Colored join for winner/candidate/roll lists.
function M.ColorList(names, sep, sheet)
  local out = {}
  local n = 0
  if type(names) == "table" then
    while names[n + 1] ~= nil do
      n = n + 1
      table.insert(out, M.ColoredName(names[n + 1], sheet))
    end
  end
  return table.concat(out, sep or ", ")
end

if ZugLoot then ZugLoot.ClassColors = M end
return M
