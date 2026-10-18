-- tests/test_chat_routing.lua
-- Single chat router verification: sim and live rolls share Comm.Say —
-- only the CHANNEL differs by grouping. Solo -> ZugLoot log (Z.Print),
-- party -> PARTY, raid -> RAID (RAID_WARNING for warnings). Identical
-- text in every grouping, so solo sim output reads exactly like the
-- raid-night lines (verifiable without a raid).
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else T.pass = T.pass + 1 end
end
local function ok(v, msg)
  if not v then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else T.pass = T.pass + 1 end
end

ZugLoot = {}
dofile("Util.lua")
dofile("Constants.lua")
dofile("ClassColors.lua")
dofile("SRData.lua")
dofile("Resolver.lua")
dofile("ItemCards.lua")
dofile("Timer.lua")

ZugLoot.Caps = ZugLoot.Caps or { SR = 100, MS = 100, OS = 99, TMOG = 98 }
local printed = {} -- ZugLoot log (solo destination)
local sent = {} -- SendChatMessage calls: { msg, chan }
ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
SendChatMessage = function(msg, chan) table.insert(sent, { msg = tostring(msg), chan = tostring(chan) }) end
UnitName = function() return "SoloPlayer" end
GetNumRaidMembers = function() return 0 end
GetRaidRosterInfo = function() return nil end
time = time or os.time

local grouping = "solo"
ZugLoot.SRSecurity = {
  IsInRaid = function() return grouping == "raid" end,
  IsInParty = function() return grouping == "party" end,
  IsInGroup = function() return grouping ~= "solo" end,
  IsSolo = function() return grouping == "solo" end,
  AmML = function() return true end,
  MasterLooterName = function() return "SoloPlayer" end,
}
ZugLoot.RaiderLootUI = { ShowItem = function() end, OnRoll = function() end, Hide = function() end }
ZugLoot.DropLog = { Add = function() end }
ZugLoot.MainWindow = nil
ZugLoot.SRView = nil

dofile("RollList.lua")
dofile("Comm.lua")
dofile("LootWindow.lua")
dofile("MasterLootUI.lua")
dofile("Sim.lua")
local Sim = ZugLoot.Sim
local SRData = ZugLoot.SRData
local ML = ZugLoot.MasterLootUI
local LW = ZugLoot.LootWindow
ML.lootOpen = true

local function makeSheet()
  local s = SRData.NewSheet()
  s.items[1001] = { quality = 4, rollers = {
    { name = "Aaa", rolls = 1, sr_plus = 10 },
    { name = "Bbb", rolls = 2, sr_plus = nil },
  } }
  -- Sheet classes so chat pins cover the class color, not just the link.
  SRData.SetPlayerClass(s, "Aaa", "Paladin")
  SRData.SetPlayerClass(s, "Bbb", "Mage")
  return s
end

-- Player-link pins: clickable class color per name.
local LINK_AAA = "|cFFF58CBA|Hplayer:Aaa|h[Aaa]|h|r"
local LINK_BBB = "|cFF69CCF0|Hplayer:Bbb|h[Bbb]|h|r"

