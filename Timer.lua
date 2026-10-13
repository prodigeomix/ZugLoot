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

-- Advance the clock by dt seconds, firing everything due. Collect-then-fire
-- so callbacks may safely schedule (or cancel) more timers.
function M.Update(dt)
  dt = tonumber(dt) or 0
  local due = {}
  local keep = {}
  for i = 1, qlen() do
    local h = M.queue[i]
    if h.dead then
      -- drop
    else
      h.t = h.t - dt
      if h.t <= 0 then
        h.dead = true
        table.insert(due, h.fn)
      else
        table.insert(keep, h)
      end
    end
  end
  M.queue = keep
  local j = 1
  while due[j] ~= nil do
    if due[j] then due[j]() end
    j = j + 1
  end
end

if ZugLoot then ZugLoot.Timer = M end
return M
