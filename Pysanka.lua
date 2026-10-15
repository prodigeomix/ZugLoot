-- ZugLoot/Pysanka.lua
-- Raid-setup sheet ("PYSANKA" tab): invitation word, buff / tank-healer /
-- debuff / puller / kill-order assignments. PURE model + live roster merge;
-- no WoW API at load (every client touch is call-time guarded).
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.Pysanka = M

local Util
if Z and Z.Util then Util = Z.Util end
local function trim(s)
  if Util and Util.Trim then return Util.Trim(s) end
  s = tostring(s or "")
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end
local function arrayCount(t)
  if Util and Util.ArrayCount then return Util.ArrayCount(t) end
  local n = 0
  if type(t) == "table" then while t[n + 1] ~= nil do n = n + 1 end end
  return n
end

M.INVITE_DEFAULT = "invite"

-- Buff grid: group rows x buff columns (mirrors the sheet's Buffs table).
M.BUFF_COLS = { "Intellect", "MoTW", "Fortitude", "Spirit", "Shadow Protection" }
M.BUFF_ROWS = { "1-2", "3-4", "5-6", "7-8" }

-- Tank & Healer Assignments: one row per raid mark.
M.MARKS = { "Skull", "Cross", "Square", "Moon", "Triangle", "Diamond", "Circle", "Star" }
-- Raid-target icon index per mark (client UI-RaidTargetingIcon_N texture
-- numbering: 1 Star, 2 Circle, 3 Diamond, 4 Triangle, 5 Moon, 6 Square,
-- 7 Cross, 8 Skull).
M.MARK_ICONS = {
  Star = 1, Circle = 2, Diamond = 3, Triangle = 4,
  Moon = 5, Square = 6, Cross = 7, Skull = 8,
}

-- Texture path for a mark's raid icon (nil for unknown marks). Pure.
function M.MarkIcon(mark)
  local n = M.MARK_ICONS[mark]
  if not n then return nil end
  return "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. n
end
M.TANK_FIELDS = { "tank", "healer", "healer2" }
M.N_TANKS = 8

-- Debuff assignments, two visual rows (7 + 4, like the sheet).
M.DEBUFF_ROW1 = { "CoR", "CoS", "CoE", "Faerie Fire", "Wisdom", "Light", "Crusader" }
M.DEBUFF_ROW2 = { "Demo Shout", "Clap", "Sunder Refresh", "Imp Expose Armor" }

function M.Default()
  local pys = {
    inviteWord = M.INVITE_DEFAULT,
    coordinator = "", pallyPower = "", puller = "",
    buffs = {}, tanks = {},
    raidAll = { tank = "", healer = "" },
    debuffs = {}, killOrder = {},
  }
  for i = 1, arrayCount(M.BUFF_ROWS) do
    pys.buffs[i] = {}
    for j = 1, arrayCount(M.BUFF_COLS) do pys.buffs[i][j] = "" end
  end
  for i = 1, M.N_TANKS do
    pys.tanks[i] = { mark = M.MARKS[i], tank = "", healer = "", healer2 = "" }
  end
  for i = 1, arrayCount(M.MARKS) do pys.killOrder[i] = M.MARKS[i] end
  return pys
end

-- Ensure a usable sheet on the DB (forward-fills older saves). db may be
-- nil headless (returns a detached sheet then).
function M.Ensure(db)
  db = db or {}
  if type(db.pysanka) ~= "table" then db.pysanka = M.Default() end
  local p = db.pysanka
  if p.inviteWord == nil then p.inviteWord = M.INVITE_DEFAULT end
  if p.coordinator == nil then p.coordinator = "" end
  if p.pallyPower == nil then p.pallyPower = "" end
  if p.puller == nil then p.puller = "" end
  if type(p.buffs) ~= "table" then p.buffs = {} end
  for i = 1, arrayCount(M.BUFF_ROWS) do
    if type(p.buffs[i]) ~= "table" then p.buffs[i] = {} end
    for j = 1, arrayCount(M.BUFF_COLS) do
      if p.buffs[i][j] == nil then p.buffs[i][j] = "" end
    end
  end
  if type(p.tanks) ~= "table" then p.tanks = {} end
  for i = 1, M.N_TANKS do
    if type(p.tanks[i]) ~= "table" then
      p.tanks[i] = { mark = M.MARKS[i], tank = "", healer = "", healer2 = "" }
    end
    if not p.tanks[i].mark then p.tanks[i].mark = M.MARKS[i] end
  end
  if type(p.raidAll) ~= "table" then p.raidAll = { tank = "", healer = "" } end
  if type(p.debuffs) ~= "table" then p.debuffs = {} end
  if arrayCount(p.killOrder) == 0 then
    p.killOrder = {}
    for i = 1, arrayCount(M.MARKS) do p.killOrder[i] = M.MARKS[i] end
  end
  return p
end

-- Invitation word: blank falls back to the default (there is always a word
-- to whisper).
function M.GetInvite(pys)
  local w = trim(pys and pys.inviteWord or "")
  if w == "" then return M.INVITE_DEFAULT end
  return w
end

function M.SetInvite(pys, v)
  if not pys then return end
  pys.inviteWord = trim(v or "")
end

function M.GetBuff(pys, r, c)
  if not pys or type(pys.buffs) ~= "table" then return "" end
  local row = pys.buffs[r]
  if type(row) ~= "table" then return "" end
  return tostring(row[c] or "")
end

function M.SetBuff(pys, r, c, v)
  if not pys then return end
  pys.buffs = pys.buffs or {}
  if type(pys.buffs[r]) ~= "table" then pys.buffs[r] = {} end
  pys.buffs[r][c] = trim(v or "")
end

function M.SetTank(pys, idx, field, v)
  if not pys or type(idx) ~= "number" then return end
  if idx < 1 or idx > M.N_TANKS then return end
  local okField = false
  for i = 1, arrayCount(M.TANK_FIELDS) do
    if M.TANK_FIELDS[i] == field then okField = true break end
  end
  if not okField then return end
  pys.tanks = pys.tanks or {}
  if type(pys.tanks[idx]) ~= "table" then
    pys.tanks[idx] = { mark = M.MARKS[idx], tank = "", healer = "", healer2 = "" }
  end
  pys.tanks[idx][field] = trim(v or "")
end

function M.SetRaidAll(pys, field, v)
  if not pys then return end
  if field ~= "tank" and field ~= "healer" then return end
  pys.raidAll = pys.raidAll or { tank = "", healer = "" }
  pys.raidAll[field] = trim(v or "")
end

function M.GetDebuff(pys, name)
  if not pys or type(pys.debuffs) ~= "table" then return "" end
  return tostring(pys.debuffs[name] or "")
end

function M.SetDebuff(pys, name, v)
  if not pys or not name or tostring(name) == "" then return end
  pys.debuffs = pys.debuffs or {}
  pys.debuffs[tostring(name)] = trim(v or "")
end

function M.SetPuller(pys, v)
  if not pys then return end
  pys.puller = trim(v or "")
end

function M.SetCoordinator(pys, v)
  if not pys then return end
  pys.coordinator = trim(v or "")
end

function M.SetPally(pys, v)
  if not pys then return end
  pys.pallyPower = trim(v or "")
end

-- Sorted unique merge of two name lists (sheet + roster). Pure.
function M.MergeNames(a, b)
  local seen, out = {}, {}
  local function add(list)
    for i = 1, arrayCount(list) do
      local n = trim(list[i])
      if n ~= "" and not seen[n] then
        seen[n] = true
        table.insert(out, n)
      end
    end
  end
  add(a)
  add(b)
  table.sort(out)
  return out
end

-- Live picker roster: SR-sheet players first, then group members not on
-- the sheet. All client access is call-time guarded (nil-safe headless).
function M.PlayerChoices()
  local sheetNames = {}
  if Z.SRData and Z.SRData.AllPlayerNames and Z.DB and Z.DB.sheet then
    local ok, names = pcall(Z.SRData.AllPlayerNames, Z.DB.sheet)
    if ok and type(names) == "table" then sheetNames = names end
  end
  local roster = {}
  if Z.VersionGrid and Z.VersionGrid.RosterNames then
    local ok, names = pcall(Z.VersionGrid.RosterNames)
    if ok and type(names) == "table" then roster = names end
  end
  return M.MergeNames(sheetNames, roster)
end

if ZugLoot then ZugLoot.Pysanka = M end
return M
