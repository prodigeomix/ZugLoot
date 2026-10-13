-- ZugLoot/SRData.lua
-- PURE sheet model: parse line format + raidres export, SR+ extraction, won marks.
-- No WoW API. Loadable in-game and under stock lua.
local M = {}

local Gfind = string.gmatch or string.gfind

local Util
if ZugLoot and ZugLoot.Util then Util = ZugLoot.Util
else
  local ok, u = pcall(require, "Util")
  if ok then Util = u end
end
if not Util then
  Util = { Trim = function(s) return tostring(s or "") end, Split = function(s) return { s } end }
  Util.ItemID = function(x) return tonumber(x) end
  Util.ArrayCount = function(t) local n = 0 if type(t) == "table" then while t[n+1] ~= nil do n = n + 1 end end return n end
  Util.Base64Decode = function() return nil end
  Util.JsonDecode = function() return nil end
end

function M.NewSheet()
  return { meta = { raidID = nil, importedAt = 0, importedBy = "?", source = "?" }, items = {}, hardres = {}, won = {}, rolls = {} }
end

M.ROLLS_PER_ITEM_MAX = 25

-- Roll history: every finished roll session for an itemID this raid.
-- entry = { t=epoch, mode="SR"|"OPEN"|"RAID"|"TWO", winners={names},
--             entries={ {name, base, sr_plus, effective, missroll, excludedWon} } }
-- Entries should be stored sorted by effective desc (record-time sort).
function M.RecordRolls(sheet, itemID, entry)
  sheet.rolls = sheet.rolls or {}
  sheet.rolls[itemID] = sheet.rolls[itemID] or {}
  table.insert(sheet.rolls[itemID], entry)
  while Util.ArrayCount(sheet.rolls[itemID]) > M.ROLLS_PER_ITEM_MAX do
    table.remove(sheet.rolls[itemID], 1)
  end
  return Util.ArrayCount(sheet.rolls[itemID])
end

function M.GetRolls(sheet, itemID)
  if not sheet or not sheet.rolls or not sheet.rolls[itemID] then return {} end
  return sheet.rolls[itemID]
end

function M.RollCount(sheet, itemID)
  return Util.ArrayCount(M.GetRolls(sheet, itemID))
end

-- SR+ extraction parity with RollFor: max wins, value only (isValid ignored).
function M.ExtractSRPlus(entry)
  if type(entry) ~= "table" then
    local n = tonumber(entry)
    if n and n > 0 then return n end
    return nil
  end
  local val = nil
  local function num(x) local n = tonumber(x) if n and n > 0 then return n end return nil end
  if entry.sr_plus ~= nil and type(entry.sr_plus) ~= "table" then val = num(entry.sr_plus) end
  if not val and entry.srPlus ~= nil and type(entry.srPlus) ~= "table" then val = num(entry.srPlus) end
  if not val and type(entry.srPlus) == "table" and entry.srPlus.value ~= nil then val = num(entry.srPlus.value) end
  if not val and type(entry.sr_plus) == "table" and entry.sr_plus.value ~= nil then val = num(entry.sr_plus.value) end
  if not val and entry.rollBonus ~= nil then val = num(entry.rollBonus) end
  if not val and entry.roll_bonus ~= nil then val = num(entry.roll_bonus) end
  return val
end

local function addRoller(sheet, itemID, quality, name, count, srPlus)
  sheet.items[itemID] = sheet.items[itemID] or { quality = quality or 4, rollers = {} }
  local rollers = sheet.items[itemID].rollers
  local found = nil
  for i = 1, Util.ArrayCount(rollers) do
    if rollers[i].name == name then found = rollers[i] break end
  end
  if not found then
    found = { name = name, rolls = 0, sr_plus = nil }
    table.insert(rollers, found)
  end
  found.rolls = found.rolls + (count or 1)
  if srPlus and (not found.sr_plus or srPlus > found.sr_plus) then
    found.sr_plus = srPlus
  end
end

-- Parse one "itemID[:count][+srplus]" token. Returns itemID, count, srplus, err.
function M.ParseEntry(token)
  token = Util.Trim(token or "")
  if token == "" then return nil, nil, nil, "empty entry" end
  local idPart, rest = string.match(token, "^(%d+)%s*(.*)$")
  if not idPart then return nil, nil, nil, "bad item id in '" .. token .. "'" end
  local count, plus = 1, 0
  rest = Util.Trim(rest or "")
  if rest ~= "" then
    local c = string.match(rest, "^:%s*(%d+)")
    if c then count = tonumber(c) end
    local p = string.match(rest, "%+%s*(%d+)")
    if p then plus = tonumber(p) end
    -- Validate nothing else remains.
    local cleaned = rest
    cleaned = string.gsub(cleaned, "^:%s*%d+", "")
    cleaned = string.gsub(cleaned, "%+%s*%d+", "")
    cleaned = Util.Trim(cleaned)
    if cleaned ~= "" then return nil, nil, nil, "bad entry '" .. token .. "'" end
  end
  return tonumber(idPart), count, plus, nil
end

