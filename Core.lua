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

-- Factory reset: wipe all SavedVariables (account + character) and reapply
-- defaults via InitDB. Clears session data too (active sheet, raid archive,
-- drop log). Deliberately NOT permission-gated: everything touched is local
-- client state (a raider must be able to recover a broken local setup, and
-- the raid can always rebroadcast the sheet). Testable core.
function Z.DoResetAllSettings()
  if ZugLootDB then for k in pairs(ZugLootDB) do ZugLootDB[k] = nil end end
  if ZugLootCharDB then for k in pairs(ZugLootCharDB) do ZugLootCharDB[k] = nil end end
  Z.InitDB()
  if Z.VersionGrid and Z.VersionGrid.seen then Z.VersionGrid.seen = {} end
  if Z.MainWindow then Z.MainWindow.Refresh() end
  if Z.SRView then Z.SRView.Refresh() end
end

-- Button/slash entry point with confirmation window. Outside the client
-- (no StaticPopup API) the confirm is skipped so tests can use it directly.
function Z.RequestResetAllSettings()
  if not (StaticPopupDialogs and StaticPopup_Show) then
    Z.DoResetAllSettings()
    Z.Print("All ZugLoot settings reset to defaults (sheet, history, log and options cleared).")
    return
  end
  StaticPopupDialogs["ZUGLOOT_RESET_ALL"] = StaticPopupDialogs["ZUGLOOT_RESET_ALL"] or {
    text = "Reset ALL ZugLoot settings?\nActive sheet, raid history, drop log and all options return to defaults. This cannot be undone.",
    button1 = "Reset all", button2 = "Cancel",
    OnAccept = function()
      Z.DoResetAllSettings()
      Z.Print("All ZugLoot settings reset to defaults (sheet, history, log and options cleared).")
    end,
    timeout = 0, whileDead = 1,
  }
  StaticPopup_Show("ZUGLOOT_RESET_ALL")
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
  -- Timer driver: advances ZugLoot.Timer on every frame (vanilla 1.12 has
  -- no C_Timer). Guarded so Core loads even if Timer.lua is absent.
  if Z.Timer then
    local tf = CreateFrame("Frame", "ZugLootTimerFrame")
    tf:SetScript("OnUpdate", function() Z.Timer.Update(arg1) end)
  end
end

function Z.Slash(msg)
  msg = (Z.Util and Z.Util.Trim(msg or "")) or tostring(msg or "")
  local cmd, rest = string.match(msg, "^(%S+)%s*(.*)$")
  cmd = string.lower(cmd or "")
  rest = rest or ""
  if cmd == "" or cmd == "help" then
    Z.Print("/zl sheet|raids|raid <id>|import|loadfile|rf|arf|rr|2x|roll|award|fr|cr|trade|show|hide|time|autoclose|auto|ver|verlist|sim|simboss|simtmog|simroll|simstop|log|logclear|reset|help")
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
  elseif cmd == "simtmog" then Z.Sim.SimTmog(rest)
  elseif cmd == "simroll" then Z.Sim.RequestRoll(Z.Util.ItemID(rest))
  elseif cmd == "simstop" then Z.Sim.Stop()
  elseif cmd == "roll" then Z.MasterLootUI.StartItemRoll(rest)
  elseif cmd == "award" then
    if Z.MasterLootUI and Z.MasterLootUI.RequireML() then
      Z.MasterLootUI.AwardChosen({ name = Z.Util.Trim(rest), via = "menu" })
    end
  elseif cmd == "trade" then
    local link, from, to = string.match(rest or "", "(%S+)%s+(%S+)%s+(%S+)")
    local itemID = Z.Util.ItemID(link or "")
    if not itemID or not from or not to then
      Z.Print("Usage: /zl trade <itemlink|itemID> <from> <to>")
    elseif Z.MasterLootUI and Z.MasterLootUI.RequireML() then
      Z.MasterLootUI.RecordTrade(itemID, link, from, to, false)
    end
  elseif cmd == "log" then Z.MainWindow.Toggle("rolls")
  elseif cmd == "logclear" then Z.DropLog.Clear()
  elseif cmd == "reset" then Z.SRImport.ResetWon()
  else Z.Print("unknown command. /zl help")
  end
end

Z.Init()
