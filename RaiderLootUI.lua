-- ZugLoot/RaiderLootUI.lua
-- Raider roll window, LootBlare look-and-feel: compact dark frame, green
-- countdown bar on top, big item icon + quality-colored name, two-column
-- roll list (class-colored names left, "roll (min-max)" in roll-type color
-- right, grouped SR > MS > OS > TMOG), four dice buttons at the bottom,
-- top-screen winner banner. Works for master-loot AND group-loot drops.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.RaiderLootUI = M

local frame = nil
local itemIcon = nil
local iconButton = nil
local itemName = nil
local timerText = nil
local leftText = nil
local rightText = nil
local statusBar = nil
local statusText = nil
local resultFrame = nil
local resultText = nil

local timeLeft = 0
local duration = 15
local active = false

M.rolls = {}

local RAID_CLASS_COLORS = {
  ["Warrior"] = "FFC79C6E",
  ["Mage"]    = "FF69CCF0",
  ["Rogue"]   = "FFFFF569",
  ["Druid"]   = "FFFF7D0A",
  ["Hunter"]  = "FFABD473",
  ["Shaman"]  = "FF0070DE",
  ["Priest"]  = "FFFFFFFF",
  ["Warlock"] = "FF9482C9",
  ["Paladin"] = "FFF58CBA",
}

local ROLL_BUTTONS = {
  { label = "SR", type = "SR", capKey = "SR", color = "ffe5302d",
    rgb = { 0.898, 0.188, 0.176 }, tip = "Roll for Soft Reserve" },
  { label = "MS", type = "MS", capKey = "MS", color = "FFFFFF00",
    rgb = { 1.0, 1.0, 0.0 }, tip = "Roll for Main Spec" },
  { label = "OS", type = "OS", capKey = "OS", color = "FF00FF00",
    rgb = { 0.0, 1.0, 0.0 }, tip = "Roll for Off Spec" },
  { label = "TM", type = "TMOG", capKey = "TMOG", color = "FF00FFFF",
    rgb = { 0.0, 1.0, 1.0 }, tip = "Roll for Transmog" },
}

local ROLL_GROUP_ORDER = { "SR", "MS", "OS", "TMOG" }

local function caps()
  if Z.Caps then return Z.Caps end
  return { SR = 100, MS = 100, OS = 99, TMOG = 98 }
end

local function rangeFor(rtype)
  local c = caps()
  if rtype == "OS" then return 1, (c.OS or 99) end
  if rtype == "TMOG" then return 1, (c.TMOG or 98) end
  return 1, (c.SR or 100)
end

-- Class name for roll-list coloring: raid roster first, then self.
-- Anything missing (solo, tests) falls back to nil = white.
function M.PlayerClass(name)
  if not name then return nil end
  if GetNumRaidMembers and GetRaidRosterInfo and GetNumRaidMembers() > 0 then
    for i = 1, GetNumRaidMembers() do
      local n, _, _, _, class = GetRaidRosterInfo(i)
      if n == name then return class end
    end
  end
  if UnitName and UnitClass and name == UnitName("player") then
    local class = UnitClass("player")
    return class
  end
  return nil
end

local function classColorHex(class)
  return RAID_CLASS_COLORS[class] or "FFFFFFFF"
end

local function typeColorHex(rtype)
  for i = 1, 4 do
    if ROLL_BUTTONS[i].type == rtype then return ROLL_BUTTONS[i].color end
  end
  return "FFFFFFFF"
end

