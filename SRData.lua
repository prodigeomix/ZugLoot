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
  return { meta = { raidID = nil, importedAt = 0, importedBy = "?", source = "?" }, items = {}, hardres = {}, won = {}, rolls = {}, players = {} }
end

-- Class fallback store: players[name] = { class = <canonical> }.
-- Filled at import from raidres character.class / legacy role strings and
-- used whenever the live party/raid roster does not know a name.
-- NormalizeClass lives in ClassColors (loaded after SRData in the toc),
-- so matching here is local: canonical names + longest class+spec prefix.
local SHEET_CLASSES = {
  "Warrior", "Paladin", "Hunter", "Rogue", "Priest",
  "Shaman", "Mage", "Warlock", "Druid",
}

local function sheetNormalizeClass(s)
  s = tostring(s or "")
  s = (string.gsub(s, "^%s*(.-)%s*$", "%1"))
  if s == "" then return nil end
  local lower = string.lower(s)
  for i = 1, 9 do
    if lower == string.lower(SHEET_CLASSES[i]) then return SHEET_CLASSES[i] end
  end
  local best = nil
  for i = 1, 9 do
    local canon = string.lower(SHEET_CLASSES[i])
    if string.sub(lower, 1, string.len(canon)) == canon then
      if not best or string.len(canon) > string.len(string.lower(best)) then
        best = SHEET_CLASSES[i]
      end
    end
  end
  return best
end

function M.SetPlayerClass(sheet, name, rawClass)
  if not sheet or not name or tostring(name) == "" then return nil end
  local c = sheetNormalizeClass(rawClass)
  if not c then return nil end
  sheet.players = sheet.players or {}
  local p = sheet.players[tostring(name)]
  if type(p) ~= "table" then
    p = {}
    sheet.players[tostring(name)] = p
  end
  -- First truth wins: imports are additive across items, classes agree.
  -- The RAW value is kept alongside (p.raw) so role icons stay
  -- spec-aware ("PaladinHoly" heals) while matching stays canonical.
  if not p.class then p.class = c end
  if not p.raw then p.raw = tostring(rawClass) end
  return p.class
end

function M.PlayerClass(sheet, name)
  if not sheet or not sheet.players then return nil end
  local p = sheet.players[tostring(name or "")]
  if type(p) == "table" then return p.class end
  return nil
end

M.ROLLS_PER_ITEM_MAX = 25

-- Sheet log floor: roll history, unreserved stubs, and won marks only
-- ever cover rare (blue, 3) and above. Anything below never enters the
-- sheet. Unknown quality (nil — cold item cache, no row) can't be
-- classified, so it proceeds (old behavior, no data loss).
M.SHEET_QUALITY_MIN = 3
function M.LoggableQuality(quality)
  local q = tonumber(quality)
  if q == nil then return true end
  return q >= M.SHEET_QUALITY_MIN
end

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
      -- META lines belong to the broadcast envelope, not the sheet:
      -- skip them here (ExtractMeta consumes them on receive). Unknown
      -- heads would otherwise fail as player names.
      if string.upper(head) ~= "META" then
      local parts = Util.Split(tail, ",")
      if string.upper(head) == "HARDRES" then
        for i = 1, Util.ArrayCount(parts) do
          local id = Util.ItemID(parts[i])
          if not id then return nil, "line " .. lineNo .. ": bad hardres id '" .. Util.Trim(parts[i]) .. "'" end
          sheet.hardres[id] = { quality = 5 }
        end
      elseif string.upper(head) == "PLAYERS" then
        for i = 1, Util.ArrayCount(parts) do
          local nm, cls = string.match(Util.Trim(parts[i]), "^([^=]+)=([^=]+)$")
          if nm and cls then M.SetPlayerClass(sheet, Util.Trim(nm), Util.Trim(cls)) end
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
  end
  return sheet, nil
end

-- A pasted blob may carry preamble lines above it (tool headers,
-- "copy below this line" notes). First JSON / long-base64 line wins;
-- everything above is dropped. Returns nil when no payload line is found
-- (caller keeps the original text so empty/garbage errors still fire).
function M.IsBase64Line(t)
  local s = string.gsub(tostring(t or ""), "%s", "")
  if string.len(s) < 32 then return false end
  return string.find(s, "^[A-Za-z0-9+/=]+$") ~= nil
end

