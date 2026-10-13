-- tests/run_tests.lua — stock-lua runner. Usage: lua tests/run_tests.lua (cwd = ZugLoot/)
local totalPass, totalFail = 0, 0
local function run(file)
  local chunk, err = loadfile("tests/" .. file)
  if not chunk then
    print("LOAD FAIL " .. file .. ": " .. tostring(err))
    totalFail = totalFail + 1
    return
  end
  -- Each test file expects cwd files Util.lua etc.; set package path + cwd.
  local ok, T = pcall(chunk)
  if not ok then
    print("RUN FAIL " .. file .. ": " .. tostring(T))
    totalFail = totalFail + 1
    return
  end
  totalPass = totalPass + (T.pass or 0)
  totalFail = totalFail + (T.fail or 0)
  for _, e in ipairs(T.errors or {}) do print(e) end
  print(string.format("%s: %d passed, %d failed", file, T.pass or 0, T.fail or 0))
end

-- Tests dofile() sibling pure modules, so run them with cwd = addon root.
run("test_srdata.lua")
run("test_resolver.lua")
run("test_security.lua")

-- 5.0-syntax sanity: all shipped lua files must parse (loadfile without running).
local files = { "Constants.lua", "Util.lua", "SRData.lua", "Resolver.lua", "SRView.lua",
  "SRSecurity.lua", "SRImport.lua", "BossData.lua" }
for _, f in ipairs(files) do
  local c, e = loadfile(f)
  if not c then print("PARSE FAIL " .. f .. ": " .. tostring(e)) totalFail = totalFail + 1
  else print("parse ok: " .. f) end
end

print(string.format("TOTAL: %d passed, %d failed", totalPass, totalFail))
if totalFail > 0 then os.exit(1) end
print("All tests passed.")