-- Re-render the two-column list: grouped SR > MS > OS > TMOG, best roll
-- first within a group, capped at 8 visible rows (LootBlare parity).
local function RenderRolls()
  if not leftText or not rightText then return end
  local groups = { SR = {}, MS = {}, OS = {}, TMOG = {} }
  for i = 1, Z.Util.ArrayCount(M.rolls) do
    local r = M.rolls[i]
    local g = groups[r.rtype] or groups.MS
    table.insert(g, r)
  end
  for _, key in ipairs(ROLL_GROUP_ORDER) do
    table.sort(groups[key], function(a, b) return (a.roll or 0) > (b.roll or 0) end)
  end
  local left, right, count = {}, {}, 0
  for _, key in ipairs(ROLL_GROUP_ORDER) do
    local g = groups[key]
    for i = 1, Z.Util.ArrayCount(g) do
      if count >= 8 then break end
      local r = g[i]
      local hex = classColorHex(r.class)
      local name = string.sub(tostring(r.player or "?"), 1, 15)
      if r.excluded then
        table.insert(left, "|cff888888" .. name .. "|r")
        table.insert(right, "|cff888888" .. tostring(r.roll) .. " (" .. r.minR .. "-" .. r.maxR .. ") won|r")
      else
        table.insert(left, "|c" .. hex .. name .. "|r")
        table.insert(right, "|c" .. typeColorHex(r.rtype)
          .. string.format("%2d (%d-%d)", r.roll, r.minR, r.maxR) .. "|r")
      end
      count = count + 1
    end
    if count >= 8 then break end
  end
  leftText:SetText(table.concat(left, "\n"))
  rightText:SetText(table.concat(right, "\n"))
end

local function ClearRolls()
  M.rolls = {}
  if leftText then leftText:SetText("") end
  if rightText then rightText:SetText("") end
end

local function SetItemInfo(link)
  local iconPath = "Interface\\Icons\\INV_Misc_QuestionMark"
  local name, quality = nil, nil
  if link and GetItemInfo then
    local id = string.match(tostring(link), "item:(%d+)")
    if id then
      local n, _, q, _, _, _, _, _, tex = GetItemInfo(tonumber(id))
      if n then
        name, quality = n, q
        if tex then iconPath = tex end
      end
    end
  end
  if itemIcon then itemIcon:SetTexture(iconPath) end
  if iconButton and iconButton.SetNormalTexture then iconButton:SetNormalTexture(iconPath) end
  if itemName then
    if name and quality and GetItemQualityColor then
      local _, _, _, hex = GetItemQualityColor(quality)
      itemName:SetText((hex or "") .. tostring(name) .. "|r")
    else
      itemName:SetText(tostring(link or "?"))
    end
  end
  if frame then
    if quality and GetItemQualityColor then
      local r, g, b = GetItemQualityColor(quality)
      frame:SetBackdropBorderColor(r or 0.2, g or 0.2, b or 0.2)
    else
      frame:SetBackdropBorderColor(0.2, 0.2, 0.2)
    end
  end
  M.itemLink = link
end