function M.ExtractPayload(text)
  local started = false
  local out = {}
  for line in Gfind(tostring(text or "") .. "\n", "([^\n]*)\n") do
    local t = Util.Trim(line)
    if not started then
      if t ~= "" and (string.sub(t, 1, 1) == "{" or M.IsBase64Line(t)) then
        started = true
      end
    end
    if started then table.insert(out, line) end
  end
  if not started then return nil end
  return table.concat(out, "\n")
end

-- Quote-aware single CSV row split (5.0-safe). Handles quoted fields
-- ("Sigil of Ancient Accord", "Date (GMT)") and "" escapes; every
-- field comes back trimmed.
function M.ParseCSVRow(line)
  line = tostring(line or "")
  local out, field = {}, {}
  local i, n = 1, string.len(line)
  local inQ = false
  while i <= n do
    local c = string.sub(line, i, i)
    if inQ then
      if c == '"' then
        if string.sub(line, i + 1, i + 1) == '"' then
          table.insert(field, '"')
          i = i + 2
        else
          inQ = false
          i = i + 1
        end
      else
        table.insert(field, c)
        i = i + 1
      end
    else
      if c == '"' then
        inQ = true
        i = i + 1
      elseif c == "," then
        table.insert(out, table.concat(field))
        field = {}
        i = i + 1
      else
        table.insert(field, c)
        i = i + 1
      end
    end
  end
  table.insert(out, table.concat(field))
  for k = 1, Util.ArrayCount(out) do out[k] = Util.Trim(out[k]) end
  return out
end

-- Second SR-sheet format: CSV export (ID,Attendee,Class,Specialization,SR+
-- plus ignored columns like Item/Boss/Date). Header-matched, so column
-- order and extras don't matter; lines above the header are preamble and
-- dropped. Minimum columns: ID + Attendee. Class/Spec feed the sheet
-- class store (combined Class+Spec, no spaces, for RoleOf); SR+ defaults 0.
local CSV_ID = { id = true, itemid = true }
local CSV_ATT = { attendee = true, player = true, name = true, character = true, raider = true }
local CSV_CLASS = { class = true }
local CSV_SPEC = { specialization = true, spec = true }
local CSV_PLUS = { ["sr+"] = true, srplus = true }

local function csvHNorm(s)
  s = string.lower(Util.Trim(s or ""))
  s = string.gsub(s, "[ _]", "")
  return s
end

local function csvColMap(fields)
  local map = {}
  for i = 1, Util.ArrayCount(fields) do
    local h = csvHNorm(fields[i])
    if CSV_ID[h] and not map.id then map.id = i
    elseif CSV_ATT[h] and not map.att then map.att = i
    elseif CSV_CLASS[h] and not map.class then map.class = i
    elseif CSV_SPEC[h] and not map.spec then map.spec = i
    elseif CSV_PLUS[h] and not map.plus then map.plus = i end
  end
  if map.id and map.att then return map end
  return nil
end

