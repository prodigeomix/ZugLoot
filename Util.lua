-- ZugLoot/Util.lua
-- PURE helpers. No WoW API. Lua 5.0-safe (no `#`, no goto, no bitwise ops).
-- Loaded both in-game (via toc) and under stock lua in tests/.
local M = {}

-- 5.0 (client) uses string.gfind, 5.1+ uses string.gmatch.
local Gfind = string.gmatch or string.gfind

function M.Trim(s)
  s = tostring(s or "")
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Count array-part entries without `#` / `table.getn` (works on 5.0 and 5.5).
function M.ArrayCount(t)
  local n = 0
  if type(t) ~= "table" then return 0 end
  while t[n + 1] ~= nil do n = n + 1 end
  return n
end

function M.TableCount(t)
  local n = 0
  if type(t) ~= "table" then return 0 end
  for _ in pairs(t) do n = n + 1 end
  return n
end

function M.Split(str, sep)
  local out = {}
  str = tostring(str or "")
  sep = sep or ","
  local pattern = "([^" .. sep .. "]+)"
  for part in Gfind(str, pattern) do
    table.insert(out, M.Trim(part))
  end
  return out
end

-- Extract numeric item id from "item:12345..." or plain "12345".
function M.ItemID(linkOrID)
  if type(linkOrID) == "number" then return linkOrID end
  local s = tostring(linkOrID or "")
  local id = string.match(s, "item:(%d+)")
  if id then return tonumber(id) end
  local plain = string.match(M.Trim(s), "^(%d+)$")
  if plain then return tonumber(plain) end
  return nil
end

-- Minimal base64 decode (pure lua, 5.0-safe). Ignores whitespace, handles `=`.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64REV = nil
local function b64rev()
  if B64REV then return B64REV end
  B64REV = {}
  local n = M.ArrayCount({}) -- noop, keep 5.0-safe style
  for i = 1, 64 do
    local c = string.sub(B64, i, i)
    B64REV[c] = i - 1
  end
  return B64REV
end

function M.Base64Decode(data)
  if not data or data == "" then return nil end
  data = string.gsub(tostring(data), "%s", "")
  local rev = b64rev()
  local out = {}
  local i = 1
  -- luacheck: ignore
  local len = string.len(data)
  while i <= len do
    local c1 = rev[string.sub(data, i, i)] or 0
    local c2 = rev[string.sub(data, i + 1, i + 1)] or 0
    local c3 = rev[string.sub(data, i + 2, i + 2)] or 0
    local c4 = rev[string.sub(data, i + 3, i + 3)] or 0
    local pad = 0
    if string.sub(data, i + 3, i + 3) == "=" then pad = pad + 1 end
    if string.sub(data, i + 2, i + 2) == "=" then pad = pad + 1 end
    local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4
    local b1 = math.floor(n / 65536) % 256
    local b2 = math.floor(n / 256) % 256
    local b3 = n % 256
    table.insert(out, string.char(b1))
    if pad < 2 then table.insert(out, string.char(b2)) end
    if pad < 1 then table.insert(out, string.char(b3)) end
    i = i + 4
  end
  return table.concat(out)
end

-- Tiny JSON subset decoder: enough for raidres exports
-- (objects with string keys, arrays, numbers, strings, true/false/null, nesting).
-- Implemented as a small recursive descent parser (5.0-safe).
function M.JsonDecode(s)
  s = tostring(s or "")
  local pos = 1
  local function skip()
    while true do
      local c = string.sub(s, pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1
      else break end
    end
  end
  local parseValue, parseString, parseNumber, parseArray, parseObject
  parseString = function()
    pos = pos + 1 -- opening quote
    local out = {}
    while true do
      local c = string.sub(s, pos, pos)
      if c == "" then error("unterminated string") end
      if c == '"' then pos = pos + 1 break end
      if c == "\\" then
        local e = string.sub(s, pos + 1, pos + 1)
        if e == "n" then table.insert(out, "\n")
        elseif e == "t" then table.insert(out, "\t")
        elseif e == "r" then table.insert(out, "\r")
        elseif e == "u" then
          -- \uXXXX -> best effort: ascii only, else "?"
          local hex = string.sub(s, pos + 2, pos + 5)
          local n = tonumber(hex, 16) or 63
          if n < 256 then table.insert(out, string.char(n))
          else table.insert(out, "?") end
          pos = pos + 4
        else table.insert(out, e) end
        pos = pos + 2
      else
        table.insert(out, c)
        pos = pos + 1
      end
    end
    return table.concat(out)
  end
  parseNumber = function()
    local sub = string.sub(s, pos)
    local num = string.match(sub, "^%-?%d+%.?%d*[eE]?[+%-]?%d*")
    pos = pos + string.len(num)
    return tonumber(num)
  end
  parseArray = function()
    pos = pos + 1
    local arr = {}
    local idx = 1
    skip()
    if string.sub(s, pos, pos) == "]" then pos = pos + 1 return arr end
    while true do
      arr[idx] = parseValue()
      idx = idx + 1
      skip()
      local c = string.sub(s, pos, pos)
      if c == "," then pos = pos + 1
      elseif c == "]" then pos = pos + 1 break
      else error("expected , or ] at " .. pos) end
    end
    return arr
  end
  parseObject = function()
    pos = pos + 1
    local obj = {}
    skip()
    if string.sub(s, pos, pos) == "}" then pos = pos + 1 return obj end
    while true do
      skip()
      local k = parseString()
      skip()
      assert(string.sub(s, pos, pos) == ":", "expected : at " .. pos)
      pos = pos + 1
      obj[k] = parseValue()
      skip()
      local c = string.sub(s, pos, pos)
      if c == "," then pos = pos + 1
      elseif c == "}" then pos = pos + 1 break
      else error("expected , or } at " .. pos) end
    end
    return obj
  end
  parseValue = function()
    skip()
    local c = string.sub(s, pos, pos)
    if c == "{" then return parseObject() end
    if c == "[" then return parseArray() end
    if c == '"' then return parseString() end
    if c == "t" and string.sub(s, pos, pos + 3) == "true" then pos = pos + 4 return true end
    if c == "f" and string.sub(s, pos, pos + 4) == "false" then pos = pos + 5 return false end
    if c == "n" and string.sub(s, pos, pos + 3) == "null" then pos = pos + 4 return nil end
    return parseNumber()
  end
  local ok, val = pcall(parseValue)
  if not ok then return nil, val end
  return val
end

-- Format an epoch timestamp for display. Pure + testable: works with the
-- WoW `date` global, stock `os.date`, or returns "?" when ts is empty.
function M.FormatTime(ts, fmt)
  ts = tonumber(ts) or 0
  if ts <= 0 then return "?" end
  fmt = fmt or "%Y-%m-%d %H:%M"
  if date then
    local ok, s = pcall(date, fmt, ts)
    if ok and s then return s end
  end
  if os and os.date then
    local ok, s = pcall(os.date, fmt, ts)
    if ok and s then return s end
  end
  return tostring(ts)
end

if ZugLoot then ZugLoot.Util = M end
return M
