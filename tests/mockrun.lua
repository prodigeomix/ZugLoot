local function newObj(kind)
  local o = { kind=kind, children={}, scripts={}, points={}, texts={} };
  function o:SetWidth(w) self.w=w end
  function o:SetHeight(h) self.h=h end
  function o:SetPoint(...) table.insert(self.points,{...}) end
  function o:SetAllPoints(...) end
  function o:ClearAllPoints() self.points={} end
  function o:SetMovable() end
  function o:EnableMouse() end
  function o:SetClampedToScreen() end
  function o:RegisterForDrag() end
  function o:SetScript(k,f) self.scripts[k]=f end
  function o:GetScript(k) return self.scripts[k] end
  function o:SetBackdrop() end
  function o:SetBackdropColor() end
  function o:SetBackdropBorderColor() end
  function o:Hide() self.hidden=true end
  function o:Show() self.hidden=false end
  function o:SetAlpha(a) self.alpha=a end
  function o:GetAlpha() return self.alpha or 1 end
  function o:IsVisible() return not self.hidden end
  function o:CreateTexture(...) local t={}; function t:SetTexture() end; function t:SetAllPoints() end; function t:SetPoint() end; function t:SetHeight() end; function t:SetWidth() end; function t:SetVertexColor() end; function t:Hide() end; function t:Show() end; return t end
  function o:CreateFontString(...) local fs={txt="",points={}}; function fs:SetAllPoints() end; function fs:SetText(s) self.txt=s end; function fs:GetText() return self.txt end; function fs:SetPoint(...) table.insert(self.points,{...}) end; function fs:ClearAllPoints() self.points={} end; function fs:SetWidth() end; function fs:SetHeight() end; function fs:SetJustifyH() end; function fs:SetJustifyV() end; function fs:SetTextColor() end; function fs.SetShadowOffset() end; function fs:GetStringWidth() return 40 end; function fs:GetFont() return "Fonts\\FRIZQT__.TTF" end; function fs:SetFont() end; return fs end
  function o:GetFontString() local f={}; function f:SetFont() end; function f:SetPoint() end; function f:SetTextColor() end; return f end
  function o:SetStatusBarTexture() end
  function o:SetStatusBarColor() end
  function o:SetValue(v) self.sbval=v end
  function o:SetText(s) self.label=s end
  function o:SetThumbTexture() end
  function o:GetThumbTexture() local t={}; function t:SetWidth() end; function t:SetHeight() end; function t:SetVertexColor() end; return t end
  function o:SetMinMaxValues(a,b) self.mn=a; self.mx=b end
  function o:GetMinMaxValues() return self.mn or 0, self.mx or 0 end
  function o:SetValueStep() end
  function o:SetValue(v) self.val=v end
  function o:GetValue() return self.val or 0 end
  function o:EnableMouseWheel() end
  function o:SetScrollChild() end
  function o:SetVerticalScroll() end
  function o:GetHeight() return self.h or 10 end
  function o:Raise() end
  return o;
end
CreateFrame = function(kind, name, parent, tmpl) return newObj(kind) end
UIParent = newObj("Frame");
GameTooltip = newObj("Tooltip");
function GameTooltip:SetOwner() end; function GameTooltip:SetText() end; function GameTooltip:AddLine() end; function GameTooltip:Show() end; function GameTooltip:Hide() end; function GameTooltip:SetHyperlink() end
getglobal = function() return nil end
-- Emulates the client: stable name/link/texture whether called with the
-- full link or the bare id (the arg-echoing stub hid link-vs-id bugs).
GetItemInfo = function(id)
  local num = tonumber(string.match(tostring(id), "item:(%d+)") or id)
  return "Test Sword", "|cffa335ee|Hitem:"..tostring(num)..":0:0:0|h[Test Sword]|h|r", 4, 0,0,0,0,0, "Interface\\Icons\\INV_Sword_01"
