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
run("test_itemcards.lua")
run("test_sim.lua")
run("test_reset.lua")
run("test_raids.lua")

-- Mock-client UI run: executes MainWindow Build + all tab renders under a
-- fake 1.12 frame API to catch typos/nil-globals outside the client.
print("--- mock UI run --")
local mchunk, merr = loadfile("tests/mockrun.lua")
if not mchunk then
  print("LOAD FAIL mockrun.lua: " .. tostring(merr))
  totalFail = totalFail + 1
else
  local mok, merr2 = pcall(mchunk)
  if not mok then
    print("RUN FAIL mockrun.lua: " .. tostring(merr2))
    totalFail = totalFail + 1
  end
end

-- 5.0-syntax sanity: all shipped lua files must parse (loadfile without running).
local files = { "Constants.lua", "Util.lua", "SRData.lua", "Resolver.lua", "ItemCards.lua", "SRView.lua",
  "SRSecurity.lua", "SRImport.lua", "BossData.lua", "MainWindow.lua", "Sim.lua", "MasterLootUI.lua",
  "RaidArchive.lua", "Comm.lua", "Core.lua" }
for _, f in ipairs(files) do
  local c, e = loadfile(f)
  if not c then print("PARSE FAIL " .. f .. ": " .. tostring(e)) totalFail = totalFail + 1
  else print("parse ok: " .. f) end
end

print(string.format("TOTAL: %d passed, %d failed", totalPass, totalFail))
if totalFail > 0 then os.exit(1) end
print("All tests passed.")