local function reset()
  ZugLoot.Timer.CancelAll()
  Sim.pending = {}
  Sim.running = false
  Sim.raid = nil
  Sim.FakeCount = 2
  ML.roll = nil
  ML.lastRound = nil
  LW.Clear()
  printed, sent = {}, {}
  ZugLoot.DB = { sheet = makeSheet(), rollTime = 30 }
  -- Named sim row so DisplayItemLink resolves like a live corpse row
  -- (sim queue entries carry links; the window row carries the name).
  LW.SetItems({ { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "sim")
end

local function rigged(values)
  local i = 0
  return function(lo, hi)
    i = i + 1
    local v = values[((i - 1) % #values) + 1]
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
  end
end
local realRandom = math.random

-- Chat snapshot helpers: what the user would SEE per grouping.
local function logText() return table.concat(printed, "\n") end
local function chatText()
  local out = {}
  for i = 1, #sent do table.insert(out, sent[i].msg) end
  return table.concat(out, "\n")
end
-- The ROLL lines only (start, fake/roll lines, verdict, award) —
-- harness notes (SIM item..., SIM: ... roll(s) in, SIM done...) live
-- in the local log in every grouping and never go on the wire.
local function rollLines(lines)
  local out = {}
  for i = 1, #lines do
    local l = lines[i]
    if not string.find(l, "^SIM item ", 1)
        and not string.find(l, "^SIM: ", 1)
        and not string.find(l, "^SIM done", 1)
        and not string.find(l, "^SIM raid", 1)
        and not string.find(l, "^SIM boss", 1)
        and not string.find(l, "^Loot window open", 1) then
      table.insert(out, l)
    end
  end
  return table.concat(out, "\n")
end
local function chatChans()
  local out = {}
  for i = 1, #sent do table.insert(out, sent[i].chan) end
  return table.concat(out, ",")
end

-- 1. Solo: everything lands in the ZugLoot log, nothing on the wire.
reset()
grouping = "solo"
math.random = rigged({ 90, 80 })
Sim.SimItem("|cffa335ee|Hitem:1001:::::::::|h[Dragonfang Blade]|h|r")
math.random = realRandom
LW.doAction(1001, "finish")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
eq(#sent, 0, "solo sends nothing (log only)")
local soloLog = logText()
ok(string.find(soloLog, "Roll ", 1, true) ~= nil, "solo log has roll-start")
ok(string.find(soloLog, LINK_AAA .. " rolls 90 (1-100)", 1, true) ~= nil, "solo log has fake roll line (linked)")
ok(string.find(soloLog, "won by " .. LINK_AAA .. " (100)", 1, true) ~= nil, "solo log has verdict (linked)")
ok(string.find(soloLog, LINK_AAA .. " wins ", 1, true) ~= nil, "solo log has award line (linked)")
-- Canonical roll text: the ROLL lines from the solo log (harness notes
-- stripped) — raid/party group-chat must match these byte-for-byte.
local soloRolls = rollLines(printed)

-- 2. Same sim IN RAID: identical text, but on RAID / RAID_WARNING.
reset()
grouping = "raid"
math.random = rigged({ 90, 80 })
Sim.SimItem("|cffa335ee|Hitem:1001:::::::::|h[Dragonfang Blade]|h|r")
math.random = realRandom
LW.doAction(1001, "finish")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(#sent > 0, "raid sim reaches group chat")
-- Line builders produce the same text solo printed locally...
local raidChat = chatText()
ok(string.find(raidChat, LINK_AAA .. " rolls 90 (1-100)", 1, true) ~= nil, "raid sim roll line matches solo text")
ok(string.find(raidChat, "won by " .. LINK_AAA .. " (100)", 1, true) ~= nil, "raid sim verdict matches solo text")
ok(string.find(raidChat, LINK_AAA .. " wins ", 1, true) ~= nil, "raid sim award matches solo text")
eq(raidChat, soloRolls,
  "raid sim group-chat text == solo log roll lines")
-- ...on the group channels only (start is a warning).
ok(string.find(chatChans(), "RAID_WARNING", 1, true) ~= nil, "roll-start warns the raid")
ok(string.find(chatChans(), "RAID", 1, true) ~= nil, "roll traffic on RAID")
for i = 1, #sent do
  ok(sent[i].chan == "RAID" or sent[i].chan == "RAID_WARNING", "raid sends RAID/RAID_WARNING only")
end
eq(#printed, 3, "raid sim keeps only harness lines local (queue/drain notes)")

-- 3. Same sim IN PARTY: identical text on PARTY (warnings degrade: no
-- party warning channel exists).
reset()
grouping = "party"
math.random = rigged({ 90, 80 })
Sim.SimItem("|cffa335ee|Hitem:1001:::::::::|h[Dragonfang Blade]|h|r")
math.random = realRandom
LW.doAction(1001, "finish")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
ok(#sent > 0, "party sim reaches party chat")
for i = 1, #sent do
  eq(sent[i].chan, "PARTY", "party sends PARTY only (no warnings)")
end
eq(chatText(), raidChat, "party text == raid text (channel only differs)")

-- 4. LIVE roll shares the path: same builders, same channels.
reset()
grouping = "raid"
LW.SetItems({ { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "loot")
LW.OpenDetail(1001)
LW.doAction(1001, "roll")
ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
ML.IntakeChatRoll("Bbb rolls 80 (1-100)")
LW.doAction(1001, "finish")
ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
local liveChat = chatText()
-- Chat lines carry REAL clickable links, never bare white text.
ok(string.find(liveChat, "|Hitem:1001", 1, true) ~= nil, "live roll-start links the item")
ok(string.find(liveChat, "Roll |c", 1, true) ~= nil, "live roll-start is quality-colored")
-- Live intake does NOT re-announce (the player's own /roll system
-- message is already in chat): only start + verdict + award go out.
ok(string.find(liveChat, "Aaa rolls 90", 1, true) == nil, "live intake stays quiet (no double line)")
ok(string.find(liveChat, "won by " .. LINK_AAA .. " (100)", 1, true) ~= nil, "live verdict shares the builder")
ok(string.find(liveChat, LINK_AAA .. " wins |c", 1, true) ~= nil, "live award shares the builder (linked)")
for i = 1, #sent do
  ok(sent[i].chan == "RAID" or sent[i].chan == "RAID_WARNING", "live raid sends RAID/RAID_WARNING only")
end
-- The sim fake line and the shared builder agree word-for-word.
eq(ML.RollLine({ name = "Aaa", roll = 90, min = 1, max = 100 }), LINK_AAA .. " rolls 90 (1-100)", "RollLine format pinned")
LW.SetItems({ { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "loot")
local awardBuilt = ML.AwardLine(1001, "item:1001", "Aaa")
ok(string.find(awardBuilt, LINK_AAA .. " wins ", 1, true) ~= nil, "AwardLine names the winner (linked)")
ok(string.find(awardBuilt, "|Hitem:1001", 1, true) ~= nil, "AwardLine links the item")
ok(string.find(awardBuilt, "[Dragonfang Blade]", 1, true) ~= nil, "AwardLine names the item")

-- 5. Non-ML simmer in raid/party: the sim speaks to the group — a sim
-- is an explicit test action, never background echo, so the speaker
-- gate doesn't apply. Same text the ML's sim produces, on the same
-- channels (start warns).
ZugLoot.SRSecurity.AmML = function() return false end
for _, g in ipairs({ "raid", "party" }) do
  reset()
  grouping = g
  math.random = rigged({ 90, 80 })
  Sim.SimItem("|cffa335ee|Hitem:1001:::::::::|h[Dragonfang Blade]|h|r")
  math.random = realRandom
  LW.doAction(1001, "finish")
  ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
  ok(#sent > 0, g .. " simmer reaches group chat")
  eq(chatText(), raidChat, g .. " simmer text == ML sim text")
  for i = 1, #sent do
    if g == "raid" then
      ok(sent[i].chan == "RAID" or sent[i].chan == "RAID_WARNING", "raid simmer sends RAID/RAID_WARNING only")
    else
      eq(sent[i].chan, "PARTY", "party simmer sends PARTY only")
    end
  end
end

-- 5b. Non-ML LIVE flow stays local: only the master looter speaks live
-- lines to the group (no background echo from raiders' clients).
for _, g in ipairs({ "raid", "party" }) do
  reset()
  grouping = g
  LW.SetItems({ { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" } }, "loot")
  LW.OpenDetail(1001)
  LW.doAction(1001, "roll")
  ML.IntakeChatRoll("Aaa rolls 90 (1-100)")
  ML.IntakeChatRoll("Bbb rolls 80 (1-100)")
  LW.doAction(1001, "finish")
  ML.AwardChosen({ name = "Aaa", via = "winner" }, 1001)
  eq(#sent, 0, g .. " raider sends no live lines (ML-only chat)")
  local raiderLog = logText()
  ok(string.find(raiderLog, "won by " .. LINK_AAA .. " (100)", 1, true) ~= nil, g .. " raider still sees the verdict locally")
  ok(string.find(raiderLog, LINK_AAA .. " wins ", 1, true) ~= nil, g .. " raider still sees the award locally")
end
ZugLoot.SRSecurity.AmML = function() return true end

-- 5c. Player names in chat are clickable class-colored links
-- (|cHEX|Hplayer:Name|h[Name]|h|r): click -> whisper menu, color ->
-- class. Unknown classes still link (white). Roll/verdict/award/sand
-- all share the builder, so one pin covers every chat line.
reset()
local linkBuilt = ML.AwardLine(1001, "item:1001", "Aaa")
ok(string.find(linkBuilt, "|Hplayer:Aaa|h[Aaa]|h", 1, true) ~= nil, "award names the winner as a player link")
local linkRoll = ML.RollLine({ name = "Aaa", roll = 90, min = 1, max = 100 })
ok(string.find(linkRoll, "|Hplayer:Aaa|h[Aaa]|h", 1, true) ~= nil, "roll line links the roller")
eq(ML.RollLine({ name = "Aaa", roll = 90, min = 1, max = 100 }),
  ZugLoot.ClassColors.PlayerLink("Aaa") .. " rolls 90 (1-100)", "RollLine links, format pinned")
local linkTied = ML.ResultLine({ itemID = 1001, itemLink = "item:1001" },
  { winners = {}, tied = { { name = "Bbb" } } })
ok(string.find(linkTied, "|Hplayer:Bbb|h[Bbb]|h", 1, true) ~= nil, "tie verdict links the tied")
local linkSand = ML.SandLine(19183, "item:19183", "Bbb", 1, 6)
ok(string.find(linkSand, "|Hplayer:Bbb|h[Bbb]|h", 1, true) ~= nil, "sand line links the winner")
ok(string.find(ML.AwardLine(1001, "item:1001", "Tmog", "Aaa"),
  "|Hplayer:Aaa|h[Aaa]|h", 1, true) ~= nil, "trade-to recipient links too")

-- 6. Pure builders: tie / no-winner verdicts + sand line + start line.
reset()
LW.SetItems({
  { itemID = 1001, link = "item:1001", name = "Dragonfang Blade" },
  { itemID = 19183, link = "item:19183", name = "Hourglass Sand" },
}, "loot")
local tieRes = { winners = {}, tied = { { name = "Aaa" }, { name = "Bbb" } } }
ok(string.find(ML.ResultLine({ itemID = 1001, itemLink = "item:1001" }, tieRes), "tie between " .. LINK_AAA .. ", " .. LINK_BBB, 1, true) ~= nil, "tie verdict pinned")
local noRes = { winners = {}, tied = {} }
ok(string.find(ML.ResultLine({ itemID = 1001, itemLink = "item:1001" }, noRes), "no eligible rolls", 1, true) ~= nil, "no-winner verdict pinned")
local sandBuilt = ML.SandLine(19183, "item:19183", "Bbb", 1, 6)
ok(string.find(sandBuilt, "Sand x1 -> " .. LINK_BBB .. " (6 total)", 1, true) ~= nil, "sand line pinned")
ok(string.find(sandBuilt, "|Hitem:19183", 1, true) ~= nil, "sand line links the item")
local startBuilt = ML.StartLine(1001, "item:1001", "SR")
ok(string.find(startBuilt, "Roll ", 1, true) ~= nil, "start line pinned")
ok(string.find(startBuilt, "|Hitem:1001", 1, true) ~= nil, "start line links the item")
local rrBuilt = ML.StartLine(1001, "item:1001", "RAIDROLL")
ok(string.find(rrBuilt, "Raid rolling ", 1, true) ~= nil, "raid-roll start pinned")
ok(string.find(rrBuilt, "|Hitem:1001", 1, true) ~= nil, "raid-roll start links the item")

-- 6. Sand shares the router too (was SayGroup-gated on source before).
reset()
grouping = "party"
LW.SetItems({ { itemID = 19183, link = "item:19183", name = "Hourglass Sand" } }, "loot")
ok(ML.SandDistribute(19183, "loot"), "sand distributes")
eq(#sent, 1, "party sand reaches party chat")
eq(sent[1].chan, "PARTY", "party sand on PARTY")
ok(string.find(sent[1].msg, "Sand x1 -> ", 1, true) ~= nil, "sand text shared")

if T.fail == 0 then
  print("chat routing discipline passed")
else
  for _, e in ipairs(T.errors) do print(e) end
  os.exit(1)
end

return T
