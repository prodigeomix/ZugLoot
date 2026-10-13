-- tests/test_window_size.lua
-- MainWindow sizing: big targets, clamped to screen minus margins, sane floor.
-- ComputeSize is pure (screen dims passed in); no WoW API needed.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else T.pass = T.pass + 1 end
end

ZugLoot = {}
dofile("Util.lua")
dofile("MainWindow.lua")
local MW = ZugLoot.MainWindow

-- 1. No screen info (mock/test): full targets.
local w, h = MW.ComputeSize(nil, nil)
eq(w, 900, "fallback width")
eq(h, 640, "fallback height")

-- 2. Big monitor: targets fit, unchanged.
w, h = MW.ComputeSize(1920, 1080)
eq(w, 900, "1080p width")
eq(h, 640, "1080p height")

-- 3. Small monitor: clamped to screen minus margins (40 x, 60 y).
w, h = MW.ComputeSize(800, 600)
eq(w, 760, "800w -> 760")
eq(h, 540, "600h -> 540")

-- 4. Width-constrained only.
w, h = MW.ComputeSize(700, 1200)
eq(w, 660, "narrow width clamped")
eq(h, 640, "tall height keeps target")

-- 5. Height-constrained only.
w, h = MW.ComputeSize(2000, 500)
eq(w, 900, "wide width keeps target")
eq(h, 440, "short height clamped")

-- 6. Tiny screen: minimums hold (480x360).
w, h = MW.ComputeSize(400, 300)
eq(w, 480, "min width floor")
eq(h, 360, "min height floor")

-- 7. Classic 1024x768: fits under screen.
w, h = MW.ComputeSize(1024, 768)
eq(w, 900, "1024 width fits target")
eq(h, 640, "768 height fits target")

-- 8. Zero/garbage input treated as unknown.
w, h = MW.ComputeSize(0, -5)
eq(w, 900, "zero width fallback")
eq(h, 640, "negative height fallback")

return T
