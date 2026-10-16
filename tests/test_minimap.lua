-- tests/test_minimap.lua
-- Minimap ZL badge button: pure position math + tooltip lines + persisted
-- angle. No frame APIs needed (Build is client-only, nil-guarded).
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
dofile("Minimap.lua")
local MM = ZugLoot.Minimap

ZugLoot.VERSION = "0.1.0"
ZugLoot.DB = { sheet = nil }
ZugLoot.CharDB = {}
ZugLoot.SRSecurity = { RoleLabel = function() return "Solo (preview)" end }
CreateFrame = nil -- headless: Build must no-op
Minimap = nil

-- 1. Angle math: 0 = top, 90 = right, 180 = bottom, 270 = left.
local x0, y0 = MM.AnglePos(0, 80)
eq(x0, 0, "top: x=0")
eq(y0, 80, "top: y=+r")
local x90, y90 = MM.AnglePos(90, 80)
ok(math.abs(x90 - 80) < 0.001, "right: x=+r")
ok(math.abs(y90) < 0.001, "right: y=0")
local x180, y180 = MM.AnglePos(180, 80)
ok(math.abs(x180) < 0.001, "bottom: x=0")
eq(y180, -80, "bottom: y=-r")
local x270, y270 = MM.AnglePos(270, 80)
ok(math.abs(x270 + 80) < 0.001, "left: x=-r")
ok(math.abs(y270) < 0.001, "left: y=0")

-- 2. Angle persistence (per character).
eq(MM.GetAngle(), 200, "default angle")
MM.SetAngle(90)
eq(ZugLoot.CharDB.minimapAngle, 90, "angle persisted")
eq(MM.GetAngle(), 90, "angle read back")

-- 3. Tooltip lines: title + no-sheet + role + hint.
local lines = MM.TipLines()
eq(lines[1], "ZugLoot v0.1.0", "title line")
eq(lines[2], "no sheet", "no sheet line")
ok(lines[#lines] ~= nil and string.find(lines[#lines], "Drag", 1, true) ~= nil, "hint line")

-- 4. With a sheet: raid name shows.
ZugLoot.DB.sheet = { meta = { raidID = "R1", raidName = "Molten Core" } }
local lines2 = MM.TipLines()
eq(lines2[2], "Molten Core", "raid name line")

-- 5. Build no-ops headless (no CreateFrame); the badge is one
-- prerendered image (no FontStrings, no drift).
eq(MM.Build(), nil, "headless build is nil-safe")
eq(MM.BADGE_IMAGE,
  "Interface\\AddOns\\ZugLoot\\Media\\ZL-Badge.tga",
  "prerendered badge from Media")
eq(MM.BADGE_SIZE, 32, "badge fills the button")
ok(MM.ICON == nil and MM.ICON_HIRES == nil, "no stock icon: media badge only")
ok(MM.button == nil, "no button headless")

return T