-- Static line format (CustomData/ZugLoot_SR.txt):
--   Player; itemID[:count][+srplus], ...
--   HARDRES; itemID, ...
function M.ParseLineFormat(text)
  local sheet = M.NewSheet()
  sheet.meta.source = "file"
  local lineNo = 0
  for line in Gfind(tostring(text or "") .. "\n", "([^\n]*)\n") do
    lineNo = lineNo + 1
    local t = Util.Trim(line)
    if t ~= "" and string.sub(t, 1, 1) ~= "#" then
      local head, tail = string.match(t, "^([^;]+);(.*)$")
      if not head then
        return nil, "line " .. lineNo .. ": missing ';' in '" .. t .. "'"
      end
      head = Util.Trim(head)
      local parts = Util.Split(tail, ",")
      if string.upper(head) == "HARDRES" then
        for i = 1, Util.ArrayCount(parts) do
          local id = Util.ItemID(parts[i])
          if not id then return nil, "line " .. lineNo .. ": bad hardres id '" .. Util.Trim(parts[i]) .. "'" end
          sheet.hardres[id] = { quality = 5 }
        end
      else
        if head == "" then return nil, "line " .. lineNo .. ": missing player name" end
        for i = 1, Util.ArrayCount(parts) do
          local itemID, count, plus, err = M.ParseEntry(parts[i])
          if err then return nil, "line " .. lineNo .. ": " .. err end
          addRoller(sheet, itemID, 4, head, count, (plus > 0) and plus or nil)
        end
      end
    end
  end
  return sheet, nil
end

-- raidres.top / fly.dev / softres.it export: base64(json). Accepts raw json too.
function M.ParseRaidResExport(encodedOrJson)
  local raw = tostring(encodedOrJson or "")
  raw = Util.Trim(raw)
  if raw == "" then return nil, "empty import data" end
  local decoded = Util.Base64Decode(raw)
  local jsonText = decoded or raw
  -- If base64 decoded to zlib garbage, fail cleanly.
  if decoded and string.sub(decoded, 1, 1) ~= "{" then
    -- Might be compressed (bcc path) — out of scope for skeleton, report it.
    if not string.find(decoded, "\"reservations\"") and not string.find(decoded, "\"softreserves\"") then
      return nil, "unsupported encoding (compressed exports need the full client)"
    end
  end
  local data, err = Util.JsonDecode(jsonText)
  if not data then return nil, "bad JSON: " .. tostring(err) end
  return M.TransformRaidRes(data)
end

function M.TransformRaidRes(data)
  if type(data) ~= "table" then return nil, "export must be a JSON object" end
  local sheet = M.NewSheet()
  sheet.meta.source = "paste"
  local metaId = nil
  if type(data.metadata) == "table" and data.metadata.id then metaId = tostring(data.metadata.id) end
  sheet.meta.raidID = metaId
  local function xform(items, name, role, quality)
    for i = 1, Util.ArrayCount(items) do
      local it = items[i]
      if type(it) == "table" and it.id then
        addRoller(sheet, tonumber(it.id), it.quality or quality or 4, name, 1, M.ExtractSRPlus(it) or M.ExtractSRPlus({ sr_plus = nil }))
        -- also check player-level bonus: handled by caller merging; keep simple:
      end
    end
  end
  -- New format: reservations[] { character={name,class}, raidItemId|id, srPlus }
  if type(data.reservations) == "table" then
    for i = 1, Util.ArrayCount(data.reservations) do
      local e = data.reservations[i]
      if type(e) == "table" then
        local ch = e.character or {}
        local nm = ch.name or e.name
        local id = e.raidItemId or e.id
        if nm and id then
          local bonus = M.ExtractSRPlus(e) or M.ExtractSRPlus(ch)
          addRoller(sheet, tonumber(id), e.quality or 4, tostring(nm), 1, bonus)
        end
      end
    end
  end
  -- Legacy: softreserves[] { name, role, items[] }
  if type(data.softreserves) == "table" then
    for i = 1, Util.ArrayCount(data.softreserves) do
      local sr = data.softreserves[i]
      if type(sr) == "table" and sr.name then
        local pbonus = M.ExtractSRPlus(sr)
        local items = sr.items or {}
        for j = 1, Util.ArrayCount(items) do
          local it = items[j]
          if type(it) == "table" and it.id then
            local bonus = M.ExtractSRPlus(it) or pbonus
            addRoller(sheet, tonumber(it.id), it.quality or 4, tostring(sr.name), 1, bonus)
          end
        end
      end
    end
  end
  -- Hard reserves.
  if type(data.hardreserves) == "table" then
    for i = 1, Util.ArrayCount(data.hardreserves) do
      local it = data.hardreserves[i]
      if type(it) == "table" and it.id then sheet.hardres[tonumber(it.id)] = { quality = it.quality or 5 } end
    end
  end
  return sheet, nil
end

-- Won marks: one copy per player per item per raid.
function M.MarkWon(sheet, itemID, player)
  sheet.won[itemID] = sheet.won[itemID] or {}
  sheet.won[itemID][player] = true
end

function M.HasWon(sheet, itemID, player)
  return sheet.won[itemID] and sheet.won[itemID][player] or false
end

function M.ClearWon(sheet)
  sheet.won = {}
end

function M.ClearRolls(sheet)
  sheet.rolls = {}
end

function M.SortedItemIDs(sheet)
  local ids = {}
  for id in pairs(sheet.items) do table.insert(ids, id) end
  table.sort(ids)
  return ids
end

function M.GetRollers(sheet, itemID)
  if not sheet.items[itemID] then return {} end
  return sheet.items[itemID].rollers or {}
end

if ZugLoot then ZugLoot.SRData = M end
return M
