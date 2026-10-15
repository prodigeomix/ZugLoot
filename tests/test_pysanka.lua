-- tests/test_pysanka.lua
-- Pysanka raid-setup model: defaults, setters, invite fallback, name merge.
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
dofile("Pysanka.lua")
local PY = ZugLoot.Pysanka
local Util = ZugLoot.Util

local d = PY.Default()
eq(PY.GetInvite(d), "invite", "invite defaults to invite")
PY.SetInvite(d, "  inv  ")
eq(PY.GetInvite(d), "inv", "invite trims")
PY.SetInvite(d, "   ")
eq(PY.GetInvite(d), "invite", "blank invite falls back to default")
eq(Util.ArrayCount(PY.BUFF_COLS), 5, "5 buff columns")
eq(Util.ArrayCount(PY.BUFF_ROWS), 4, "4 buff rows")
PY.SetBuff(d, 1, 2, "Janetta")
eq(PY.GetBuff(d, 1, 2), "Janetta", "buff set/get")
eq(PY.GetBuff(d, 4, 5), "", "buff default empty")
eq(PY.N_TANKS, 8, "8 tank rows")
eq(d.tanks[1].mark, "Skull", "first mark is skull")
eq(d.tanks[8].mark, "Star", "last mark is star")
PY.SetTank(d, 1, "tank", "Pysanka")
eq(d.tanks[1].tank, "Pysanka", "tank set")
PY.SetTank(d, 1, "bogus", "X")
eq(d.tanks[1].bogus, nil, "bad tank field ignored")
PY.SetTank(d, 99, "tank", "X")
ok(true, "out-of-range tank ignored without error")
PY.SetRaidAll(d, "tank", "Shaman")
eq(d.raidAll.tank, "Shaman", "raid-all tank set")
PY.SetDebuff(d, "CoR", "Ahjinn")
eq(PY.GetDebuff(d, "CoR"), "Ahjinn", "debuff set/get")
eq(PY.GetDebuff(d, "CoS"), "", "debuff default empty")
PY.SetPuller(d, "Remorph")
eq(d.puller, "Remorph", "puller set")
PY.SetCoordinator(d, "Pysanka")
eq(d.coordinator, "Pysanka", "coordinator set")
PY.SetPally(d, "Joblosspally")
eq(d.pallyPower, "Joblosspally", "pally power set")
eq(Util.ArrayCount(d.killOrder), 8, "kill order holds 8 marks")
eq(d.killOrder[1], "Skull", "kill order starts at skull")

local merged = PY.MergeNames({ "B", "A", "A" }, { "C", "B" })
eq(Util.ArrayCount(merged), 3, "merge dedups")
eq(merged[1], "A", "merge sorted first")
eq(merged[3], "C", "merge sorted last")

local db = {}
local p = PY.Ensure(db)
ok(db.pysanka ~= nil, "ensure stores the sheet")
eq(PY.GetInvite(p), "invite", "ensured invite default")
p.tanks = nil
p.buffs = nil
PY.Ensure(db)
ok(db.pysanka.tanks[1] ~= nil, "ensure refills tanks")
ok(db.pysanka.buffs[1] ~= nil, "ensure refills buffs")
local detached = PY.Ensure(nil)
ok(detached ~= nil and PY.GetInvite(detached) == "invite", "ensure works headless")

-- Raid-target icons: plural sprite sheet + SetTexCoord crop (Bagshui/Luna
-- pattern on this client). Single-icon files do NOT exist.
eq(PY.MarkIcon("Skull"), "Interface\\TargetingFrame\\UI-RaidTargetingIcons", "skull sheet")
eq(PY.MarkIcon("Star"), "Interface\\TargetingFrame\\UI-RaidTargetingIcons", "star sheet")
eq(PY.MarkIcon("Bogus"), nil, "unknown mark has no icon")
local sl, sr, st, sb = PY.MarkCoords("Star")
eq(sl, 0, "star crop left")
eq(sr, 0.25, "star crop right")
eq(st, 0, "star crop top")
eq(sb, 0.25, "star crop bottom")
local kl, kr, kt, kb = PY.MarkCoords("Skull")
eq(kl, 0.75, "skull crop left")
eq(kr, 1, "skull crop right")
eq(kt, 0.25, "skull crop top")
eq(kb, 0.5, "skull crop bottom")
eq(PY.MarkCoords("Bogus"), nil, "unknown mark has no coords")
ok(PY.MARK_ICONS["Skull"] == 8 and PY.MARK_ICONS["Cross"] == 7
  and PY.MARK_ICONS["Square"] == 6 and PY.MARK_ICONS["Triangle"] == 4
  and PY.MARK_ICONS["Diamond"] == 3 and PY.MARK_ICONS["Circle"] == 2,
  "all mark icon numbers")

return T
