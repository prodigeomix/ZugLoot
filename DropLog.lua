-- ZugLoot/DropLog.lua
-- Drop/audit log: every observed drop + award. Ring buffer (cap 500).
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.DropLog = M

function M.Add(itemID, itemLink, source, outcome, winner)
  Z.DB.drops = Z.DB.drops or {}
  table.insert(Z.DB.drops, {
    t = (time and time()) or 0,
    itemID = itemID,
    link = itemLink,
    source = source or "?",
    outcome = outcome or "?",
    winner = winner,
  })
  while Z.Util.ArrayCount(Z.DB.drops) > Z.Limits.DROP_LOG_MAX do
    table.remove(Z.DB.drops, 1)
  end
  if Z.Comm and outcome == "award" then
    -- awards already broadcast by MasterLootUI; log-only here.
  end
end

function M.Clear()
  if not Z.SRSecurity.CanImport() then
    Z.Print("Only the master looter or raid leader can clear the log.")
    return
  end
  Z.DB.drops = {}
  Z.Print("Drop log cleared.")
end

function M.Lines()
  local out = {}
  local n = Z.Util.ArrayCount(Z.DB.drops or {})
  for i = n, 1, -1 do
    local d = Z.DB.drops[i]
    table.insert(out, tostring(d.t) .. " [" .. tostring(d.source) .. "] " .. tostring(d.link or d.itemID) ..
      " " .. tostring(d.outcome) .. (d.winner and (" -> " .. d.winner) or ""))
  end
  if Z.Util.ArrayCount(out) == 0 then table.insert(out, "(log empty)") end
  return out
end

local logFrame = nil
function M.Show()
  if not logFrame then
    logFrame = CreateFrame("Frame", "ZugLootLogFrame", UIParent)
    logFrame:SetWidth(460) logFrame:SetHeight(300)
    logFrame:SetPoint("CENTER", UIParent, "CENTER", -200, 0)
    logFrame:SetMovable(true) logFrame:EnableMouse(true)
    logFrame:RegisterForDrag("LeftButton")
    logFrame:SetScript("OnDragStart", function() logFrame:StartMoving() end)
    logFrame:SetScript("OnDragStop", function() logFrame:StopMovingOrSizing() end)
    logFrame:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    logFrame:SetBackdropColor(0, 0, 0, 0.9)
    local t = logFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOP", logFrame, "TOP", 0, -10)
    t:SetText("ZugLoot — Drop log")
    local c = logFrame:CreateFontString("ZugLootLogContent", "OVERLAY", "GameFontHighlightSmall")
    c:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 14, -40)
    c:SetWidth(432) c:SetJustifyH("LEFT") c:SetJustifyV("TOP")
    local cb = CreateFrame("Button", nil, logFrame, "UIPanelButtonTemplate")
    cb:SetWidth(80) cb:SetHeight(22)
    cb:SetPoint("BOTTOM", logFrame, "BOTTOM", 0, 12)
    cb:SetText("Close")
    cb:SetScript("OnClick", function() logFrame:Hide() end)
    logFrame:Hide()
  end
  local c = getglobal("ZugLootLogContent")
  if c then
    local ls = M.Lines()
    local show = {}
    for i = 1, math.min(Z.Util.ArrayCount(ls), 25) do table.insert(show, ls[i]) end
    c:SetText(table.concat(show, "\n"))
  end
  logFrame:Show()
  for i = 1, Z.Util.ArrayCount(M.Lines()) do Z.Print(M.Lines()[i]) end
end
