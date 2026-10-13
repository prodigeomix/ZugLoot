-- tests/test_settings_reset.lua
-- Factory reset: RequestResetAllSettings wipes SavedVariables (account +
-- character), clears session data and reapplies defaults, via confirm popup
-- when available and directly otherwise.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else T.pass = T.pass + 1 end
end
local function ok(v, msg)
  if not v then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else T.pass = T.pass + 1 end
end

-- Minimal frame mock for Core's Z.Init() at load.
local function blankFrame()
  local o = {}
  function o:RegisterEvent() end
  function o:SetScript() end
  return o
end
CreateFrame = function() return blankFrame() end
UIParent = {}
SlashCmdList = {}
DEFAULT_CHAT_FRAME = nil

ZugLoot = {}
dofile("Util.lua")
dofile("Constants.lua")
dofile("ClassColors.lua")
dofile("SRData.lua")
dofile("Core.lua")
local Z = ZugLoot

local printed = {}
Z.Print = function(m) table.insert(printed, tostring(m)) end

local function seedDirty()
  ZugLootDB = {
    sheet = Z.SRData.NewSheet(),
    raidArchive = { { raidID = "R1" } },
    drops = { { itemID = 1 } },
    rollTime = 99,
    autoClose = false,
    customKey = "must-go",
  }
  ZugLootCharDB = { autoRoll = true, verSeen = { X = true }, customChar = 1 }
  Z.DB = ZugLootDB
  Z.CharDB = ZugLootCharDB
  Z.VersionGrid = { seen = { Y = true } }
  Z.MainWindow = nil
  Z.SRView = nil
  printed = {}
end

-- 1. Direct path (no popup API): everything wiped, defaults reapplied.
StaticPopupDialogs = nil
StaticPopup_Show = nil
seedDirty()
Z.RequestResetAllSettings()
eq(Z.DB.rollTime, Z.Limits.ROLL_TIMEOUT_DEFAULT, "rollTime default restored")
eq(Z.DB.autoClose, true, "autoClose default restored")
eq(Z.DB.sheet, nil, "sheet cleared")
eq(#Z.DB.raidArchive, 0, "archive cleared")
eq(#Z.DB.drops, 0, "drops cleared")
eq(Z.DB.customKey, nil, "unknown account keys wiped")
eq(Z.CharDB.autoRoll, false, "autoRoll default restored")
eq(Z.CharDB.customChar, nil, "unknown char keys wiped")
ok(next(Z.CharDB.verSeen) == nil, "verSeen cleared")
ok(next(Z.VersionGrid.seen) == nil, "runtime version cache cleared")
ok(string.find(printed[#printed], "reset to defaults"), "confirmation printed")

-- 2. Second reset on clean state is a safe no-op.
printed = {}
Z.RequestResetAllSettings()
eq(Z.DB.rollTime, Z.Limits.ROLL_TIMEOUT_DEFAULT, "defaults hold")
ok(string.find(printed[#printed], "reset to defaults"), "still reports")

-- 3. Confirm path: popup defined, OnAccept performs the reset.
seedDirty()
StaticPopupDialogs = {}
local shown = nil
StaticPopup_Show = function(name) shown = name end
printed = {}
Z.RequestResetAllSettings()
eq(shown, "ZUGLOOT_RESET_ALL", "confirm popup shown")
-- nothing wiped yet (user hasn't confirmed):
eq(Z.DB.rollTime, 99, "no reset before confirm")
ok(StaticPopupDialogs["ZUGLOOT_RESET_ALL"] ~= nil, "dialog registered")
StaticPopupDialogs["ZUGLOOT_RESET_ALL"].OnAccept()
eq(Z.DB.rollTime, Z.Limits.ROLL_TIMEOUT_DEFAULT, "reset on accept")
eq(Z.DB.sheet, nil, "sheet cleared on accept")
StaticPopupDialogs = nil
StaticPopup_Show = nil

return T