end
UnitName = function() return "SoloPlayer" end
GetNumRaidMembers = function() return 0 end
GetRaidRosterInfo = function() return nil end
GetNumPartyMembers = function() return 0 end
ChatFrameEditBox = { IsVisible=function() return false end };
UIFrameFadeIn = function(f) if f then f:SetAlpha(1) end end
GetItemQualityColor = function(q) return 0.64, 0.21, 0.93, "|cffa335ee" end
GetTime = function() return 100 end
UnitClass = function() return "Warrior", "WARRIOR" end
IsControlKeyDown = function() return false end
IsShiftKeyDown = function() return false end
math.mod = math.mod or function(a,b) return a % b end;
ZugLoot = {}; dofile("Util.lua"); dofile("Constants.lua"); dofile("ClassColors.lua");
ZugLoot.Print = function() end
ZugLoot.DB = { sheet=nil, drops={}, rollTime=15 };
ZugLoot.CharDB = { autoRoll=false };
dofile("SRData.lua"); dofile("Resolver.lua"); dofile("ItemCards.lua");
dofile("RaidArchive.lua");
dofile("SRSecurity.lua");
dofile("Comm.lua");
ZugLoot.SRImport = { ShowPaste=function() end, LoadFromFile=function() end, ResetWon=function() end, RequestResetRollLog=function() end };
ZugLoot.AutoRoll = { Set=function() end };
ZugLoot.VersionGrid = { seen={}, RosterNames=function() return {"A","B"} end, ColorFor=function() return "GREEN" end, Request=function() end };
dofile("MainWindow.lua");
dofile("LootWindow.lua");
dofile("MasterLootUI.lua");
dofile("RaiderLootUI.lua");
local Z = ZugLoot;
Z.MainWindow.Build();
Z.MainWindow.Show("sheet");
print("empty sheet render OK");
local s,_ = Z.SRData.ParseLineFormat("Blackfang; 17063:2+20, 19137:1\nCarbon; 18646:1+60, 17063:1+130\nHARDRES; 17782, 18564\n");
s.meta.raidID = "MOCK-RAID-1";
s.meta.raidName = "Molten Core";
s.meta.importedAt = 1720000000;
Z.SRData.RecordRolls(s, 17063, { t=1, mode="SR", winners={"Carbon"}, entries={{name="Carbon",base=95,sr_plus=130,effective=225},{name="Blackfang",base=40,sr_plus=20,effective=60}} });
Z.SRData.EnsureUnreserved(s, 9999, 4);
Z.SRData.RecordRolls(s, 9999, { t=2, mode="OPEN", winners={"SoloPlayer"}, entries={{name="SoloPlayer",base=70,sr_plus=0,effective=70}} });
Z.SRData.MarkWon(s, 17063, "Carbon");
Z.DB.sheet = s;
Z.DB.drops = { { t=1, itemID=17063, link="[Test Sword]", source="raid", outcome="award", winner="Carbon" } };
Z.DB.sheet = s;
-- ML loot window + award menu render under the mock frame API.
Z.LootWindow.SetItems({ { itemID=19137, link="[Test Dagger]", quality=4, sr=1 } }, "loot");
Z.LootWindow.Show("Boss loot");
assert(Z.LootWindow.Find(19137) ~= nil, "loot window lists the drop");
local sess = { id=1, itemID=19137, itemLink="[Test Dagger]", mode="SR", rolls={ { name="Blackfang", roll=95, type="SR" } }, itemCount=1 };
local res = Z.Resolver.ResolveItem(s, 19137, sess.rolls, { cap=100, requireSR=true });
assert(type(Z.MasterLootUI.BuildAwardMenu) == "function", "menu builder loaded");
local menu = Z.MasterLootUI.BuildAwardMenu(sess, res);
assert(type(menu) == "table" and type(menu.winners) == "table", "menu shape");
assert(menu.winners[1].name == "Blackfang", "menu top winner");
assert(#menu.candidates >= 2, "candidate roster built");
local lines = Z.MasterLootUI.AwardMenuLines(menu);
assert(#lines >= 3, "menu lines render");
print("loot window + award menu OK");
-- client frames: overview rows + row detail under the mock frame API.
Z.LootWindow.Show("Boss loot");
assert(Z.LootWindow.frame ~= nil, "overview frame built");
assert(#Z.LootWindow.rows == 1, "one overview row painted");
Z.LootWindow.OpenDetail(19137);
assert(Z.LootWindow.detail ~= nil, "detail data opened");
assert(Z.LootWindow.detailFrame ~= nil, "detail frame built");
assert(Z.LootWindow.detailFrame.rolls ~= nil, "roll list widget built");
-- rolling + award phases repaint under the mock API (persistent window).
Z.LootWindow.detail.phase = "rolling";
Z.LootWindow.DetailOnRoll(19137, nil, "Blackfang", 95, "SR", 115);
Z.LootWindow.detail.countdown = 12;
Z.LootWindow.RefreshDetail();
Z.LootWindow.DetailOnFinish(19137, menu);
assert(Z.LootWindow.detail.phase == "award", "detail flips to award");
Z.LootWindow.RefreshDetail();
-- two award buttons: primary (SR winner) + Award TMOG (kind winner).
Z.LootWindow.detail.menu.perType = Z.LootWindow.detail.menu.perType or {};
Z.LootWindow.detail.menu.perType.TMOG = { entry = { name = "SoloPlayer",
  rollType = "TMOG", effective = 15 }, tied = {} };
Z.LootWindow.RefreshDetail();
local df2 = Z.LootWindow.detailFrame;
assert(df2.tmogB ~= nil, "Award TMOG button built");
assert(df2.tmogB.hidden ~= true, "Award TMOG visible with a TMOG roll");
assert(string.find(df2.tmogB.label or "", "SoloPlayer", 1, true) ~= nil,
  "Award TMOG names the kind winner, got: " .. tostring(df2.tmogB.label));
-- no TMOG roll -> button hides (SR-only award window).
Z.LootWindow.detail.menu.perType.TMOG = {};
Z.LootWindow.RefreshDetail();
assert(df2.tmogB.hidden == true, "Award TMOG hidden without a TMOG roll");
-- preaward (parked award view): same winner rows as the award window.
Z.LootWindow.detail.phase = "preaward";
Z.LootWindow.RefreshDetail();
local preActs = Z.LootWindow.DetailActions();
assert(preActs[1].id == "award-name", "preaward primary is the top winner");
assert(preActs[1].name == "Blackfang", "preaward winner named");
local preContinue = false
for _, a in ipairs(preActs) do
  if a.id == "continue" then preContinue = true end
end
assert(preContinue, "preaward offers Continue");
assert(df2.awardB.hidden ~= true, "preaward primary button visible");
assert(string.find(df2.awardB.label or "", "Blackfang", 1, true) ~= nil,
  "preaward primary names the winner, got: " .. tostring(df2.awardB.label));
-- button bar geometry: flow-layout invariants — every VISIBLE button
-- inside the frame, no two buttons on the same row overlap, rows stack
-- on the 10 + k*30 grid (wraps when narrow, shares one row when wide).
local df = Z.LootWindow.detailFrame;
local function barBox(b)
  local pts = b.points or {}
  local last = pts[#pts]
  if not last or last[1] ~= "BOTTOMLEFT" then return nil end
  return { x = last[4] or 0, y = last[5] or 0, w = b.w or 0 }
end
local vis = {}
for _, n in ipairs({ "awardB", "tmogB", "moreB", "closeB" }) do
  local btn = df[n]
  if btn and btn.hidden ~= true then
    local box = barBox(btn)
    assert(box ~= nil, n .. " placed");
    assert(box.x >= 0 and box.x + box.w <= Z.LootWindow.DETAIL_WIDTH,
      n .. " inside frame");
    assert((box.y - 10) % 30 == 0, n .. " on row grid");
    table.insert(vis, { name = n, box = box })
  end
end
for i = 1, #vis do
  for j = i + 1, #vis do
    local a, b = vis[i], vis[j]
    if a.box.y == b.box.y then
      local overlap = not (a.box.x + a.box.w <= b.box.x or b.box.x + b.box.w <= a.box.x)
      assert(not overlap, a.name .. " overlaps " .. b.name);
    end
  end
end
local function hasAnchor(pts, want)
  for _, p in ipairs(pts or {}) do
    for _, v in ipairs(p) do if v == want then return true end end
  end
  return false
end
assert(hasAnchor(df.rolls.points, "BOTTOMRIGHT"), "rolls text ends above the bar");
-- ... dropdown builds under the mock API, rows clickable, closes cleanly.
Z.LootWindow.ToggleMoreDropdown(Z.LootWindow.detailFrame.moreB);
assert(Z.LootWindow.moreDropdown ~= nil, "more dropdown opened");
assert(#Z.LootWindow.moreDropdown.rows >= 2, "dropdown rows painted");
Z.LootWindow.CloseDetail();
assert(Z.LootWindow.detail == nil, "detail closed");
assert(Z.LootWindow.moreDropdown == nil, "dropdown closed with detail");
print("loot frames OK");
Z.RaidArchive.ArchiveActive(Z.DB, 2000);
for _,tab in ipairs({"sheet","raids","rolls","versions","setup"}) do
  Z.MainWindow.SelectTab(tab);
  print("rendered tab:", tab);
end
-- scrollbar invariant, checked on every tab: a visible slider may only belong
-- to the active tab. Hidden tabs must never paint a thumb (the old bug left
-- stale sliders from hidden tabs over the live list).
for _,tab in ipairs({"sheet","raids","rolls","versions","setup"}) do
  Z.MainWindow.SelectTab(tab);
  local sliderState = Z.MainWindow.DebugSliderState();
  for other, vis in pairs(sliderState) do
    assert(not vis or other == tab, "slider of hidden tab " .. other .. " visible while on " .. tab);
  end
end
print("slider invariant OK");
-- layout invariant: rows must span the live window (bodyWidth == winW - 64).
-- Catches Lua-scoping regressions where size assignments miss the locals.
local layout = Z.MainWindow.DebugLayout();
assert(layout.winW == 900, "expected 900-wide window in mock, got " .. tostring(layout.winW));
assert(layout.bodyWidth == layout.winW - 64, "body width " .. tostring(layout.bodyWidth) .. " detached from window " .. tostring(layout.winW));
print("layout invariant OK");
-- header shows ID, raid name and raid start
Z.MainWindow.SelectTab("sheet");
local hdr = Z.MainWindow.DebugHeader();
assert(hdr and string.find(hdr, "ID MOCK-RAID-1", 1, true), "header shows raid ID, got: " .. tostring(hdr));
assert(string.find(hdr, "Molten Core", 1, true), "header shows raid name, got: " .. tostring(hdr));
assert(string.find(hdr, "started 2024", 1, true), "header shows raid start, got: " .. tostring(hdr));
assert(string.find(hdr, "items", 1, true), "header shows item count, got: " .. tostring(hdr));
-- prominent active raid line on the brand row: name + start (ID lives on sub-line)
local act = Z.MainWindow.DebugActiveRaid();
assert(act and string.find(act, "ACTIVE RAID", 1, true), "active raid label, got: " .. tostring(act));
assert(string.find(act, "Molten Core", 1, true), "active raid name, got: " .. tostring(act));
assert(string.find(act, "started 2024", 1, true), "active raid start, got: " .. tostring(act));
assert(not string.find(act, "MOCK-RAID-1", 1, true), "ID stays on sub-line, got: " .. tostring(act));
print("header invariant OK");
-- LootBlare-style roll window: build, show item, feed grouped rolls.
Z.RaiderLootUI.ShowItem("|cffa335ee|Hitem:17063:0:0:0|h[Thunderfury]|h|r", 15);
-- icon + name resolve link-first (regression: bare-ID call showed no
-- icon and fell back to the raw link text).
assert(Z.RaiderLootUI.iconPath == "Interface\\Icons\\INV_Sword_01",
  "roll window icon resolved, got: " .. tostring(Z.RaiderLootUI.iconPath));
assert(Z.RaiderLootUI.itemNameText ~= nil
  and not string.find(Z.RaiderLootUI.itemNameText, "|Hitem:", 1, true),
  "roll window name resolved, got: " .. tostring(Z.RaiderLootUI.itemNameText));
Z.RaiderLootUI.OnRoll("Thrall", 40, "SR");
Z.RaiderLootUI.OnRoll("Jaina", 50, "MS");
Z.RaiderLootUI.OnRoll("Varian", 45, "OS");
Z.RaiderLootUI.OnRoll("Anduin", 98, "TMOG");
Z.RaiderLootUI.OnRoll("Guldan", 35, "SR");
assert(#Z.RaiderLootUI.rolls == 5, "roll window collected 5 rolls");
-- sheet fallback colors the roll list: Thrall is a Paladin on the sheet.
s.players = s.players or {};
s.players["Thrall"] = { class = "PaladinHoly" };
assert(Z.ClassColors.ClassOf("Thrall") == "Paladin", "roll window sheet class");
assert(Z.ClassColors.ColoredName("Thrall") == "|cFFF58CBAThrall|r", "roll window pink");
Z.RaiderLootUI.ShowResult("The winner is Jaina (50) !");
print("roll window OK");
print("MOCK UI RUN OK");
