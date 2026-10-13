-- ZugLoot/VersionGrid.lua
-- Raid version squares grid: green=current, yellow=outdated, red=no addon, grey=offline.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.VersionGrid = M

M.seen = {} -- [name] = { version=..., auto=bool, online=bool }

function M.Announce()
  if Z.Comm then Z.Comm.AnnounceVersion() end
end

function M.Request()
  M.seen = {}
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

function M.RosterNames()
  local names = {}
  if GetNumRaidMembers and GetNumRaidMembers() > 0 then
    for i = 1, GetNumRaidMembers() do
      local name = GetRaidRosterInfo(i)
      if name then table.insert(names, name) end
    end
  elseif GetNumPartyMembers then
    table.insert(names, UnitName("player"))
    for i = 1, GetNumPartyMembers() do
      local n = UnitName("party" .. i)
      if n then table.insert(names, n) end
    end
  else
    table.insert(names, UnitName("player") or "you")
  end
  return names
end

function M.ColorFor(name)
  local s = M.seen[name]
  if not s then return "RED" end
  if cmpVersion(s.version, Z.VERSION) == 0 then return "GREEN" end
  return "YELLOW"
end

function M.AllCurrent()
  local names = M.RosterNames()
  for i = 1, Z.Util.ArrayCount(names) do
    if M.ColorFor(names[i]) ~= "GREEN" then return false end
  end
  return true
end

-- Pure render for tests: returns rows of {name, color}.
function M.RenderRows(names)
  local rows = {}
  for i = 1, Z.Util.ArrayCount(names) do
    local n = names[i]
    table.insert(rows, { name = n, color = M.ColorFor(n) })
  end
  return rows
end

function M.Show()
  -- Versions tab in the main window owns the grid now; kept for API compat.
  if Z.MainWindow then Z.MainWindow.Toggle("versions") return end
  M.Request()
end

function M.PrintList()
  for _, n in ipairs(M.RosterNames()) do
    local disp = n
    if Z.ClassColors and Z.ClassColors.ColoredName then
      disp = Z.ClassColors.ColoredName(n)
    end
    Z.Print(disp .. ": " .. M.ColorFor(n) .. ((M.seen[n] and M.seen[n].version) or "no addon"))
  end
end
