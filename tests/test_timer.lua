-- tests/test_timer.lua
-- Timer scheduler: ordering, countdowns, cancel, re-entrant scheduling.
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
dofile("Timer.lua")
local Tm = ZugLoot.Timer

-- 1. Fires in time order as the clock advances.
Tm.CancelAll()
local fired = {}
Tm.After(1.0, function() table.insert(fired, "b") end)
Tm.After(0.5, function() table.insert(fired, "a") end)
Tm.After(1.5, function() table.insert(fired, "c") end)
eq(Tm.Pending(), 3, "three pending")
Tm.Update(0.5)
eq(table.concat(fired, ","), "a", "first due fires")
eq(Tm.Pending(), 2, "two left")
Tm.Update(0.5)
eq(table.concat(fired, ","), "a,b", "second fires")
Tm.Update(1.0)
eq(table.concat(fired, ","), "a,b,c", "all fired in order")
eq(Tm.Pending(), 0, "queue empty")

-- 2. Zero/negative delay fires on next Update.
Tm.CancelAll()
local z = 0
Tm.After(0, function() z = z + 1 end)
Tm.Update(0)
eq(z, 1, "zero-delay fires")

-- 3. Cancel drops a timer; CancelAll empties.
Tm.CancelAll()
local c = 0
local h = Tm.After(1, function() c = c + 1 end)
Tm.After(1, function() c = c + 10 end)
Tm.Cancel(h)
Tm.Update(5)
eq(c, 10, "cancelled timer skipped")
Tm.CancelAll()
eq(Tm.Pending(), 0, "cancel-all empties")

-- 4. Callbacks may schedule more timers (collect-then-fire).
Tm.CancelAll()
local seq = {}
Tm.After(0.5, function()
  table.insert(seq, "first")
  Tm.After(0.5, function() table.insert(seq, "second") end)
end)
Tm.Update(0.5)
eq(table.concat(seq, ","), "first", "re-entrant schedule deferred")
Tm.Update(0.5)
eq(table.concat(seq, ","), "first,second", "chained timer fires")

-- 5. Update with no timers is a safe no-op.
Tm.CancelAll()
Tm.Update(10)
eq(Tm.Pending(), 0, "empty update safe")

return T
