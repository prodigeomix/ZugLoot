-- tests/test_util.lua
-- Util.FormatTime: epoch -> display string, "?" when empty.
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
dofile("ClassColors.lua")
local Util = ZugLoot.Util

-- Empty / zero / nil timestamps render as "?".
eq(Util.FormatTime(nil), "?", "nil -> ?")
eq(Util.FormatTime(0), "?", "0 -> ?")
eq(Util.FormatTime(""), "?", "empty -> ?")

-- A real epoch formats via os.date fallback (mockrun/stock lua have no `date` global).
local s = Util.FormatTime(1720000000)
ok(s ~= "?" and string.find(s, "2024"), "epoch formats, got: " .. tostring(s))

-- Custom format passes through.
local s2 = Util.FormatTime(1720000000, "%Y")
eq(s2, "2024", "custom format")

-- Util.Mod: the shared 5.0/5.1+ modulo (no % op on client, no math.mod here).
eq(Util.Mod(7, 3), 1, "7 mod 3")
eq(Util.Mod(256, 256), 0, "256 mod 256")
eq(Util.Mod(0, 5), 0, "0 mod 5")
eq(Util.Mod(65536, 256), 0, "base64 row wraps")

-- 5.0-compat polyfills (strict clients lack string.match/string.gmatch):
-- hide the natives, reload Util, verify behavior, restore. Faithful 5.0
-- simulation: 5.0 HAS string.gfind (removed in 5.1+), so provide it off
-- the real gmatch while the native gmatch is hidden.
local realMatch, realGmatch = string.match, string.gmatch
string.match, string.gmatch = nil, nil
string.gfind = realGmatch
dofile("Util.lua")
local U50 = ZugLoot.Util
eq(U50.ItemID("item:17063:0:0:0"), 17063, "polyfill: ItemID off link")
eq(U50.ItemID("1001"), 1001, "polyfill: bare id")
local a, b = string.match("sync blackfang", "^(%S+)%s*(.*)$")
eq(a, "sync", "polyfill: multi-capture first")
eq(b, "blackfang", "polyfill: multi-capture rest")
eq(string.match("no digits here", "(%d+)"), nil, "polyfill: miss returns nil")
eq(string.match("[Thunderfury]", "%[(.-)%]"), "Thunderfury", "polyfill: no-capture whole match")
local seen = {}
for w in string.gmatch("a b c", "(%S+)") do table.insert(seen, w) end
eq(table.concat(seen, ","), "a,b,c", "polyfill: gmatch iterates")
string.match, string.gmatch = realMatch, realGmatch
string.gfind = nil -- 5.5 has no gfind; don't leak the harness shim

return T
