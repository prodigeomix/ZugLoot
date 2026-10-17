-- ZugLoot/Timer.lua
-- Tiny countdown scheduler. Vanilla 1.12 has no C_Timer, so this is driven
-- by a hidden frame's OnUpdate in Core; tests drive it by hand via Update().
-- Pure logic, no WoW API at load or in Update. Lua 5.0-safe.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.Timer = M

M.queue = {}

-- Local length (Timer must not depend on Util load order in tests).
local function qlen()
  local n = 0
  while M.queue[n + 1] ~= nil do n = n + 1 end
  return n
end

-- Schedule fn to run after sec seconds. Returns a handle for Cancel().
function M.After(sec, fn)
  local h = { t = tonumber(sec) or 0, fn = fn, dead = false }
  table.insert(M.queue, h)
  return h
end

function M.Cancel(h)
  if h then h.dead = true end
end

function M.CancelAll()
  M.queue = {}
end

function M.Pending()
  local n = 0
  for i = 1, qlen() do
    if not M.queue[i].dead then n = n + 1 end
  end
  return n
end

local dueScratch = {}
local keepScratch = {}

-- Advance the clock by dt seconds, firing everything due. Collect-then-fire
-- so callbacks may safely schedule (or cancel) more timers.
-- ZERO ALLOCATIONS: early-exits when empty; reuses static buffers.
function M.Update(dt)
  if M.queue[1] == nil then return end
  dt = tonumber(dt) or 0
  local n = qlen()
  local dueCount = 0
  local keepCount = 0
  for i = 1, n do
    local h = M.queue[i]
    if h and not h.dead then
      h.t = h.t - dt
      if h.t <= 0 then
        h.dead = true
        dueCount = dueCount + 1
        dueScratch[dueCount] = h.fn
      else
        keepCount = keepCount + 1
        keepScratch[keepCount] = h
      end
    end
  end
  for i = 1, keepCount do
    M.queue[i] = keepScratch[i]
    keepScratch[i] = nil
  end
  for i = keepCount + 1, n do
    M.queue[i] = nil
  end
  for j = 1, dueCount do
    local fn = dueScratch[j]
    dueScratch[j] = nil
    if fn then fn() end
  end
end

if ZugLoot then ZugLoot.Timer = M end
return M
