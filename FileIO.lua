-- ZugLoot/FileIO.lua
-- CustomData file wrapper (Nampower APIs). Pattern from CooldownCrafts/Chronicle.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.FileIO = M

M.SR_FILENAME = "ZugLoot_SR.txt"

function M.IsAvailable()
  return ReadCustomFile ~= nil
end

function M.ReadSRFile()
  if not ReadCustomFile then return nil, "ReadCustomFile not available (requires Nampower)" end
  -- Distinguish missing file from read errors / empty file.
  if CustomFileExists then
    local eok, exists = pcall(CustomFileExists, M.SR_FILENAME)
    if eok and not exists then
      return nil, M.SR_FILENAME .. " not found in CustomData/ (looking for exactly that name)"
    end
  end
  local ok, result = pcall(ReadCustomFile, M.SR_FILENAME)
  if not ok then return nil, "read error: " .. tostring(result) end
  if result == nil then return nil, M.SR_FILENAME .. " not found in CustomData/ (ReadCustomFile returned nil)" end
  -- Nampower may append trailing whitespace/newlines; callers trim as needed.
  if tostring(result) == "" then return nil, M.SR_FILENAME .. " is empty (0 bytes)" end
  return result, nil
end

function M.WriteSRFile(content)
  if not WriteCustomFile then return false, "WriteCustomFile not available (requires Nampower)" end
  local ok, err = pcall(WriteCustomFile, M.SR_FILENAME, content, "w")
  if not ok then return false, tostring(err) end
  return true
end