function M.ParseCSVFormat(text)
  local lines = {}
  for line in Gfind(tostring(text or "") .. "\n", "([^\n]*)\n") do
    table.insert(lines, line)
  end
  -- Header scan: preamble (tool notes, blanks, # comments) above the
  -- header is dropped — first ID+Attendee header line wins.
  local map, headerAt = nil, nil
  local i = 1
  while lines[i] ~= nil do
    local t = Util.Trim(lines[i])
    if t ~= "" and string.sub(t, 1, 1) ~= "#" then
      local m = csvColMap(M.ParseCSVRow(lines[i]))
      if m then map, headerAt = m, i break end
    end
    i = i + 1
  end
  if not map then return nil, "no CSV header (needs ID + Attendee columns)" end
  local nCols = Util.ArrayCount(M.ParseCSVRow(lines[headerAt]))
  local sheet = M.NewSheet()
  sheet.meta.source = "csv"
  i = headerAt + 1
  while lines[i] ~= nil do
    local t = Util.Trim(lines[i])
    if t ~= "" and string.sub(t, 1, 1) ~= "#" then
      local f = M.ParseCSVRow(lines[i])
      while Util.ArrayCount(f) < nCols do table.insert(f, "") end
      local id = Util.ItemID(f[map.id])
      local nm = Util.Trim(f[map.att] or "")
      -- Rows without the minimum fields aren't reservations: skip
      -- (mirrors TransformRaidRes, which skips entries lacking name/id).
      if id and nm ~= "" then
        local plusStr = ""
        if map.plus then plusStr = f[map.plus] or "" end
        local plus = tonumber(Util.Trim(plusStr))
        local bonus = (plus and plus > 0) and plus or nil
        addRoller(sheet, id, 4, nm, 1, bonus)
        local cls = ""
        if map.class then cls = Util.Trim(f[map.class] or "") end
        if cls ~= "" then
          local spec = ""
          if map.spec then spec = Util.Trim(f[map.spec] or "") end
          -- No spaces: "Paladin"+"Protection" -> "PaladinProtection"
          -- so RoleOf/SpecName see the spec suffix.
          local raw = string.gsub(cls, "%s+", "") .. string.gsub(spec, "%s+", "")
          M.SetPlayerClass(sheet, nm, raw)
        end
      end
    end
    i = i + 1
  end
  return sheet, nil
end

-- raidres.top / fly.dev / softres.it export: base64(json). Accepts raw json too.
function M.ParseRaidResExport(encodedOrJson)
  local raw = tostring(encodedOrJson or "")
  -- Preamble tolerance: lines above the blob are dropped (first JSON /
  -- long-base64 line wins). No payload line: keep the text so the
  -- empty/garbage errors below still fire.
  raw = M.ExtractPayload(raw) or raw
  raw = Util.Trim(raw)
  if raw == "" then return nil, "empty import data" end
  local decoded = Util.Base64Decode(raw)
  -- Truncated write? Base64 length not a multiple of 4, or decoded JSON
  -- cut mid-string/object: fail CLEANLY (never let JsonDecode run on a
  -- partial payload — on huge inputs that is the hang).
  if decoded then
    local stripped = string.gsub(raw, "%s", "")
    local blen = string.len(stripped)
    if blen - math.floor(blen / 4) * 4 ~= 0 then
      return nil, "truncated import data (bad base64 length) — re-copy the export"
    end
    local tail = string.gsub(decoded, "%s+$", "")
    local last = string.sub(tail, -1)
    if last ~= "}" and last ~= "]" then
      return nil, "truncated import data (JSON cut off) — re-copy the export"
    end
  end
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
  local raidName = nil
  local exportAt = nil
  if type(data.metadata) == "table" then
    if data.metadata.id then metaId = tostring(data.metadata.id) end
    -- Export time = content revision: prefer an explicit timestamp when
    -- the exporter provides one (exportedAt / exported_at / updatedAt /
    -- timestamp, epoch seconds), else fall back to import time at apply.
    for _, k in ipairs({ "exportedAt", "exported_at", "updatedAt", "updated_at", "timestamp", "exported" }) do
      local v = tonumber(data.metadata[k])
      if v and v > 0 then exportAt = v break end
    end
    -- Raid/instance name: `instances` array first, then `instance` (name or id).
    local inst = data.metadata.instances
    if type(inst) == "table" then
      local i = 1
      while inst[i] ~= nil do
        if inst[i] and inst[i] ~= "" then raidName = tostring(inst[i]) break end
        i = i + 1
      end
    elseif data.metadata.instance ~= nil and data.metadata.instance ~= "" then
      raidName = tostring(data.metadata.instance)
    end
  end
  sheet.meta.raidID = metaId
  sheet.meta.raidName = raidName
  sheet.meta.importedAt = exportAt or 0 -- 0 = unknown: ApplySheet stamps now
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
          M.SetPlayerClass(sheet, tostring(nm), ch.class or e.class)
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
        M.SetPlayerClass(sheet, tostring(sr.name), sr.role or sr.class)
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

-- Won marks: one copy per player per item per raid. Optional quality
-- (4th arg) enforces the sheet log floor: below rare never marks
-- (returns false, marks nothing). Nil quality proceeds (unclassifiable).
function M.MarkWon(sheet, itemID, player, quality)
  if not M.LoggableQuality(quality) then return false end
  sheet.won[itemID] = sheet.won[itemID] or {}
  sheet.won[itemID][player] = true
  return true
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

-- Ensure an item dropped/rolled but never SR'd has a stub entry so it shows
-- on the sheet (at the bottom, flagged `unsr`). Never touches an existing
-- entry: real SR data is never clobbered. Rare-and-above only: a known
-- below-rare quality refuses (returns false, nothing added) — such items
-- never enter the sheet. Returns true if a stub was added.
function M.EnsureUnreserved(sheet, itemID, quality)
  if not sheet or not itemID then return false end
  if sheet.items[itemID] then return false end
  if not M.LoggableQuality(quality) then return false end
  sheet.items[itemID] = { quality = quality or 4, rollers = {}, unsr = true }
  return true
end

function M.IsUnreserved(sheet, itemID)
  return sheet and sheet.items[itemID] and sheet.items[itemID].unsr == true
end

-- Remove unreserved stubs (roll-session artifacts). Used by roll-log reset
-- so the sheet returns to its imported state. Returns count removed.
function M.PruneUnreserved(sheet)
  if not sheet or not sheet.items then return 0 end
  local n = 0
  for id, item in pairs(sheet.items) do
    if type(item) == "table" and item.unsr == true then
      sheet.items[id] = nil
      n = n + 1
    end
  end
  return n
end

function M.SortedItemIDs(sheet)
  local ids = {}
  for id in pairs(sheet.items) do table.insert(ids, id) end
  table.sort(ids)
  return ids
end

-- Card order: alphabetical by item name, unreserved stubs (rolled but
-- never SR'd) at the bottom. Names come from the client item cache
-- (GetItemInfo); unknown ids fall back to "item:<id>" so the order stays
-- deterministic headless and for uncached items. opts.keepNumeric keeps
-- the legacy numeric order (broadcast serialize path — wire stability).
function M.CardName(sheet, id)
  local item = sheet.items[id]
  local cached = item and item.name or nil
  if cached and cached ~= "" then return tostring(cached) end
  if GetItemInfo then
    local ok, nm = pcall(GetItemInfo, tonumber(id))
    if ok and nm and nm ~= "" then return tostring(nm) end
  end
  return "item:" .. tostring(id)
end
function M.SortedCardIDs(sheet, opts)
  local sr, un = {}, {}
  for id, item in pairs(sheet.items) do
    if type(item) == "table" and item.unsr == true then
      table.insert(un, id)
    else
      table.insert(sr, id)
    end
  end
  if opts and opts.keepNumeric then
    table.sort(sr)
    table.sort(un)
  else
    local function byName(a, b)
      local na, nb = M.CardName(sheet, a), M.CardName(sheet, b)
      if na ~= nb then return na < nb end
      return a < b -- tie-break: stable numeric fallback
    end
    table.sort(sr, byName)
    table.sort(un, byName)
  end
  for i = 1, Util.ArrayCount(un) do table.insert(sr, un[i]) end
  return sr
end

function M.GetRollers(sheet, itemID)
  if not sheet.items[itemID] then return {} end
  return sheet.items[itemID].rollers or {}
end

-- Hard reserve lookup: sheet.hardres[itemID] = { quality } (line HARDRES
-- section or raidres hardreserves[]). Pure, nil-safe for tests.
function M.IsHardres(sheet, itemID)
  if not sheet or not sheet.hardres then return false end
  return sheet.hardres[itemID] ~= nil
end

-- Loot-window badge for an item: "HR" beats everything; "SR" / "SR:n" when
-- n players hold a soft reserve; "" when nobody reserved it.
function M.ReserveBadge(sheet, itemID)
  if M.IsHardres(sheet, itemID) then return "HR" end
  local n = 0
  if sheet and sheet.items and sheet.items[itemID] then
    n = Util.ArrayCount(sheet.items[itemID].rollers or {})
  end
  if n <= 0 then return "" end
  if n == 1 then return "SR" end
  return "SR:" .. n
end

-- Players holding a soft reserve on an item, sorted. Powers the row
-- detail's roller list and the single-SR direct-award shortcut.
function M.SRNames(sheet, itemID)
  local out = {}
  if sheet and sheet.items and sheet.items[itemID] then
    local rollers = sheet.items[itemID].rollers or {}
    for i = 1, Util.ArrayCount(rollers) do
      if rollers[i] and rollers[i].name then table.insert(out, rollers[i].name) end
    end
  end
  table.sort(out)
  return out
end

-- All unique player names across every item, sorted. Used for open-roll sims
-- so unreserved items are rolled by players from the loaded sheet.
function M.AllPlayerNames(sheet)
  local seen, out = {}, {}
  if not sheet or not sheet.items then return out end
  for _, item in pairs(sheet.items) do
    local rollers = item.rollers or {}
    local i = 1
    while rollers[i] ~= nil do
      local n = rollers[i].name
      if n and not seen[n] then seen[n] = true table.insert(out, n) end
      i = i + 1
    end
  end
  table.sort(out)
  return out
end

if ZugLoot then ZugLoot.SRData = M end
return M
