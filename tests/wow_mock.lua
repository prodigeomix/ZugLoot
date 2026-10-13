-- tests/wow_mock.lua
-- Minimal globals so UI files at least parse under stock lua (not executed).
-- Pure modules (Util/SRData/Resolver) need no mock.
CreateFrame = CreateFrame or function() return nil end
UIParent = UIParent or {}
DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME or nil
SLASH_ZUGLOOT1 = nil
SlashCmdList = SlashCmdList or {}
StaticPopupDialogs = StaticPopupDialogs or {}
function StaticPopup_Show() return nil end
function getglobal() return nil end
function SendChatMessage() end
function SendAddonMessage() end
function RandomRoll() end
function UnitName() return "TestPlayer" end
function GetNumRaidMembers() return 0 end
function GetLootMethod() return nil end
function GetLootMaster() return nil end
function IsRaidLeader() return false end
function IsRaidOfficer() return false end
function IsPartyLeader() return false end
