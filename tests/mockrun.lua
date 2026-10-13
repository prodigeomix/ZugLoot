local function newObj(kind)
  local o = { kind=kind, children={}, scripts={}, points={}, texts={} };
  function o:SetWidth(w) self.w=w end
  function o:SetHeight(h) self.h=h end
  function o:SetPoint(...) table.insert(self.points,{...}) end
  function o:SetAllPoints(...) end
  function o:ClearAllPoints() end
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
  function o:IsVisible() return not self.hidden end
  function o:CreateTexture(...) local t={}; function t:SetTexture() end; function t:SetAllPoints() end; function t:SetPoint() end; function t:SetHeight() end; function t:SetWidth() end; function t:SetVertexColor() end; function t:Hide() end; function t:Show() end; return t end
  function o:CreateFontString(...) local fs={txt=""}; function fs:SetText(s) self.txt=s end; function fs:GetText() return self.txt end; function fs:SetPoint() end; function fs:SetWidth() end; function fs:SetHeight() end; function fs:SetJustifyH() end; function fs:SetJustifyV() end; function fs:SetTextColor() end; function fs.SetShadowOffset() end; function fs:GetStringWidth() return 40 end; return fs end
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
GetItemInfo = function(id) return "Test Sword "..id, "|cffa335ee|Hitem:"..id.."|h[Test]|h", 4, 0,0,0,0,0, "Interface\\Icons\\INV_Sword_01" end
UnitName = function() return "SoloPlayer" end
GetNumRaidMembers = function() return 0 end
GetNumPartyMembers = function() return 0 end
ChatFrameEditBox = { IsVisible=function() return false end };
math.mod = math.mod or function(a,b) return a % b end;
ZugLoot = {}; dofile("Util.lua"); dofile("Constants.lua");
ZugLoot.Print = function() end
ZugLoot.DB = { sheet=nil, drops={}, rollTime=15 };
ZugLoot.CharDB = { autoRoll=false };
dofile("SRData.lua"); dofile("Resolver.lua"); dofile("ItemCards.lua");
dofile("RaidArchive.lua");
dofile("SRSecurity.lua");
ZugLoot.SRImport = { ShowPaste=function() end, LoadFromFile=function() end, ResetWon=function() end, RequestResetRollLog=function() end };
ZugLoot.AutoRoll = { Set=function() end };
ZugLoot.VersionGrid = { seen={}, RosterNames=function() return {"A","B"} end, ColorFor=function() return "GREEN" end, Request=function() end };
dofile("MainWindow.lua");
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
-- prominent active raid line on the brand row
local act = Z.MainWindow.DebugActiveRaid();
assert(act and string.find(act, "ACTIVE RAID", 1, true), "active raid label, got: " .. tostring(act));
assert(string.find(act, "Molten Core", 1, true), "active raid name, got: " .. tostring(act));
assert(string.find(act, "MOCK-RAID-1", 1, true), "active raid ID, got: " .. tostring(act));
print("header invariant OK");
print("MOCK UI RUN OK");
