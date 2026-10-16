-- tests/test_help.lua
-- /zl help: slim multi-line output, one line per KEPT command. The
-- dispatcher and the help list must agree exactly (no dead docs, no
-- undocumented commands).
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
dofile("Util.lua")
-- Minimal frame mock: Core.lua calls Z.Init() (CreateFrame) at load.
CreateFrame = CreateFrame or function()
  return { RegisterEvent = function() end, SetScript = function() end }
end
SlashCmdList = SlashCmdList or {}
dofile("Core.lua")
local Z = ZugLoot
Z.VERSION = "9.9.9-test"
local printed = {}
Z.Print = function(m) table.insert(printed, m) end

local lines = Z.HelpLines()
ok(#lines >= 10, "help lists the slim set, got " .. #lines)
ok(string.find(lines[1], "9.9.9-test", 1, true) ~= nil, "header carries version")

-- Slim set: exactly these commands, nothing else.
local kept = { "sheet", "import", "loadfile", "sheetreq", "sync",
  "simboss", "simraid", "simstop", "rehearse", "rolldebug", "lootdebug", "help" }
local dropped = { "raids", "raid", "rf", "arf", "rr", "2x", "fr", "cr",
  "show", "hide", "time", "autoclose", "auto", "ver", "verlist",
  "sim", "simtmog", "simroll", "rollauto", "lootframe",
  "log", "logclear", "reset", "roll", "award" }
local function documents(cmd)
  for _, ln in ipairs(lines) do
    if string.sub(ln, 1, 4) == "    "
        and (string.sub(ln, 5, 4 + #cmd) == cmd
          and string.sub(ln, 5 + #cmd, 5 + #cmd) == " ") then
      return true
    end
  end
  return false
end
for _, cmd in ipairs(kept) do
  ok(documents(cmd), "help documents /zl " .. cmd)
end
for _, cmd in ipairs(dropped) do
  ok(not documents(cmd), "help drops /zl " .. cmd)
end

-- /zl help prints exactly the lines (headless: Print capture).
printed = {}
local back = Z.PrintHelp()
eq(#printed, #lines, "PrintHelp prints every line")
eq(#back, #lines, "PrintHelp returns every line")
for i = 1, #lines do eq(back[i], lines[i], "help line " .. i) end

return T
