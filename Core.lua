-- ZugLoot/Core.lua
-- Namespace bootstrap, SavedVariables defaults, event frame, slash commands.
-- (In-game only; tests load pure files directly.)
ZugLoot = ZugLoot or {}
local Z = ZugLoot

Z.DB = nil
Z.CharDB = nil

function Z.Print(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700ZugLoot:|r " .. tostring(msg or ""))
  end
end

function Z.InitDB()
  ZugLootDB = ZugLootDB or {}
  ZugLootCharDB = ZugLootCharDB or {}
  ZugLootDB.sheet = ZugLootDB.sheet or nil
  ZugLootDB.raidArchive = ZugLootDB.raidArchive or {}
  ZugLootDB.drops = ZugLootDB.drops or {}
  ZugLootDB.rollTime = ZugLootDB.rollTime or Z.Limits.ROLL_TIMEOUT_DEFAULT
  ZugLootDB.autoClose = (ZugLootDB.autoClose == nil) and true or ZugLootDB.autoClose
  ZugLootCharDB.autoRoll = ZugLootCharDB.autoRoll or false
  ZugLootCharDB.verSeen = ZugLootCharDB.verSeen or {}
  Z.DB = ZugLootDB
  Z.CharDB = ZugLootCharDB
end

local frame = nil
function Z.OnEvent(event, arg1, arg2, arg3, arg4)
  if event == "ADDON_LOADED" and arg1 == "ZugLoot" then
    Z.InitDB()
    Z.Print("loaded v" .. tostring(Z.VERSION) .. ". /zl help")
    if Z.VersionGrid then Z.VersionGrid.Announce() end
  elseif Z.Comm then
    Z.Comm.OnEvent(event, arg1, arg2, arg3, arg4)
  end
  if Z.MasterLootUI and Z.MasterLootUI.OnEvent then Z.MasterLootUI.OnEvent(event, arg1, arg2, arg3, arg4) end
  if Z.RaiderLootUI and Z.RaiderLootUI.OnEvent then Z.RaiderLootUI.OnEvent(event, arg1, arg2, arg3, arg4) end
end

function Z.Init()
  frame = CreateFrame("Frame", "ZugLootFrame")
  frame:RegisterEvent("ADDON_LOADED")
  frame:RegisterEvent("CHAT_MSG_ADDON")
  frame:RegisterEvent("CHAT_MSG_SYSTEM")
  frame:RegisterEvent("CHAT_MSG_RAID_WARNING")
  frame:RegisterEvent("LOOT_OPENED")
  frame:RegisterEvent("RAID_ROSTER_UPDATE")
  frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
  frame:SetScript("OnEvent", function() Z.OnEvent(event, arg1, arg2, arg3, arg4) end)
  SLASH_ZUGLOOT1 = "/zl"
  SLASH_ZUGLOOT2 = "/zugloot"
  SlashCmdList["ZUGLOOT"] = function(msg) Z.Slash(msg) end
end

function Z.Slash(msg)
  msg = (Z.Util and Z.Util.Trim(msg or "")) or tostring(msg or "")
  local cmd, rest = string.match(msg, "^(%S+)%s*(.*)$")
  cmd = string.lower(cmd or "")
  rest = rest or ""
  if cmd == "" or cmd == "help" then
    Z.Print("/zl sheet|raids|raid <id>|import|loadfile|rf|arf|rr|2x|fr|cr|show|hide|time|autoclose|auto|ver|verlist|sim|simboss|log|logclear|reset|help")
  elseif cmd == "sheet" then Z.MainWindow.Toggle("sheet")
  elseif cmd == "raids" then Z.MainWindow.Toggle("raids")
  elseif cmd == "raid" then Z.SRImport.ActivateArchivedRaid((Z.Util and Z.Util.Trim(rest) ~= "" and Z.Util.Trim(rest)) or nil)
  elseif cmd == "import" then Z.SRImport.ShowPaste()
  elseif cmd == "loadfile" then Z.SRImport.LoadFromFile()
  elseif cmd == "rf" then Z.MasterLootUI.StartRoll(rest, "SR")
  elseif cmd == "arf" then Z.MasterLootUI.StartRoll(rest, "OPEN")
  elseif cmd == "rr" then Z.MasterLootUI.StartRoll(rest, "RAID")
  elseif cmd == "2x" then Z.MasterLootUI.StartRoll(rest, "TWO")
  elseif cmd == "fr" then Z.MasterLootUI.FinishEarly()
  elseif cmd == "cr" then Z.MasterLootUI.Cancel()
  elseif cmd == "show" then Z.RaiderLootUI.Show()
  elseif cmd == "hide" then Z.RaiderLootUI.Hide()
  elseif cmd == "time" then Z.RaiderLootUI.SetTime(tonumber(rest))
  elseif cmd == "autoclose" then Z.RaiderLootUI.SetAutoClose(rest)
  elseif cmd == "auto" then Z.AutoRoll.Set(rest)
  elseif cmd == "ver" then Z.MainWindow.Toggle("versions")
  elseif cmd == "verlist" then Z.VersionGrid.PrintList()
  elseif cmd == "sim" then Z.Sim.SimItem(rest)
  elseif cmd == "simboss" then Z.Sim.SimBoss(rest)
  elseif cmd == "log" then Z.MainWindow.Toggle("rolls")
  elseif cmd == "logclear" then Z.DropLog.Clear()
  elseif cmd == "reset" then Z.SRImport.ResetWon()
  else Z.Print("unknown command. /zl help")
  end
end

Z.Init()
