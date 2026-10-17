-- ZugLoot/AutoRoll.lua
-- Per-character auto-roll for SR'd items + auto-resolve readiness.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.AutoRoll = M

function M.IsOn() return Z.CharDB and Z.CharDB.autoRoll end

function M.Set(s)
  s = string.lower(Z.Util.Trim(s or ""))
  if s == "on" then Z.CharDB.autoRoll = true
  elseif s == "off" then Z.CharDB.autoRoll = false end
  Z.Print("auto-roll " .. (M.IsOn() and "ON" or "OFF"))
end

function M.PlayerSRd(itemID)
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then return false end
  local me = UnitName("player")
  local rollers = Z.SRData.GetRollers(sheet, itemID)
  for i = 1, Z.Util.ArrayCount(rollers) do
    if rollers[i].name == me and not Z.SRData.HasWon(sheet, itemID, me) then
      return true
    end
  end
  return false
end

-- How many times the local player reserved this item (x2 = two rolls).
function M.PlayerAllowance(itemID)
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then return 1 end
  local me = UnitName("player")
  local rollers = Z.SRData.GetRollers(sheet, itemID)
  for i = 1, Z.Util.ArrayCount(rollers) do
    if rollers[i].name == me then
      local n = tonumber(rollers[i].rolls) or 1
      if n < 1 then n = 1 end
      return n
    end
  end
  return 1
end

function M.MaybeAutoRoll(itemLink)
  if not M.IsOn() then return end
  local itemID = Z.Util.ItemID(itemLink)
  if not itemID then return end
  if M.PlayerSRd(itemID) then
    local n = M.PlayerAllowance(itemID)
    local k = 1
    while k <= n do
      Z.Print("Auto-rolling SR (" .. itemLink .. ")")
      RandomRoll(1, Z.Caps.SR)
      k = k + 1
    end
  end
end

-- Auto-resolve: true when every eligible SR roller is version-green + auto-on.
-- Skeleton heuristic: all known versions current (VersionGrid tracks flags).
function M.AllGreenAndAuto()
  if Z.VersionGrid and Z.VersionGrid.AllCurrent() then return true end
  return false
end
