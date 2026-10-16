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

return T