function M.Build()
  frame = CreateFrame("Frame", "ZugLootLootFrame", UIParent)
  frame:SetWidth(220) frame:SetHeight(250)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
  frame:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  frame:SetBackdropColor(0, 0, 0, 0.85)
  frame:SetBackdropBorderColor(0.2, 0.2, 0.2)
  frame:SetMovable(true) frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function() frame:StartMoving() end)
  frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
  if frame.SetClampedToScreen then frame:SetClampedToScreen(true) end

  local xb = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  xb:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -10)
  xb:SetScript("OnClick", function() M.Hide() end)

  -- Countdown bar floating above the frame (LootBlare placement).
  statusBar = CreateFrame("StatusBar", nil, frame)
  statusBar:SetWidth(200) statusBar:SetHeight(16)
  statusBar:SetPoint("TOP", frame, "TOP", 0, 20)
  statusBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  statusBar:SetStatusBarColor(0.2, 0.7, 0.2, 1)
  statusBar:Hide()
  statusText = statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  statusText:SetPoint("CENTER", statusBar, "CENTER", 0, 0)

  -- Item icon + name header.
  itemIcon = frame:CreateTexture(nil, "ARTWORK")
  itemIcon:SetWidth(40) itemIcon:SetHeight(40)
  itemIcon:SetPoint("TOP", frame, "TOP", 0, -10)
  iconButton = CreateFrame("Button", nil, frame)
  iconButton:SetWidth(40) iconButton:SetHeight(40)
  iconButton:SetPoint("TOP", frame, "TOP", 0, -10)
  iconButton:SetScript("OnEnter", function()
    if GameTooltip and M.itemLink then
      GameTooltip:SetOwner(iconButton, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(M.itemLink)
      GameTooltip:Show()
    end
  end)
  iconButton:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  iconButton:SetScript("OnClick", function()
    if IsControlKeyDown and IsControlKeyDown() and DressUpItemLink then
      DressUpItemLink(M.itemLink)
    elseif IsShiftKeyDown and IsShiftKeyDown() and ChatFrameEditBox
        and ChatFrameEditBox:IsVisible() and M.itemLink and GetItemInfo then
      local n, link, q = GetItemInfo(M.itemLink)
      if n and link then ChatFrameEditBox:Insert(link) end
    end
  end)

  timerText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  timerText:SetPoint("CENTER", frame, "TOPLEFT", 30, -32)
  if timerText.SetFont then
    local f = timerText:GetFont()
    if f then timerText:SetFont(f, 20) end
  end

  itemName = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  itemName:SetPoint("TOP", itemIcon, "BOTTOM", 0, -10)
  itemName:SetWidth(200)
  itemName:SetJustifyH("CENTER")

  -- Two-column roll list.
  leftText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  leftText:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -73)
  leftText:SetJustifyH("LEFT")
  leftText:SetWidth(130)
  leftText:SetHeight(150)
  rightText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  rightText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -73)
  rightText:SetJustifyH("RIGHT")
  rightText:SetWidth(120)
  rightText:SetHeight(150)

  -- Dice buttons along the bottom.
  local panelW = 220
  local bw, n = 32, 4
  local spacing = (panelW - (n * bw)) / (n + 1)
  for i = 1, n do
    local b = ROLL_BUTTONS[i]
    local btn = CreateFrame("Button", nil, frame)
    btn:SetWidth(bw + 10) btn:SetHeight(bw + 6)
    btn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT",
      i * spacing + (i - 1) * bw - 6, 5)
    btn:SetText(b.label)
    local font = btn:GetFontString()
    if font then
      if font.SetFont then font:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE") end
      font:SetPoint("TOP", btn, "TOP", 0, -3)
      font:SetTextColor(0.7, 0.7, 0.7)
    end
    btn:SetBackdrop({ edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      edgeSize = 12, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    local rgb = b.rgb
    btn:SetBackdropBorderColor(rgb[1] * 0.7, rgb[2] * 0.7, rgb[3] * 0.7, 1)
    btn:SetScript("OnEnter", function()
      btn:SetBackdropBorderColor(rgb[1], rgb[2], rgb[3], 1)
      if font then font:SetTextColor(1, 1, 1) end
      if GameTooltip then
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
        local cap = (caps()[b.capKey] or 100)
        GameTooltip:SetText(b.tip .. " (1-" .. cap .. ")", 1, 1, 1, 1, true)
        GameTooltip:Show()
      end
    end)
    btn:SetScript("OnLeave", function()
      btn:SetBackdropBorderColor(rgb[1] * 0.7, rgb[2] * 0.7, rgb[3] * 0.7, 1)
      if font then font:SetTextColor(0.7, 0.7, 0.7) end
      if GameTooltip then GameTooltip:Hide() end
    end)
    local btype, bcap = b.type, (caps()[b.capKey] or 100)
    btn:SetScript("OnClick", function() M.DoRoll(btype, bcap) end)
  end

  frame:SetScript("OnUpdate", function()
    if not active then return end
    timeLeft = timeLeft - (arg1 or 0)
    local remaining = timeLeft
    if remaining < 0 then remaining = 0 end
    if statusBar and statusBar:IsShown() then
      statusBar:SetValue(remaining)
      if statusText then statusText:SetText(string.format("%.0fs", remaining)) end
      local pct = (duration > 0) and (remaining / duration) or 0
      if pct < 0.25 then
        statusBar:SetStatusBarColor(1, 0.1, 0.1)
      elseif pct < 0.5 then
        statusBar:SetStatusBarColor(1, 0.6, 0)
      else
        statusBar:SetStatusBarColor(0.2, 0.7, 0.2)
      end
      if remaining <= 5 and remaining > 0 and GetTime then
        statusBar:SetAlpha(0.5 + 0.5 * math.sin(GetTime() * 15))
      else
        statusBar:SetAlpha(1)
      end
    end
    if timerText then timerText:SetText(string.format("%.0f", remaining)) end
    if timeLeft <= 0 then
      if statusBar then statusBar:Hide() statusBar:SetAlpha(1) end
      local autoClose = (Z.DB and Z.DB.autoClose ~= false)
      if autoClose then M.Hide()
      else active = false end
    end
  end)
  frame:Hide()
end

-- Top-screen winner banner (LootBlare ShowRollResultMessage parity).
function M.ShowResult(message)
  if not resultFrame then
    resultFrame = CreateFrame("Frame", "ZugLootRollResultFrame", UIParent)
    resultFrame:SetWidth(600) resultFrame:SetHeight(80)
    resultFrame:SetPoint("TOP", UIParent, "TOP", 0, -100)
    resultText = resultFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    resultText:SetAllPoints()
    resultText:SetJustifyH("CENTER")
    resultText:SetJustifyV("MIDDLE")
    resultFrame:Hide()
  end
  resultText:SetText(message or "")
  resultFrame:Show()
  if GetTime then
    local startTime = GetTime()
    resultFrame:SetScript("OnUpdate", function()
      if GetTime() - startTime >= 5 then
        resultFrame:Hide()
        resultFrame:SetScript("OnUpdate", nil)
      end
    end)
  end
end

function M.ShowItem(itemLink, seconds)
  if not frame then M.Build() end
  duration = seconds or (Z.DB and Z.DB.rollTime) or 15
  timeLeft = duration
  ClearRolls()
  SetItemInfo(itemLink)
  if statusBar then
    statusBar:SetMinMaxValues(0, duration)
    statusBar:SetValue(duration)
    statusBar:SetAlpha(1)
    if statusText then statusText:SetText(duration .. "s") end
    statusBar:Show()
  end
  if UIFrameFadeIn and frame.SetAlpha then
    frame:SetAlpha(0)
    UIFrameFadeIn(frame, 0.5, 0, 1)
  end
  active = true
  frame:Show()
  -- Auto-roll path.
  if Z.AutoRoll and Z.AutoRoll.MaybeAutoRoll then Z.AutoRoll.MaybeAutoRoll(itemLink) end
end

function M.OnRoll(player, roll, rtype, excluded)
  if not frame or not frame:IsVisible() then return end
  local minR, maxR = rangeFor(rtype)
  table.insert(M.rolls, { player = player, roll = roll, rtype = rtype,
    minR = minR, maxR = maxR, excluded = excluded,
    class = M.PlayerClass(player) })
  RenderRolls()
  timeLeft = (Z.DB and Z.DB.rollTime) or 15 -- refresh on activity (LootBlare parity)
end

function M.DoRoll(rtype, cap)
  RandomRoll(1, cap)
  if Z.MasterLootUI.session then
    Z.Comm.SendRollAns(Z.MasterLootUI.session.id, rtype)
  end
end

function M.OnRollReq(msg, sender)
  -- ROLL_REQ:<session>:<link>:<mode>; verify sender is ML (LootBlare rule).
  local link = string.match(msg, "ROLL_REQ:%d+:(.+):%w+$")
  local mode = string.match(msg, ":(%w+)$")
  if Z.SRSecurity.IsML(sender) or sender == nil then
    M.ShowItem(link or msg, (Z.DB and Z.DB.rollTime) or 15)
  end
end

function M.OnEvent(event, a1, a2)
  if event == "CHAT_MSG_RAID_WARNING" then
    -- LootBlare trigger: ML links item in RW. Verify sender is ML (raid-safe).
    local sender = a2
    local link = string.match(tostring(a1 or ""), "(|c%x+|Hitem.-|h%[.-%]|h|r)")
    if link and sender and Z.SRSecurity.IsML(sender) then
      M.ShowItem(link, (Z.DB and Z.DB.rollTime) or 15)
    end
  end
end

function M.Show() if not frame then M.Build() end frame:Show() end
function M.Hide()
  if frame then frame:Hide() end
  active = false
  ClearRolls()
end

function M.SetTime(n)
  if n and n > 0 then Z.DB.rollTime = n Z.Print("Roll time set to " .. n .. "s") end
end

function M.SetAutoClose(s)
  s = string.lower(Z.Util.Trim(s or ""))
  if s == "on" then Z.DB.autoClose = true
  elseif s == "off" then Z.DB.autoClose = false end
  Z.Print("autoclose " .. tostring(Z.DB.autoClose))
end
