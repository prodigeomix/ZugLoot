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
      if UnitClass then _, cls = UnitClass("player") end
      if cls then map[me] = cls end
    end
    for i = 1, GetNumPartyMembers() do
      local n = UnitName("party" .. i)
      if n and n ~= "" then
        local cls = nil
        if UnitClass then _, cls = UnitClass("party" .. i) end
        if cls then map[n] = cls end
      end
    end
  end
  if UnitName then
    local me = UnitName("player")
    if me and me ~= "" and not map[me] then
      local cls = nil
      if UnitClass then _, cls = UnitClass("player") end
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
    local raw = nil
    if type(p) == "table" then raw = p.class else raw = p end
    return M.NormalizeClass(raw)
  end
  return nil
end

-- Hex (no "|c") for a class, white fallback.
function M.ClassColorHex(class)
  return M.COLORS[M.NormalizeClass(class)] or "FFFFFFFF"
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
