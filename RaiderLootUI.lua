-- ZugLoot/RaiderLootUI.lua
-- LootBlare-like raider frame: works for master-loot AND group-loot drops.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.RaiderLootUI = M

local frame = nil
local itemLabel = nil
local rollList = nil
local timerBar = nil
local timeLeft = 0
local active = false

local ROLL_BUTTONS = {
  { label = "SR", type = "SR", cap = 100, color = "ffe5302d" },
  { label = "MS", type = "MS", cap = 100, color = "FFFFFF00" },
  { label = "OS", type = "OS", cap = 99, color = "FF00FF00" },
  { label = "TM", type = "TMOG", cap = 98, color = "FF00FFFF" },
}

function M.Build()
  frame = CreateFrame("Frame", "ZugLootLootFrame", UIParent)
  frame:SetWidth(360) frame:SetHeight(220)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
  frame:SetMovable(true) frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function() frame:StartMoving() end)
  frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
  frame:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  frame:SetBackdropColor(0, 0, 0, 0.9)
  itemLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  itemLabel:SetPoint("TOP", frame, "TOP", 0, -12)
  itemLabel:SetWidth(330) itemLabel:SetJustifyH("CENTER")
  rollList = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  rollList:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -44)
  rollList:SetWidth(332) rollList:SetJustifyH("LEFT") rollList:SetJustifyV("TOP")
  rollList:SetText("")
  local x = 14
  for i = 1, 4 do
    local b = ROLL_BUTTONS[i]
    local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btn:SetWidth(60) btn:SetHeight(24)
    btn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, 12)
    btn:SetText(b.label)
    x = x + 70
    local btype, bcap = b.type, b.cap
    btn:SetScript("OnClick", function() M.DoRoll(btype, bcap) end)
  end
  frame:SetScript("OnUpdate", function()
    if not active then return end
    timeLeft = timeLeft - (arg1 or 0)
    if timeLeft <= 0 then
      if Z.DB.autoClose then M.Hide()
      else active = false end
    end
  end)
  frame:Hide()
end

function M.ShowItem(itemLink, seconds)
  if not frame then M.Build() end
  itemLabel:SetText(itemLink or "?")
  rollList:SetText("")
  timeLeft = seconds or Z.DB.rollTime or 15
  active = true
  frame:Show()
  -- Auto-roll path.
  if Z.AutoRoll then Z.AutoRoll.MaybeAutoRoll(itemLink) end
end

function M.OnRoll(player, roll, rtype)
  if not frame or not frame:IsVisible() then return end
  local color = "FFFFFFFF"
  for i = 1, 4 do if ROLL_BUTTONS[i].type == rtype then color = ROLL_BUTTONS[i].color end end
  rollList:SetText((rollList:GetText() or "") .. "\n|c" .. color .. player .. ": " .. roll .. " (" .. rtype .. ")|r")
  timeLeft = Z.DB.rollTime or 15 -- refresh on activity (LootBlare parity)
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
    M.ShowItem(link or msg, Z.DB.rollTime)
  end
end

function M.OnEvent(event, a1, a2)
  if event == "CHAT_MSG_RAID_WARNING" then
    -- LootBlare trigger: ML links item in RW. Verify sender is ML (raid-safe).
    local sender = a2
    local link = string.match(tostring(a1 or ""), "(|c%x+|Hitem.-|h%[.-%]|h|r)")
    if link and sender and Z.SRSecurity.IsML(sender) then
      M.ShowItem(link, Z.DB.rollTime)
    end
  end
end

function M.Show() if not frame then M.Build() end frame:Show() end
function M.Hide() if frame then frame:Hide() end active = false end

function M.SetTime(n)
  if n and n > 0 then Z.DB.rollTime = n Z.Print("Roll time set to " .. n .. "s") end
end

function M.SetAutoClose(s)
  s = string.lower(Z.Util.Trim(s or ""))
  if s == "on" then Z.DB.autoClose = true
  elseif s == "off" then Z.DB.autoClose = false end
  Z.Print("autoclose " .. tostring(Z.DB.autoClose))
end
