-- tests/test_network_mtu_throttle.lua
-- Verification of 254-byte MTU enforcement, multi-part chunking, ChatThrottleLib routing, and debouncing.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then
    T.fail = T.fail + 1
    table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else
    T.pass = T.pass + 1
  end
end

local function ok(v, msg)
  if not v then
    T.fail = T.fail + 1
    table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else
    T.pass = T.pass + 1
  end
end

ZugLoot = {}
dofile("Constants.lua")
dofile("Util.lua")
dofile("SRData.lua")
dofile("SRImport.lua")
dofile("SRSecurity.lua")
dofile("Comm.lua")

local Comm = ZugLoot.Comm
local SRData = ZugLoot.SRData
local Sec = ZugLoot.SRSecurity

-- 1. Mock network harness with hard 254-byte MTU check
local sentPackets = {}
local ctlPackets = {}
local currentTime = 1000

GetTime = function() return currentTime end
time = function() return currentTime end
UnitName = function() return "LeaderPlayer" end

SendAddonMessage = function(prefix, msg, channel)
  if string.len(msg) > 254 then
    error("HARD MTU VIOLATION: packet length " .. string.len(msg) .. " exceeds 254 bytes: " .. msg)
  end
  table.insert(sentPackets, { prefix = prefix, msg = msg, channel = channel })
end

-- Mock group state: in raid as ML
Sec.IsInRaid = function() return true end
Sec.IsSolo = function() return false end
Sec.AmML = function() return true end
Sec.CanAcceptFrom = function(s) return true end

-- Construct large 40-man sheet
local bigSheet = SRData.NewSheet()
bigSheet.meta = { raidID = "Raid-40Man-MC", raidName = "Molten Core", importedBy = "LeaderPlayer", importedAt = 1000 }
for id = 17001, 17045 do
  bigSheet.items[id] = { quality = 4, rollers = {
    { name = "TankWarrior", rolls = 2, sr_plus = 20 },
    { name = "HealPriest", rolls = 1, sr_plus = 10 },
    { name = "MageDps", rolls = 1, sr_plus = nil },
  } }
end

-- Broadcast sheet and assert all sent packets obey MTU <= 254
sentPackets = {}
Comm.lastBroadcastTime = 0
Comm.BroadcastSheet(bigSheet, "Raid-40Man-MC")

ok(#sentPackets > 1, "large sheet was split into multiple chunks")
for idx, pkt in ipairs(sentPackets) do
  ok(string.len(pkt.msg) <= 254, "packet " .. idx .. " is within 254-byte MTU (actual " .. string.len(pkt.msg) .. ")")
  ok(string.sub(pkt.msg, 1, 8) == "SHEET_C:", "packet carries chunk header")
end

-- 2. Verify receiver reassembly of chunks
ZugLoot.DB = { sheet = nil }
for _, pkt in ipairs(sentPackets) do
  Comm.OnMessage(pkt.msg, "LeaderPlayer", "RAID")
end

ok(ZugLoot.DB.sheet ~= nil, "sheet reassembled on receiver")
eq(ZugLoot.DB.sheet.meta.raidID, "Raid-40Man-MC", "reassembled sheet has matching raidID")
ok(ZugLoot.DB.sheet.items[17001] ~= nil, "item 17001 intact in reassembled sheet")
eq(#ZugLoot.DB.sheet.items[17001].rollers, 3, "item rollers count intact")

-- 3. Verify out-of-order chunk reassembly
ZugLoot.DB = { sheet = nil }
Comm.chunkBuffers = {}
-- Feed in reverse order
for i = #sentPackets, 1, -1 do
  Comm.OnMessage(sentPackets[i].msg, "LeaderPlayer", "RAID")
end
ok(ZugLoot.DB.sheet ~= nil, "reverse-order chunks successfully reassembled")
ok(ZugLoot.DB.sheet.items[17045] ~= nil, "item 17045 intact in reverse reassembly")

-- 4. Verify ChatThrottleLib routing
ChatThrottleLib = {
  SendAddonMessage = function(self, priority, prefix, msg, channel)
    table.insert(ctlPackets, { priority = priority, prefix = prefix, msg = msg, channel = channel })
  end
}

ctlPackets = {}
sentPackets = {}
currentTime = currentTime + 10 -- pass debounce
Comm.RequestVersions()

eq(#ctlPackets, 1, "traffic routes via ChatThrottleLib when available")
eq(ctlPackets[1].prefix, "ZugLoot", "correct prefix passed to CTL")
eq(ctlPackets[1].msg, "VER_REQ", "correct payload passed to CTL")
eq(#sentPackets, 0, "bare SendAddonMessage skipped when CTL is present")

-- Fallback check: CTL removed
ChatThrottleLib = nil
sentPackets = {}
currentTime = currentTime + 10
Comm.RequestVersions()
eq(#sentPackets, 1, "clean fallback to SendAddonMessage when CTL is missing")

-- 5. Broadcast debouncing verification
sentPackets = {}
Comm.RequestSheet()
eq(#sentPackets, 1, "first RequestSheet sends")

-- Immediate second call (within 0.1s)
currentTime = currentTime + 0.1
Comm.RequestSheet()
eq(#sentPackets, 1, "second RequestSheet dropped by debounce")

-- After debounce interval passes
currentTime = currentTime + 2.0
Comm.RequestSheet()
eq(#sentPackets, 2, "RequestSheet sends after debounce cooldown")

if T.fail == 0 then
  print("network mtu and throttle discipline passed")
else
  for _, e in ipairs(T.errors) do print(e) end
  os.exit(1)
end

return T
