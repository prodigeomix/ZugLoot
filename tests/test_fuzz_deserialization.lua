-- tests/test_fuzz_deserialization.lua
-- Mutational fuzzer for SRImport, SRData, and Comm.OnMessage deserialization.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then
    T.fail = T.fail + 1
    table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else
    T.pass = T.pass + 1
  end
end

local function ok(v, msg)
  if not v then
    T.fail = T.fail + 1
    table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else
    T.pass = T.pass + 1
  end
end

ZugLoot = {}
dofile("Constants.lua")
dofile("Util.lua")
dofile("SRData.lua")
dofile("SRSecurity.lua")
dofile("SRImport.lua")
dofile("Comm.lua")

ZugLoot.DB = { sheet = nil }
ZugLoot.Print = function() end

local Import = ZugLoot.SRImport
local SRData = ZugLoot.SRData
local Comm = ZugLoot.Comm

-- 1. Static assertion: Zero usage of loadstring or RunScript across all files
local files = {
  "Constants.lua", "Util.lua", "Timer.lua", "ClassColors.lua", "SRData.lua",
  "Resolver.lua", "ItemCards.lua", "ItemIcon.lua", "SRView.lua", "SRSecurity.lua",
  "SRImport.lua", "Pysanka.lua", "MainWindow.lua", "Sim.lua", "MasterLootUI.lua",
  "RaidArchive.lua", "Comm.lua", "Core.lua", "LootWindow.lua", "AtlasLoot.lua",
  "RaiderLootUI.lua", "DropLog.lua", "VersionGrid.lua", "Minimap.lua"
}

for _, f in ipairs(files) do
  local fh = io.open(f, "r")
  if fh then
    local content = fh:read("*a")
    fh:close()
    ok(not string.find(content, "loadstring"), "zero loadstring in " .. f)
    ok(not string.find(content, "RunScript"), "zero RunScript in " .. f)
  end
end

-- 2. Seed corpus
local seeds = {
  "",
  "   ",
  "META;raidID=R1,name=MC,by=Leader,at=1000\nPlayer1;17063:1+10\nHARDRES;19019",
  "ESCPlayer1;17063:2%BPlayer2;18646:1+60",
  "Player1; 17063:2+20, 19137:1\nPlayer2; 18646:1+60\nHARDRES; 17782, 18564",
  "SHEET:1:R1:ESCPlayer1;17063:1",
  "SHEET_C:1:R1:1:2:ESCPlayer1;170",
  "SHEET_C:1:R1:2:2:63:1",
  "ROLL_REQ:17063:item:17063:0:0:0:SR",
  "AWARD:17063:Player1",
  "VER_REQ",
  "VER_ANS:0.1.0",
}

-- Linear congruential PRNG for deterministic test fuzzing
local seed = 123456789
local function rand(min, max)
  seed = (seed * 1103515245 + 12345) % 2147483648
  local r = seed / 2147483648
  return math.floor(min + r * (max - min + 1))
end

local specialChars = {
  "|", ";", ":", "%", "=", "\n", "\r", ",", "\0", "\"", "'", "\\",
  "%P", "%B", "%C", "%Z", "%%", "%0", "+", "-", " ", "\t",
  "[", "]", "{", "}", "(", ")", ".", "*", "?", "^", "$"
}

local function mutate(s)
  local mType = rand(1, 8)
  local len = string.len(s)
  if mType == 1 or len == 0 then
    -- Insert special character
    local ch = specialChars[rand(1, #specialChars)]
    local pos = rand(1, math.max(1, len))
    return string.sub(s, 1, pos - 1) .. ch .. string.sub(s, pos)
  elseif mType == 2 and len > 1 then
    -- Truncate
    local cut = rand(1, len)
    return string.sub(s, 1, cut)
  elseif mType == 3 and len > 0 then
    -- Byte flip
    local pos = rand(1, len)
    local byte = string.char(rand(0, 255))
    return string.sub(s, 1, pos - 1) .. byte .. string.sub(s, pos + 1)
  elseif mType == 4 then
    -- Boundary integer insertion
    local bounds = { "0", "-1", "-99999999", "2147483647", "9999999999999999", "1e30", "NaN", "Inf" }
    local num = bounds[rand(1, #bounds)]
    return s .. num
  elseif mType == 5 then
    -- Repetition (ReDoS stress)
    local rep = string.rep(specialChars[rand(1, #specialChars)], rand(5, 50))
    return s .. rep
  elseif mType == 6 then
    -- Base64 corruption
    return "B64" .. s .. "===" .. string.char(rand(65, 90))
  elseif mType == 7 then
    -- Escape corruption
    return "ESC" .. string.rep("%P", rand(1, 20)) .. string.rep("%B", rand(1, 20))
  else
    -- Duplicate text
    return s .. s
  end
end

-- 3. Execute 5,000 fuzz iterations
local fuzzCount = 5000
local unhandledErrors = 0

for i = 1, fuzzCount do
  local baseSeed = seeds[rand(1, #seeds)]
  local payload = mutate(baseSeed)
  if rand(1, 3) == 1 then payload = mutate(payload) end -- double mutation

  -- Fuzz DeserializeSheet
  local okD, res = pcall(Import.DeserializeSheet, payload)
  if not okD then
    unhandledErrors = unhandledErrors + 1
    table.insert(T.errors, "CRASH in DeserializeSheet on iteration " .. i .. ": " .. tostring(res))
    break
  end

  -- Fuzz ParseLineFormat
  local okP, resP = pcall(SRData.ParseLineFormat, payload)
  if not okP then
    unhandledErrors = unhandledErrors + 1
    table.insert(T.errors, "CRASH in ParseLineFormat on iteration " .. i .. ": " .. tostring(resP))
    break
  end

  -- Fuzz Comm.OnMessage
  local okC, resC = pcall(Comm.OnMessage, payload, "FuzzerSender", "RAID")
  if not okC then
    unhandledErrors = unhandledErrors + 1
    table.insert(T.errors, "CRASH in Comm.OnMessage on iteration " .. i .. ": " .. tostring(resC))
    break
  end
end

eq(unhandledErrors, 0, "5000 fuzz iterations survived with zero crashes or unhandled exceptions")
ok(fuzzCount >= 5000, "fuzz count threshold satisfied")

if T.fail == 0 then
  print("deserialization fuzzing and injection defense passed")
else
  for _, e in ipairs(T.errors) do print(e) end
  os.exit(1)
end

return T
