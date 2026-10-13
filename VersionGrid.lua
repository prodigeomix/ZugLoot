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

local gridFrame = nil
function M.Show()
  M.Request()
  if not gridFrame then
    gridFrame = CreateFrame("Frame", "ZugLootVerFrame", UIParent)
    gridFrame:SetWidth(300) gridFrame:SetHeight(200)
    gridFrame:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    gridFrame:SetMovable(true) gridFrame:EnableMouse(true)
    gridFrame:RegisterForDrag("LeftButton")
    gridFrame:SetScript("OnDragStart", function() gridFrame:StartMoving() end)
    gridFrame:SetScript("OnDragStop", function() gridFrame:StopMovingOrSizing() end)
    gridFrame:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    gridFrame:SetBackdropColor(0, 0, 0, 0.9)
    local t = gridFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOP", gridFrame, "TOP", 0, -10)
    t:SetText("ZugLoot versions (" .. Z.VERSION .. ")")
    local c = gridFrame:CreateFontString("ZugLootVerContent", "OVERLAY", "GameFontHighlightSmall")
    c:SetPoint("TOPLEFT", gridFrame, "TOPLEFT", 14, -40)
    c:SetWidth(272) c:SetJustifyH("LEFT")
    local cb = CreateFrame("Button", nil, gridFrame, "UIPanelButtonTemplate")
    cb:SetWidth(80) cb:SetHeight(22)
    cb:SetPoint("BOTTOM", gridFrame, "BOTTOM", 0, 12)
    cb:SetText("Close")
    cb:SetScript("OnClick", function() gridFrame:Hide() end)
  end
  gridFrame:Show()
end

function M.PrintList()
  for _, n in ipairs(M.RosterNames()) do
    Z.Print(n .. ": " .. M.ColorFor(n) .. ((M.seen[n] and M.seen[n].version) or "no addon"))
  end
end
