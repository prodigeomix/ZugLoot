-- ZugLoot/VersionGrid.lua
-- Raid version grid: one rectangle per raider + every SR-sheet player.
-- Status colors (comfortable, muted — never neon):
--   GREEN  = in group + on the SR sheet  (ready: SRs resolve)
--   RED    = in group + NOT on the sheet (can roll, holds no SR)
--   AMBER  = addon seen but version outdated (update nudge)
--   GREY   = on the sheet but not in this group (offline / other raid)
--   DIM    = in group but never answered (no addon / old client)
-- Names render full-length in class color with an outline for contrast.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.VersionGrid = M

M.seen = {} -- [name] = { version=..., auto=bool, online=bool }

function M.Announce()
  if Z.Comm then Z.Comm.AnnounceVersion() end
end

-- We run the addon, so we have OUR version: seed self into seen before
-- asking the group (solo sends nothing — Channel is nil — so without
-- this the grid would forever claim we lack the addon).
function M.Request()
  M.seen = {}
  local me = M.MyName and M.MyName() or nil
  if me and Z.VERSION then
    M.seen[me] = { version = Z.VERSION, online = true }
  end
  Z.Comm.RequestVersions()
  Z.Print("Version check sent. /zl ver in a few seconds.")
end

local function cmpVersion(a, b)
  if a == b then return 0 end
  if not a then return -1 end
  if not b then return 1 end
  return (tostring(a) < tostring(b)) and -1 or 1
end

function M.OnVersion(sender, version)
  if sender then M.seen[sender] = { version = Z.Util.Trim(version or "?"), online = true } end
end

-- SR sheet roster: every player holding a reserve anywhere on the sheet.
function M.SheetNames()
  local sheet = Z.DB and Z.DB.sheet
  if sheet and Z.SRData and Z.SRData.AllPlayerNames then
    return Z.SRData.AllPlayerNames(sheet) or {}
  end
  return {}
end

function M.OnSheet(name)
  if not name then return false end
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then return false end
  -- Sheet players map (import/parse may store class or record tables).
  if sheet.players and sheet.players[name] ~= nil then return true end
  -- Fallback: scan reserves (sheets built by hand/tests may skip it).
  if Z.SRData and Z.SRData.AllPlayerNames then
    local all = Z.SRData.AllPlayerNames(sheet) or {}
    for i = 1, Z.Util.ArrayCount(all) do
      if all[i] == name then return true end
    end
  end
  return false
end

-- Player name captured into a local FIRST: this client extends some
-- name APIs with extra returns (cf. UnitExists -> guid), and a bare
-- UnitName() as table.insert's last arg propagates every return
-- (3-arg insert -> "number expected, got string"). Locals truncate.
local function myName()
  if not UnitName then return nil end
  local me = UnitName("player")
  if me and me ~= "" then return me end
  return nil
end
M.MyName = myName

function M.RosterNames()
  local names = {}
  -- Solo: only me, no group APIs at all.
  local solo = Z.SRSecurity and Z.SRSecurity.IsSolo
    and Z.SRSecurity.IsSolo()
  if solo then
    table.insert(names, myName() or "you")
    return names
  end
  if GetNumRaidMembers and GetNumRaidMembers() > 0 then
    for i = 1, GetNumRaidMembers() do
      local name = GetRaidRosterInfo(i)
      if name then table.insert(names, name) end
    end
  elseif GetNumPartyMembers then
    local me = myName()
    if me then table.insert(names, me) end
    for i = 1, GetNumPartyMembers() do
      local n = UnitName("party" .. i)
      if n then table.insert(names, n) end
    end
  else
    table.insert(names, myName() or "you")
  end
  return names
end

-- Grid names: group first, then sheet players not in the group.
-- inGroup flags the sheet-only rows (rendered dim/grey).
function M.GridNames()
  local rows, seenSet = {}, {}
  local group = M.RosterNames()
  for i = 1, Z.Util.ArrayCount(group) do
    local n = group[i]
    if n and not seenSet[n] then
      seenSet[n] = true
      table.insert(rows, { name = n, inGroup = true })
    end
  end
  local sheet = M.SheetNames()
  for i = 1, Z.Util.ArrayCount(sheet) do
    local n = sheet[i]
    if n and not seenSet[n] then
      seenSet[n] = true
      table.insert(rows, { name = n, inGroup = false })
    end
  end
  return rows
end

-- Status for one name. inGroup distinguishes the sheet-only rows.
function M.StatusFor(name, inGroup)
  if inGroup == nil then inGroup = true end
  if not inGroup then return "GREY" end -- sheet, not here
  local s = M.seen[name]
  -- Outdated addon beats sheet green: an SR'd raider on an old client
  -- still needs the update nudge (auto-resolve needs current code).
  if s and cmpVersion(s.version, Z.VERSION) ~= 0 then return "AMBER" end
  if M.OnSheet(name) then return "GREEN" end -- raider + SR'd
  return "RED" -- in group, holds no SR
end

function M.ColorFor(name)
  return M.StatusFor(name, true)
end

function M.AllCurrent()
  local names = M.RosterNames()
  for i = 1, Z.Util.ArrayCount(names) do
    if M.ColorFor(names[i]) ~= "GREEN" then return false end
  end
  return true
end

-- Pure render for tests: returns rows of {name, color, inGroup}.
function M.RenderRows(names)
  local rows = {}
  for i = 1, Z.Util.ArrayCount(names) do
    local n = names[i]
    local nm, grp = n, true
    if type(n) == "table" then nm, grp = n.name, n.inGroup end
    table.insert(rows, { name = nm, color = M.StatusFor(nm, grp), inGroup = grp })
  end
  return rows
end

function M.Show()
  -- Members tab in the main window owns the grid now; kept for API compat.
  if Z.MainWindow then Z.MainWindow.Toggle("versions") return end
  M.Request()
end

function M.PrintList()
  local grid = M.GridNames()
  for i = 1, Z.Util.ArrayCount(grid) do
    local g = grid[i]
    local n = g.name
    local disp = n
    if Z.ClassColors and Z.ClassColors.ColoredName then
      disp = Z.ClassColors.ColoredName(n)
    end
    local tag = M.StatusFor(n, g.inGroup)
    if not g.inGroup then tag = tag .. " (not in group)" end
    Z.Print(disp .. ": " .. tag .. " v" .. ((M.seen[n] and M.seen[n].version) or "?"))
  end
end
