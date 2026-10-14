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
  -- Solo master-loot rehearsal (see /zl rehearse): every corpse item gets
  -- a roll window with invented rollers, then a real loot-through award.
  -- Persisted like other options; effect is solo-only. Absent = off.
  if ZugLootDB.rehearse == nil then ZugLootDB.rehearse = false end
  -- Master-loot auto-start (see /zl rollauto): rolls begin by themselves
  -- as corpses are looted. Default OFF — the ML picks each item's Roll
  -- button. General behaviour, not rehearsal-specific (rehearsal inherits
  -- it). Absent = off.
  if ZugLootDB.rollAuto == nil then ZugLootDB.rollAuto = false end
  -- Loot-takeover kill-switch state (see LootWindow.NoteSilentLoot):
  -- once our LootSlot path proves dead, the takeover stays OFF across
  -- corpses and sessions until the user opts back in. Survives reloads
  -- (a broken loot path won't fix itself on relog); re-arm via Setup tab
  -- or /zl lootframe. Never nil-guarded away: false is a valid state.
  if ZugLootDB.lootTakeover == nil then ZugLootDB.lootTakeover = true end
  ZugLootDB.autoClose = (ZugLootDB.autoClose == nil) and true or ZugLootDB.autoClose
  ZugLootCharDB.autoRoll = ZugLootCharDB.autoRoll or false
  ZugLootCharDB.verSeen = ZugLootCharDB.verSeen or {}
  -- Minimap button angle (degrees, 0 = top, clockwise). Persisted per
  -- character; nil = default position (Minimap.GetAngle handles it).
  if ZugLootCharDB.minimapAngle ~= nil then
    ZugLootCharDB.minimapAngle = tonumber(ZugLootCharDB.minimapAngle)
  end
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
    -- RollFor parity: detach Blizzard's loot frame for the whole session,
    -- so OUR loot window is the loot window in every looting situation.
    if Z.LootWindow and Z.LootWindow.DetachBlizzardLoot then
      pcall(Z.LootWindow.DetachBlizzardLoot)
    end
    if Z.VersionGrid then Z.VersionGrid.Announce() end
    -- Minimap die button (nil-safe: Build no-ops without frame APIs).
    if Z.Minimap then pcall(Z.Minimap.Build) end
  elseif Z.Comm then
    Z.Comm.OnEvent(event, arg1, arg2, arg3, arg4)
  end
  if Z.MasterLootUI and Z.MasterLootUI.OnEvent then Z.MasterLootUI.OnEvent(event, arg1, arg2, arg3, arg4) end
  if Z.RaiderLootUI and Z.RaiderLootUI.OnEvent then Z.RaiderLootUI.OnEvent(event, arg1, arg2, arg3, arg4) end
  if Z.LootWindow and Z.LootWindow.OnEvent then Z.LootWindow.OnEvent(event, arg1) end
end

function Z.Init()
  frame = CreateFrame("Frame", "ZugLootFrame")
  frame:RegisterEvent("ADDON_LOADED")
  frame:RegisterEvent("CHAT_MSG_ADDON")
  frame:RegisterEvent("CHAT_MSG_SYSTEM")
  frame:RegisterEvent("CHAT_MSG_RAID_WARNING")
  frame:RegisterEvent("LOOT_OPENED")
  frame:RegisterEvent("LOOT_CLOSED")
  frame:RegisterEvent("LOOT_SLOT_CLEARED")
  frame:RegisterEvent("START_LOOT_ROLL")
  frame:RegisterEvent("CANCEL_LOOT_ROLL")
  frame:RegisterEvent("LOOT_BIND_CONFIRM")
  frame:RegisterEvent("UI_ERROR_MESSAGE")
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
    Z.Print("/zl sheet|raids|raid <id>|import|loadfile|rf|arf|rr|2x|roll|award|fr|cr|show|hide|time|autoclose|auto|ver|verlist|sheetreq|sim|simboss|simtmog|simroll|simstop|log|logclear|reset|lootdebug|lootframe|rehearse|rollauto|help")
  elseif cmd == "sheet" then Z.MainWindow.Toggle("sheet")
  elseif cmd == "raids" then Z.MainWindow.Toggle("raids")
  elseif cmd == "raid" then Z.SRImport.ActivateArchivedRaid((Z.Util and Z.Util.Trim(rest) ~= "" and Z.Util.Trim(rest)) or nil)
  elseif cmd == "import" then Z.SRImport.ShowPaste()
  elseif cmd == "loadfile" then Z.SRImport.LoadFromFile()
  elseif cmd == "rf" then Z.MasterLootUI.StartRoll(rest, "SR")
  elseif cmd == "arf" then Z.MasterLootUI.StartRoll(rest, "OPEN")
  elseif cmd == "rr" then Z.MasterLootUI.StartRaidRoll(rest)
  elseif cmd == "2x" then Z.MasterLootUI.StartRoll(rest, "TWO")
  elseif cmd == "fr" then Z.MasterLootUI.FinishEarly(Z.Util.ItemID(rest))
  elseif cmd == "cr" then Z.MasterLootUI.Cancel(Z.Util.ItemID(rest))
  elseif cmd == "show" then Z.RaiderLootUI.Show()
  elseif cmd == "hide" then Z.RaiderLootUI.Hide()
  elseif cmd == "time" then Z.RaiderLootUI.SetTime(tonumber(rest))
  elseif cmd == "autoclose" then Z.RaiderLootUI.SetAutoClose(rest)
  elseif cmd == "auto" then Z.AutoRoll.Set(rest)
  elseif cmd == "ver" then Z.MainWindow.Toggle("versions")
  elseif cmd == "verlist" then Z.VersionGrid.PrintList()
  elseif cmd == "sheetreq" then Z.Comm.RequestSheet()
  elseif cmd == "sim" then Z.Sim.SimItem(rest)
  elseif cmd == "simboss" then Z.Sim.SimBoss(rest)
  elseif cmd == "simtmog" then Z.Sim.SimTmog(rest)
  elseif cmd == "simroll" then Z.Sim.RequestRoll(Z.Util.ItemID(rest))
  elseif cmd == "simstop" then Z.Sim.Stop()
  elseif cmd == "roll" then Z.MasterLootUI.StartItemRoll(rest)
  elseif cmd == "award" then
    if Z.MasterLootUI and Z.MasterLootUI.RequireML() then
      -- "/zl award Name [item]" — the item pins the decision when several
      -- award menus are pending; without it the open item decides.
      local nm, itemArg = string.match(rest, "^(%S+)%s*(.*)$")
      local itemID = Z.Util.ItemID(itemArg or "")
      Z.MasterLootUI.AwardChosen({ name = Z.Util.Trim(nm or ""), via = "menu" }, itemID)
    end
  elseif cmd == "lootdebug" then
    Z.LootWindow.lootDebug = not Z.LootWindow.lootDebug
    Z.Print("lootdebug " .. (Z.LootWindow.lootDebug and "ON" or "OFF"))
  elseif cmd == "rehearse" then
    if Z.Sim and Z.Sim.SetRehearse then Z.Sim.SetRehearse(rest) end
  elseif cmd == "rollauto" then
    if Z.DB then
      local s = string.lower(Z.Util.Trim(rest or ""))
      if s == "on" or s == "1" then Z.DB.rollAuto = true
      elseif s == "off" or s == "0" then Z.DB.rollAuto = false
      else Z.DB.rollAuto = not Z.DB.rollAuto end
      Z.Print("Auto-start rolls " .. (Z.DB.rollAuto and "ON" or "OFF"))
    end
  elseif cmd == "lootframe" then
    if Z.LootWindow and Z.LootWindow.TakeoverWanted() then
      Z.LootWindow.SetTakeoverWanted(false)
      Z.Print("Loot frame: Blizzard's. (/zl lootframe to switch back)")
    else
      Z.LootWindow.SetTakeoverWanted(true)
      Z.Print("Loot frame: ZugLoot. (takes over on the next corpse)")
    end
  elseif cmd == "log" then Z.DropLog.Show()
  elseif cmd == "logclear" then Z.DropLog.Clear()
  elseif cmd == "reset" then Z.SRImport.ResetWon()
  else Z.Print("unknown command. /zl help")
  end
end

Z.Init()
