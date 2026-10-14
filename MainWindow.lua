-- ZugLoot/MainWindow.lua
-- Big tabbed window, Aegis-SBR-inspired skin (flat dark palette, 1px hairlines,
-- tab rail with gold underline, scroll body). In-game only.
-- Tabs: Sheet (default) | Raids | Rolls | Versions | Setup.
--
-- Sheet tab: one card per item (sorted by itemID). Each card has:
--   - icon button (hover = full GameTooltip item details, click = link in chat)
--   - item name (quality color), [HR] tag, roll-count badge
--   - SR list: "Name xN (+SR+)" with WON marks
--   - roll history: every session this raid, one line per player per session
--     ("#1 Carbon 95(+130=225) WINNER" etc.)
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.MainWindow = M

M.activeTab = "sheet"
M.frame = nil

-- Window size: big, but never larger than the screen. Targets are resolved
-- against GetScreenWidth/Height at build/show time (UI scale and resolution
-- changes mid-session trigger a rebuild via EnsureSize).
M.TARGET_W, M.TARGET_H = 900, 640
M.MIN_W, M.MIN_H = 480, 360
M.MARGIN_W, M.MARGIN_H = 40, 60
M.winW, M.winH = nil, nil

-- NOTE (Lua scoping): these locals MUST stay above screenSize/EnsureSize/
-- RefreshSize. Lua binds locals statically, so an assignment textually above
-- the `local` declaration silently writes a global instead — the window
-- would grow while every row kept rendering at the stale 596px width.
-- per-tab scroll bodies: tabKey -> { sf, child, sb, y }
local bodies = {}
local tabBtns = {}
local headerFS = nil
local activeRaidFS = nil

local BODY_TOP, BODY_BOTTOM, BODY_LEFT = -118, 14, 14
-- Body width follows the live window width (window width minus 64).
local BODY_WIDTH = 596

local function screenSize()
  local sw, sh = nil, nil
  if GetScreenWidth then
    local ok, v = pcall(GetScreenWidth)
    if ok and tonumber(v) then sw = tonumber(v) end
  end
  if GetScreenHeight then
    local ok, v = pcall(GetScreenHeight)
    if ok and tonumber(v) then sh = tonumber(v) end
  end
  if not sw and UIParent and UIParent.GetWidth then
    local ok, v = pcall(function() return UIParent:GetWidth() end)
    if ok and tonumber(v) and tonumber(v) > 0 then sw = tonumber(v) end
  end
  if not sh and UIParent and UIParent.GetHeight then
    local ok, v = pcall(function() return UIParent:GetHeight() end)
    if ok and tonumber(v) and tonumber(v) > 0 then sh = tonumber(v) end
  end
  return sw, sh
end

-- Pure sizing: returns w, h clamped to the screen minus margins.
-- sw/sh may be nil (mock/test) to exercise the fallback + clamp math.
function M.ComputeSize(sw, sh)
  local w, h = M.TARGET_W, M.TARGET_H
  if sw and tonumber(sw) and tonumber(sw) > 0 then
    w = math.min(w, math.floor(tonumber(sw) - M.MARGIN_W))
  end
  if sh and tonumber(sh) and tonumber(sh) > 0 then
    h = math.min(h, math.floor(tonumber(sh) - M.MARGIN_H))
  end
  if w < M.MIN_W then w = M.MIN_W end
  if h < M.MIN_H then h = M.MIN_H end
  return w, h
end

function M.RefreshSize()
  local sw, sh = screenSize()
  M.winW, M.winH = M.ComputeSize(sw, sh)
  if M.winW and M.winW > 200 then BODY_WIDTH = M.winW - 64 end
  return M.winW, M.winH
end

-- Rebuild the window if the clamped size changed since Build
-- (resolution / UI-scale change). Returns true when rebuilt.
function M.EnsureSize()
  local sw, sh = screenSize()
  local w, h = M.ComputeSize(sw, sh)
  if M.frame and M.winW == w and M.winH == h then return false end
  if M.frame then M.frame:Hide() end
  M.frame = nil
  bodies = {}
  tabBtns = {}
  headerFS = nil
  activeRaidFS = nil
  M.winW, M.winH = w, h
  if M.winW and M.winW > 200 then BODY_WIDTH = M.winW - 64 end
  M.Build()
  return true
end

local PAL = {
  bg    = { 0.055, 0.059, 0.071, 0.97 },
  panel = { 0.088, 0.096, 0.116, 1.0 },
  line  = { 0.15,  0.165, 0.196, 1.0 },
  ink   = { 0.91,  0.90,  0.88 },
  mute  = { 0.55,  0.56,  0.60 },
  gold  = { 1.0, 0.82, 0.0 },
  green = { 0.3, 1.0, 0.3 },
  red   = { 1.0, 0.35, 0.35 },
}

local QUALITY_RGB = {
  [0] = { 0.62, 0.62, 0.62 },
  [1] = { 1.0, 1.0, 1.0 },
  [2] = { 0.12, 1.0, 0.0 },
  [3] = { 0.0, 0.44, 1.0 },
  [4] = { 0.64, 0.21, 0.93 },
  [5] = { 1.0, 0.5, 0.0 },
}

local TABS = {
  { key = "sheet",    label = "SHEET" },
  { key = "raids",    label = "RAIDS" },
  { key = "versions", label = "MEMBERS" },
  { key = "setup",    label = "SETUP" },
}

local function hairline(parent, y1, x1, x2)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetTexture(PAL.line[1], PAL.line[2], PAL.line[3], 1)
  t:SetHeight(1)
  t:SetPoint("TOPLEFT", parent, "TOPLEFT", x1 or 14, y1)
  t:SetPoint("TOPRIGHT", parent, "TOPRIGHT", x2 or -14, y1)
  return t
end

local function FS(parent, font, text)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetText(text or "")
  fs:SetTextColor(PAL.ink[1], PAL.ink[2], PAL.ink[3])
  if fs.SetShadowOffset then fs:SetShadowOffset(0, 0) end
  return fs
end

-- Chained hover tooltip (Aegis Tip pattern): keep prior handlers.
local function Tip(frame, title, line1, line2)
  if not frame then return end
  local prevEnter = frame:GetScript("OnEnter")
  local prevLeave = frame:GetScript("OnLeave")
  frame:SetScript("OnEnter", function()
    if prevEnter then prevEnter() end
    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
    GameTooltip:SetText(title or "", 1, 0.82, 0)
    if line1 and line1 ~= "" then GameTooltip:AddLine(line1, 1, 1, 1, 1) end
    if line2 and line2 ~= "" then GameTooltip:AddLine(line2, 1, 1, 1, 1) end
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function()
    if prevLeave then prevLeave() end
    GameTooltip:Hide()
  end)
end

-- Item icon with hover = full item tooltip, click = link into chat.
-- Uses LootBlare fix #8: GetItemInfo(tonumber(id)) for the icon texture.
local function ItemIcon(parent, itemID, size)
  local b = CreateFrame("Button", nil, parent)
  b:SetWidth(size or 36) b:SetHeight(size or 36)
  local tex = b:CreateTexture(nil, "ARTWORK")
  tex:SetAllPoints(b)
  local _, link, quality, _, _, _, _, _, icon = nil, nil, nil, nil, nil, nil, nil, nil, nil
  if GetItemInfo then
    _, link, quality, _, _, _, _, _, icon = GetItemInfo(tonumber(itemID))
  end
  tex:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
  b.iconLink = link
  b.itemID = itemID
  -- quality border
  local q = QUALITY_RGB[quality or 4] or QUALITY_RGB[4]
  local bd = b:CreateTexture(nil, "OVERLAY")
  bd:SetTexture(q[1], q[2], q[3], 0.9)
  bd:SetHeight(1) bd:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0) bd:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
  b:SetScript("OnEnter", function()
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    if b.iconLink then
      GameTooltip:SetHyperlink(b.iconLink)
    else
      GameTooltip:SetText("item:" .. tostring(b.itemID), 1, 1, 1)
      GameTooltip:AddLine("Details load when the client has seen this item.", 0.7, 0.7, 0.7, 1)
    end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", function()
    if b.iconLink and ChatFrameEditBox and ChatFrameEditBox:IsVisible() then
      ChatFrameEditBox:Insert(b.iconLink)
    elseif b.iconLink then
      Z.Print(b.iconLink)
    end
  end)
  return b
end

local function ItemName(itemID, quality)
  local name, link = nil, nil
  if GetItemInfo then name, link = GetItemInfo(tonumber(itemID)) end
  local q = QUALITY_RGB[quality or 4] or QUALITY_RGB[4]
  local label = name or ("item:" .. tostring(itemID))
  local function hex(v) return string.format("%02x", math.floor(((v or 1) * 255) + 0.5)) end
  return "|cff" .. hex(q[1]) .. hex(q[2]) .. hex(q[3]) .. label .. "|r", link
end

-------------------------------------------------------------------------------
-- Scroll body per tab
-------------------------------------------------------------------------------
local function MakeBody(parent, key)
  local bw = BODY_WIDTH
  local winH = (M.winH or 540)
  local sf = CreateFrame("ScrollFrame", "ZugLootBody_" .. key, parent)
  sf:SetPoint("TOPLEFT", parent, "TOPLEFT", BODY_LEFT, BODY_TOP)
  sf:SetWidth(bw) sf:SetHeight(winH + BODY_TOP - BODY_BOTTOM)
  local child = CreateFrame("Frame", "ZugLootBodyChild_" .. key, sf)
  child:SetWidth(BODY_WIDTH) child:SetHeight(10)
  sf:SetScrollChild(child)
  local sb = CreateFrame("Slider", "ZugLootBar_" .. key, parent, "UIPanelScrollBarTemplate")
  sb:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, BODY_TOP - 14)
  sb:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, BODY_BOTTOM + 14)
  sb:SetWidth(16)
  local up = getglobal("ZugLootBar_" .. key .. "ScrollUpButton")
  local dn = getglobal("ZugLootBar_" .. key .. "ScrollDownButton")
  if up then up:Hide() end
  if dn then dn:Hide() end
  -- NOTE: do NOT hide the pre-existing thumb texture here. SetThumbTexture
  -- reuses that same texture object, so hiding it first hides the live
  -- thumb too and the scrollbar ends up with no indicator at all.
  sb:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
  local th = sb:GetThumbTexture()
  if th then th:SetWidth(6) th:SetHeight(24) th:SetVertexColor(0.42, 0.43, 0.48, 0.95) end
  sb:SetScript("OnValueChanged", function() if sf.SetVerticalScroll then sf:SetVerticalScroll(sb:GetValue()) end end)
  sb:SetMinMaxValues(0, 0) sb:SetValueStep(24) sb:SetValue(0)
  sf:EnableMouseWheel(true)
  sf:SetScript("OnMouseWheel", function()
    local mn, mx = sb:GetMinMaxValues()
    local v = sb:GetValue() - (arg1 * 32)
    if v < mn then v = mn elseif v > mx then v = mx end
    sb:SetValue(v)
  end)
  sf:Hide()
  bodies[key] = { sf = sf, child = child, sb = sb, rows = {} }
  return bodies[key]
end

-- Single owner for slider visibility: a tab's slider is only ever shown when
-- its tab is active AND its content overflows. All five sliders share one
-- screen rect, so a stale slider from a hidden tab would paint a frozen
-- thumb over the live list.
local function SyncSlider(key)
  local b = bodies[key]
  if not b then return end
  if key == M.activeTab and b.hasOverflow then b.sb:Show() else b.sb:Hide() end
end

local function ClearBody(key)
  local b = bodies[key]
  if not b then return end
  for i = 1, Z.Util.ArrayCount(b.rows) do
    if b.rows[i] and b.rows[i].Hide then b.rows[i]:Hide() end
  end
  b.rows = {}
  b.hasOverflow = false
  b.child:SetHeight(10)
  b.sb:SetMinMaxValues(0, 0) b.sb:SetValue(0)
  if b.sf.SetVerticalScroll then b.sf:SetVerticalScroll(0) end
  b.sb:Hide()
end

local function TrackRow(key, row, h)
  local b = bodies[key]
  table.insert(b.rows, row)
  local y = 0
  for i = 1, Z.Util.ArrayCount(b.rows) - 1 do
    y = y + (b.rows[i].rowH or 20)
  end
  row:SetPoint("TOPLEFT", b.child, "TOPLEFT", 0, -y)
  row.rowH = h
  b.child:SetHeight(y + h + 8)
  local maxScroll = b.child:GetHeight() - b.sf:GetHeight()
  if maxScroll < 0 then maxScroll = 0 end
  b.sb:SetMinMaxValues(0, maxScroll)
  b.hasOverflow = maxScroll > 8
  SyncSlider(key)
end

-------------------------------------------------------------------------------
-- Sheet tab: item cards
-------------------------------------------------------------------------------
-- Class-colored name for display strings. Nil-safe headless (returns the
-- plain name when the ClassColors module is absent, as in old tests).
local function PName(name)
  if Z.ClassColors and Z.ClassColors.ColoredName then
    return Z.ClassColors.ColoredName(name)
  end
  return tostring(name or "")
end

local function RollerLine(r)
  local s = PName(r.name) .. " x" .. tostring(r.rolls or 1)
  if r.sr_plus and r.sr_plus > 0 then
    s = s .. " |cFFFFD700(+" .. r.sr_plus .. ")|r"
  end
  if r.won then s = s .. "  |cFFFF0000[WON]|r" end
  return s
end

local function RollLine(e, isWinner)
  local s = PName(e.name) .. " " .. tostring(e.base)
  if e.sr_plus and e.sr_plus > 0 then
    s = s .. "(+" .. e.sr_plus .. "=" .. (e.effective or e.base) .. ")"
  end
  if e.missroll then s = s .. " |cff888888[miss — no SR]|r" end
  if e.excludedWon then s = s .. " |cff888888[already won]|r" end
  if isWinner then s = "|cFF00FF00WINNER: |r" .. s end
  return s
end

function M.RenderSheet()
  local key = "sheet"
  ClearBody(key)
  local b = bodies[key]
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then
    local row = CreateFrame("Frame", nil, b.child)
    row:SetWidth(BODY_WIDTH) row:SetHeight(40)
    local fs = FS(row, "GameFontHighlight", "(no sheet imported — ML/RL: use Setup tab or /zl import)")
    fs:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -8)
    TrackRow(key, row, 40)
    return
  end
  local cards = Z.ItemCards.BuildCards(sheet)
  if Z.Util.ArrayCount(cards) == 0 then
    local row = CreateFrame("Frame", nil, b.child)
    row:SetWidth(BODY_WIDTH) row:SetHeight(40)
    local fs = FS(row, "GameFontHighlight", "(sheet is empty)")
    fs:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -8)
    TrackRow(key, row, 40)
    return
  end
  for ci = 1, Z.Util.ArrayCount(cards) do
    local card = cards[ci]
    local row = CreateFrame("Frame", nil, b.child)
    row:SetWidth(BODY_WIDTH)
    -- icon
    local icon = ItemIcon(row, card.itemID, 36)
    icon:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
    -- title: name + badges
    local title = FS(row, "GameFontNormal", "")
    title:SetPoint("TOPLEFT", row, "TOPLEFT", 48, -4)
    title:SetWidth(BODY_WIDTH - 60) title:SetJustifyH("LEFT")
    local nice = ItemName(card.itemID, card.quality)
    local badges = ""
    if card.hardres then badges = badges .. "  |cFFFF8000[HR]|r" end
    if card.unsr then badges = badges .. "  |cff888888[not SR'd]|r" end
    local nRolls = Z.Util.ArrayCount(card.rollSessions)
    if nRolls > 0 then
      badges = badges .. "  |cFF00FF00[rolled x" .. nRolls .. "]|r"
    end
    title:SetText(nice .. badges)
    -- body lines: SR list, then each session's player lines
    local lines = {}
    if Z.Util.ArrayCount(card.rollers) > 0 then
      for i = 1, Z.Util.ArrayCount(card.rollers) do
        table.insert(lines, RollerLine(card.rollers[i]))
      end
    else
      if card.unsr then
        table.insert(lines, "|cff888888(not on SR sheet — open roll)|r")
      else
        table.insert(lines, "|cff888888(no SRs — open roll)|r")
      end
    end
    for s = 1, Z.Util.ArrayCount(card.rollSessions) do
      local sess = card.rollSessions[s]
      local wtxt = ""
      if Z.Util.ArrayCount(sess.winners or {}) > 0 then
        local wn = {}
        for w = 1, Z.Util.ArrayCount(sess.winners) do
          table.insert(wn, PName(sess.winners[w]))
        end
        wtxt = " => " .. table.concat(wn, ", ")
      end
      table.insert(lines, "|cFFFFD700— rolls #" .. s .. " (" .. tostring(sess.mode or "?") .. ")" .. wtxt .. "|r")
      for m = 1, Z.Util.ArrayCount(sess.lines) do
        local e = sess.lines[m]
        local isW = false
        for w = 1, Z.Util.ArrayCount(sess.winners or {}) do
          if sess.winners[w] == e.name then isW = true break end
        end
        table.insert(lines, "    " .. RollLine(e, isW))
      end
      for t = 1, Z.Util.ArrayCount(sess.trades or {}) do
        local tr = sess.trades[t]
        table.insert(lines, "    |cff00FFFF" .. tostring(tr.from) .. " traded to " .. tostring(tr.to) .. " (transmog)|r")
      end
    end
    local body = FS(row, "GameFontHighlightSmall", table.concat(lines, "\n"))
    body:SetPoint("TOPLEFT", row, "TOPLEFT", 48, -22)
    body:SetWidth(BODY_WIDTH - 60) body:SetJustifyH("LEFT") body:SetJustifyV("TOP")
    local h = 30 + (Z.Util.ArrayCount(lines) * 13)
    if h < 52 then h = 52 end
    row:SetHeight(h)
    -- zebra
    if math.mod(ci, 2) == 0 then
      local z = row:CreateTexture(nil, "BACKGROUND")
      z:SetTexture(1, 1, 1, 0.03)
      z:SetAllPoints(row)
    end
    -- hover the row: item details + SR/HR summary
    local srNames = {}
    for i = 1, Z.Util.ArrayCount(card.rollers) do
      local r = card.rollers[i]
      local t = r.name .. " x" .. (r.rolls or 1)
      if r.sr_plus and r.sr_plus > 0 then t = t .. " (+" .. r.sr_plus .. ")" end
      table.insert(srNames, t)
    end
    -- NOTE: tooltip bodies stay plain (no class colors) — out of scope.
    row:EnableMouse(true)
    Tip(row, "item:" .. tostring(card.itemID),
      card.hardres and "HARD RESERVED" or ("SR: " .. (table.concat(srNames, ", ") ~= "" and table.concat(srNames, ", ") or "none")),
      nRolls > 0 and (nRolls .. " roll session(s) this raid — see rows") or "not rolled yet this raid")
    TrackRow(key, row, h)
  end
end

-------------------------------------------------------------------------------
-- Raids tab: imported raids (live sheet included). Activate switches the
-- active sheet to continue one (won marks + history come along).
-------------------------------------------------------------------------------
function M.RenderRaids()
  local key = "raids"
  ClearBody(key)
  local b = bodies[key]
  local now = (time and time()) or 0
  local rows = (Z.RaidArchive and Z.RaidArchive.ListSummaries(Z.DB, now)) or {}
  if Z.Util.ArrayCount(rows) == 0 then
    local row = CreateFrame("Frame", nil, b.child)
    row:SetWidth(BODY_WIDTH) row:SetHeight(40)
    local fs = FS(row, "GameFontHighlight", "(no past raids yet — import a sheet to start the history)")
    fs:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -8)
    TrackRow(key, row, 40)
    return
  end
  for i = 1, Z.Util.ArrayCount(rows) do
    local r = rows[i]
    local row = CreateFrame("Frame", nil, b.child)
    row:SetWidth(BODY_WIDTH) row:SetHeight(52)
    local title = FS(row, "GameFontNormal", "")
    title:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
    title:SetWidth(BODY_WIDTH - 110) title:SetJustifyH("LEFT")
    local activeTag = r.active and "  |cFF00FF00[ACTIVE]|r" or ""
    local rname = (r.raidName and r.raidName ~= "") and tostring(r.raidName) or "—"
    title:SetText(rname .. activeTag)
    local sub = FS(row, "GameFontHighlightSmall", "")
    sub:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -22)
    sub:SetWidth(BODY_WIDTH - 110) sub:SetJustifyH("LEFT")
    -- Raid start = sheet import time (raid start proxy), not archive time.
    local when = Z.Util.FormatTime(r.raidTime or r.importedAt)
    sub:SetText("ID " .. tostring(r.raidID) .. " · started " .. when
      .. " · by " .. tostring(r.importedBy) .. " · " .. tostring(r.source or "?")
      .. "\n" .. tostring(r.nItems or 0) .. " items · " .. tostring(r.nRollers or 0) .. " players · "
      .. tostring(r.nSessions or 0) .. " sessions · " .. tostring(r.nWon or 0) .. " won")
    sub:SetTextColor(PAL.mute[1], PAL.mute[2], PAL.mute[3])
    local rid = r.raidID
    if not r.active then
      local actB = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
      actB:SetWidth(80) actB:SetHeight(20)
      actB:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -4)
      actB:SetText("Activate")
      actB:SetScript("OnClick", function() Z.SRImport.ActivateArchivedRaid(rid) end)
      Tip(actB, "Activate", "Make this raid the active sheet and continue it.",
        "Won marks + roll history come along. The current sheet is archived first.")
    end
    -- zebra
    if math.mod(i, 2) == 0 then
      local z = row:CreateTexture(nil, "BACKGROUND")
      z:SetTexture(1, 1, 1, 0.03)
      z:SetAllPoints(row)
    end
    TrackRow(key, row, 52)
  end
end

-------------------------------------------------------------------------------
-- (ROLLS tab removed: DropLog.Show() prints to chat. Kept out of the
-- tab rail so the window stays Sheet | Raids | Members | Setup.)
-------------------------------------------------------------------------------
-- Members tab (key "versions"): grid of group + SR sheet, one rectangle per player
-------------------------------------------------------------------------------
-- Status fills: comfortable, muted. GREEN = soft sage (SR'd + here),
-- AMBER = warm ochre (outdated addon), RED = dusty rose (no SR here),
-- GREY = slate (sheet, not in group), DIM = faint slate (no addon).
local VER_COLORS = {
  GREEN  = { 0.30, 0.55, 0.32 },
  AMBER  = { 0.65, 0.52, 0.25 },
  RED    = { 0.60, 0.32, 0.32 },
  GREY   = { 0.32, 0.34, 0.38 },
  DIM    = { 0.22, 0.23, 0.26 },
}

function M.RenderVersions()
  local key = "versions"
  ClearBody(key)
  local b = bodies[key]
  local grid = Z.VersionGrid.GridNames()
  local perRow = 5
  local cw, chh, gap = 112, 22, 4
  -- No header line: the grid speaks for itself (colors + tooltips).
  -- Request lives in the header row now (Get sheet, next to Reset
  -- rolls): no in-grid button, no duplicate. Grid starts at the top.
  local gridTop = -4
  local gridF = CreateFrame("Frame", nil, b.child)
  gridF:SetWidth(BODY_WIDTH)
  local ri = 0
  local total = Z.Util.ArrayCount(grid)
  -- Center each row: a short last row sits mid-body, not left-hugging.
  local function rowCount(r0)
    local n = total - r0 * perRow
    if n > perRow then n = perRow end
    if n < 0 then n = 0 end
    return n
  end
  for i = 1, total do
    local nm, grp = grid[i].name, grid[i].inGroup
    local col = Z.VersionGrid.StatusFor(nm, grp)
    local cell = CreateFrame("Frame", nil, gridF)
    cell:SetWidth(cw) cell:SetHeight(chh)
    local r = math.floor((i - 1) / perRow)
    local c = math.mod(i - 1, perRow)
    local x0 = 4 + (BODY_WIDTH - 8 - (rowCount(r) * cw + (rowCount(r) - 1) * gap)) / 2
    cell:SetPoint("TOPLEFT", gridF, "TOPLEFT", x0 + c * (cw + gap), gridTop - r * (chh + gap))
    local t = cell:CreateTexture(nil, "BACKGROUND")
    local cc = VER_COLORS[col] or VER_COLORS.DIM
    t:SetTexture(cc[1], cc[2], cc[3], 1)
    t:SetAllPoints(cell)
    -- Full name in the member's class color, outlined for contrast
    -- against the status fill (1.12 FontString outline primitive).
    local label = nm
    if Z.ClassColors and Z.ClassColors.ClassColorHex and Z.ClassColors.ClassOf then
      label = "|c" .. Z.ClassColors.ClassColorHex(Z.ClassColors.ClassOf(nm)) .. nm .. "|r"
    end
    local fs = FS(cell, "GameFontNormal", label)
    fs:SetPoint("CENTER", cell, "CENTER", 0, 0)
    -- Outline for contrast against the status fill (nil-safe on mocks:
    -- GetFont/SetFont may not exist; pcall guards exotic returns).
    if fs.GetFont and fs.SetFont then
      local okF, fpath, fsize = pcall(fs.GetFont, fs)
      if okF and fpath then
        pcall(fs.SetFont, fs, fpath, fsize or 12, "OUTLINE")
      end
    end
    cell:EnableMouse(true)
    local seen = Z.VersionGrid.seen[nm]
    local tipSub = "v" .. tostring((seen and seen.version) or "?")
    local tipWhat = col == "GREEN" and "In group, SR ready"
      or col == "AMBER" and "In group, SR ready — outdated addon, update"
      or col == "GREY" and "Not in group, SR ready"
      or "In group, SR not ready"
    Tip(cell, PName(nm), tipSub, tipWhat)
    if i == total then ri = r end
  end
  local gh = 8 + (ri + 1) * (chh + gap)
  gridF:SetHeight(gh)
  TrackRow(key, gridF, gh)
  -- No refresh button: the grid auto-refreshes on open (Show fires
  -- Request), so versions are always fresh when the tab is visible.
end

-------------------------------------------------------------------------------
-- Setup tab: import / file / options
-------------------------------------------------------------------------------
function M.RenderSetup()
  local key = "setup"
  ClearBody(key)
  local b = bodies[key]
  local row = CreateFrame("Frame", nil, b.child)
  row:SetWidth(BODY_WIDTH) row:SetHeight(200)
  local t = FS(row, "GameFontNormalLarge", "Import & options")
  t:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -6)
  local sub = FS(row, "GameFontHighlightSmall", "Role: " .. Z.SRSecurity.RoleLabel() .. " — only ML / raid leader may broadcast sheets.")
  sub:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -28)
  sub:SetWidth(BODY_WIDTH - 16) sub:SetJustifyH("LEFT")
  -- Import + File live in the header row now (no duplicates here).
  local b3 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  b3:SetWidth(150) b3:SetHeight(24)
  b3:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -52)
  if Z.CharDB and Z.CharDB.autoRoll then b3:SetText("Auto-roll: ON") else b3:SetText("Auto-roll: OFF") end
  b3:SetScript("OnClick", function()
    Z.AutoRoll.Set((Z.CharDB and Z.CharDB.autoRoll) and "off" or "on")
    M.Refresh()
  end)
  Tip(b3, "Auto-roll", "Automatically /roll SR items when the ML starts a roll.")
  -- (Clear won marks removed: header Reset rolls is the same action,
  -- no duplicates.)
  local b5 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  b5:SetWidth(150) b5:SetHeight(24)
  b5:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -84)
  b5:SetText("Reset all settings")
  b5:SetScript("OnClick", function() Z.RequestResetAllSettings() end)
  Tip(b5, "Reset all settings",
    "Factory reset: sheet, raid history, drop log and all options back to defaults.",
    "Confirmation window first. Local data only — anyone can use it.")
  -- Loot-frame takeover toggle (the click-to-loot kill-switch stands it
  -- down persistently; this opts back in). Same as /zl lootframe.
  local b6 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  b6:SetWidth(150) b6:SetHeight(24)
  b6:SetPoint("LEFT", b5, "RIGHT", 8, 0)
  local function takeLabel()
    if Z.LootWindow and Z.LootWindow.TakeoverWanted() then
      return "Loot frame: ZUG"
    end
    return "Loot frame: BLIZZ"
  end
  b6:SetText(takeLabel())
  b6:SetScript("OnClick", function()
    if Z.LootWindow and Z.LootWindow.TakeoverWanted() then
      Z.LootWindow.SetTakeoverWanted(false)
    else
      Z.LootWindow.SetTakeoverWanted(true)
    end
    b6:SetText(takeLabel())
  end)
  Tip(b6, "Loot frame", "Which window handles corpse loot: ZugLoot or Blizzard's.",
    "Auto-switches to Blizzard if ZugLoot clicks stop reaching the server.")
  -- Solo rehearsal toggle (same as /zl rehearse): every corpse item gets
  -- a roll window with invented rollers, then a real loot-through award.
  -- Right beside it: auto-start toggle (same as /zl rollauto).
  local b7 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  b7:SetWidth(150) b7:SetHeight(24)
  b7:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -116)
  local function rehLabel()
    if Z.DB and Z.DB.rehearse then return "Rehearse: ON" end
    return "Rehearse: OFF"
  end
  b7:SetText(rehLabel())
  b7:SetScript("OnClick", function()
    if Z.Sim and Z.Sim.SetRehearse then Z.Sim.SetRehearse(nil) end
    b7:SetText(rehLabel())
    M.Refresh()
  end)
  Tip(b7, "Rehearse", "Solo master-loot practice: corpse items roll with invented raiders.",
    "Solo only. Awards really loot the corpse.")
  local b8 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  b8:SetWidth(150) b8:SetHeight(24)
  b8:SetPoint("LEFT", b7, "RIGHT", 8, 0)
  local function rehAutoLabel()
    if Z.DB and Z.DB.rollAuto then return "Auto-start: ON" end
    return "Auto-start: OFF"
  end
  b8:SetText(rehAutoLabel())
  b8:SetScript("OnClick", function()
    if Z.DB then Z.DB.rollAuto = not Z.DB.rollAuto end
    b8:SetText(rehAutoLabel())
    M.Refresh()
  end)
  Tip(b8, "Auto-start rolls", "Rolls start by themselves as corpses are looted.",
    "OFF (default): the ML picks each item's Roll button. General master-loot behaviour.")
  local info = FS(row, "GameFontHighlightSmall",
    "Roll time: " .. tostring(Z.DB and Z.DB.rollTime or 15) .. "s  (/zl time N)\n" ..
    "Drops logged: " .. tostring(Z.Util.ArrayCount((Z.DB and Z.DB.drops) or {})) .. "  (/zl log)\n" ..
    "Simulate (needs sheet, writes back): /zl sim <link> — /zl simboss <boss>")
  info:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -148)
  info:SetWidth(BODY_WIDTH - 16) info:SetJustifyH("LEFT")
  TrackRow(key, row, 264)
end

-------------------------------------------------------------------------------
-- Shell
-------------------------------------------------------------------------------
local RENDER = {
  sheet = M.RenderSheet,
  raids = M.RenderRaids,
  versions = M.RenderVersions,
  setup = M.RenderSetup,
}

function M.Refresh()
  if not M.frame then return end
  local sheet = Z.DB and Z.DB.sheet
  local nItems = sheet and Z.Util.TableCount(sheet.items) or 0
  local nRolls = sheet and Z.Util.TableCount(sheet.rolls or {}) or 0
  local meta = sheet and sheet.meta
  local started = Z.Util.FormatTime(meta and meta.importedAt)
  -- Prominent active raid on the brand row.
  if sheet and meta and meta.raidID then
    local nm = (meta.raidName and meta.raidName ~= "") and tostring(meta.raidName) or "—"
    local st = Z.Util.FormatTime(meta.importedAt)
    activeRaidFS:SetText("|cFF00FF00ACTIVE RAID:|r  " .. nm .. "  |cff888888started " .. st .. "|r")
  else
    activeRaidFS:SetText("|cff888888no active raid|r")
  end
  headerFS:SetText("ID " .. tostring((meta and meta.raidID) or "—")
    .. "   |   " .. tostring((meta and meta.raidName) or "—")
    .. "   |   started " .. started
    .. "   |   " .. tostring(nItems) .. " items   |   " .. tostring(nRolls) .. " rolled")
  -- Get-sheet button is always visible (re-sync on demand: new raid,
  -- sheet updated mid-run, or just making sure). Solo it prints "nobody
  -- to ask" via RequestSheet — no special-casing here.
  if M.reqSheetBtn and M.reqSheetBtn.Show then M.reqSheetBtn:Show() end
  for _, tb in ipairs(tabBtns) do
    if tb.key == M.activeTab then
      tb.fs:SetTextColor(PAL.ink[1], PAL.ink[2], PAL.ink[3])
      tb.ul:Show()
    else
      tb.fs:SetTextColor(PAL.mute[1], PAL.mute[2], PAL.mute[3])
      tb.ul:Hide()
    end
  end
  for _, td in ipairs(TABS) do
    local bd = bodies[td.key]
    if bd then
      if td.key == M.activeTab then bd.sf:Show() else bd.sf:Hide() end
      SyncSlider(td.key)
    end
  end
  local fn = RENDER[M.activeTab]
  if fn then fn() end
end

function M.SelectTab(key)
  M.activeTab = key
  M.Refresh()
end

-- Test hook (used by tests/mockrun.lua): slider visibility per tab.
function M.DebugSliderState()
  local out = {}
  for key, b in pairs(bodies) do
    out[key] = (b.sb and b.sb.IsVisible and b.sb:IsVisible()) and true or false
  end
  return out
end

-- Test hook: live layout numbers. Guards the Lua-scoping rule above:
-- BODY_WIDTH must always track winW (a stale 596 here means the row layout
-- silently detached from the window size again).
function M.DebugLayout()
  return { winW = M.winW, winH = M.winH, bodyWidth = BODY_WIDTH }
end

-- Test hook: current header line text.
function M.DebugHeader()
  if headerFS and headerFS.GetText then return headerFS:GetText() end
  return nil
end

-- Test hook: current active-raid line text.
function M.DebugActiveRaid()
  if activeRaidFS and activeRaidFS.GetText then return activeRaidFS:GetText() end
  return nil
end

-- Test hook: header buttons presence + Get-sheet visibility.
function M.DebugHeaderButtons()
  local out = {}
  local function present(b)
    return b ~= nil
  end
  local hb = M.headerBtns or {}
  out.reset = present(hb.reset or M.resetBtn)
  out.getsheet = present(hb.getsheet or M.reqSheetBtn)
  out.import = present(hb.import)
  out.file = present(hb.file)
  out.getsheetVisible = M.reqSheetBtn and M.reqSheetBtn.IsVisible
    and M.reqSheetBtn:IsVisible() or false
  return out
end

function M.Build()
  if not M.winW or not M.winH then M.RefreshSize() end
  local winW, winH = M.winW, M.winH
  local f = CreateFrame("Frame", "ZugLootMainWindow", UIParent)
  f:SetWidth(winW) f:SetHeight(winH)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  f:SetClampedToScreen(true)
  f:SetMovable(true) f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() f:StartMoving() end)
  f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
  f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  f:SetBackdropColor(PAL.bg[1], PAL.bg[2], PAL.bg[3], PAL.bg[4])
  f:SetBackdropBorderColor(PAL.line[1], PAL.line[2], PAL.line[3], 1)
  -- gold accent strip
  local strip = f:CreateTexture(nil, "OVERLAY")
  strip:SetTexture(PAL.gold[1], PAL.gold[2], PAL.gold[3], 0.9)
  strip:SetHeight(2)
  strip:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  strip:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
  -- header
  local brand = FS(f, "GameFontNormalLarge", "ZUGLOOT")
  brand:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -12)
  brand:SetTextColor(PAL.gold[1], PAL.gold[2], PAL.gold[3])
  local ver = FS(f, "GameFontNormalSmall", "v" .. tostring(Z.VERSION))
  ver:SetPoint("LEFT", brand, "RIGHT", 8, 0)
  ver:SetTextColor(PAL.mute[1], PAL.mute[2], PAL.mute[3])
  -- Active raid, prominent on the brand row: green ACTIVE + raid name + ID.
  activeRaidFS = FS(f, "GameFontNormal", "")
  activeRaidFS:SetPoint("TOPRIGHT", f, "TOPRIGHT", -150, -12)
  activeRaidFS:SetWidth(winW - 320) activeRaidFS:SetJustifyH("RIGHT")
  headerFS = FS(f, "GameFontHighlightSmall", "")
  headerFS:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
  headerFS:SetWidth(winW - 120) headerFS:SetJustifyH("LEFT")
  headerFS:SetTextColor(PAL.mute[1], PAL.mute[2], PAL.mute[3])
  local xb = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  xb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
  xb:SetScript("OnClick", function() f:Hide() end)
  -- Top-row action buttons, right of the header next to the close button:
  -- Reset rolls (was the only one) + Request SR sheet + Import + Load
  -- from File. One row, no duplicates elsewhere: Setup keeps options
  -- only (no import/clear buttons there anymore).
  -- Reset-rolls button. Opens a confirmation window; in party/raid only
  -- ML / raid leader may use it.
  local resetB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  resetB:SetWidth(96) resetB:SetHeight(20)
  resetB:SetPoint("TOPRIGHT", f, "TOPRIGHT", -34, -32)
  resetB:SetText("Reset rolls")
  resetB:SetScript("OnClick", function() Z.SRImport.RequestResetRollLog() end)
  Tip(resetB, "Reset rolls",
    "Clear all recorded rolls and won marks for this raid. The SR sheet itself is kept.",
    "Solo: always allowed. In party/raid: master looter or raid leader only.")
  M.resetBtn = resetB
  M.headerBtns = M.headerBtns or {}
  M.headerBtns.reset = resetB
  -- Request SR sheet: asks the ML (else the raid leader) for the sheet.
  -- Visible in-group only when we hold no sheet (nothing to fetch).
  local reqB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  reqB:SetWidth(96) reqB:SetHeight(20)
  reqB:SetPoint("RIGHT", resetB, "LEFT", -6, 0)
  reqB:SetText("Get sheet")
  reqB:SetScript("OnClick", function()
    if Z.Comm and Z.Comm.RequestSheet then Z.Comm.RequestSheet() end
  end)
  Tip(reqB, "Request SR sheet",
    "Asks the master looter for the current sheet (raid leader answers when no ML sheet exists).",
    "Sheets from anyone else are ignored.")
  M.reqSheetBtn = reqB
  M.headerBtns = M.headerBtns or {}
  M.headerBtns.getsheet = reqB
  -- Import (paste): same entry as the old Setup button.
  local impB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  impB:SetWidth(70) impB:SetHeight(20)
  impB:SetPoint("RIGHT", reqB, "LEFT", -6, 0)
  impB:SetText("Import")
  M.headerBtns = M.headerBtns or {}
  M.headerBtns.import = impB
  impB:SetScript("OnClick", function() Z.SRImport.ShowPaste() end)
  Tip(impB, "Import", "Paste a raidres export or line-format sheet.",
    "ML / raid leader only in group; solo preview allowed.")
  -- Load from File: same entry as the old Setup button.
  local fileB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  fileB:SetWidth(70) fileB:SetHeight(20)
  fileB:SetPoint("RIGHT", impB, "LEFT", -6, 0)
  fileB:SetText("File")
  M.headerBtns = M.headerBtns or {}
  M.headerBtns.file = fileB
  fileB:SetScript("OnClick", function() Z.SRImport.LoadFromFile() end)
  Tip(fileB, "Load from File", "Reads CustomData/ZugLoot_SR.txt (blob or lines).",
    "Requires Nampower.")
  hairline(f, -56, 14, -14)
  -- tab rail (Aegis BuildSpecTabs pattern: buttons + gold underline)
  local n = Z.Util.ArrayCount(TABS)
  local w = math.floor((winW - 100) / n)
  for i = 1, n do
    local td = TABS[i]
    local b = CreateFrame("Button", "ZugLootTab_" .. td.key, f)
    b:SetWidth(w) b:SetHeight(24)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", 16 + (i - 1) * w, -60)
    local hov = b:CreateTexture(nil, "BACKGROUND")
    hov:SetAllPoints(b)
    hov:SetTexture(1, 1, 1, 0.05) hov:Hide()
    local fs = FS(b, "GameFontNormal", td.label)
    fs:SetPoint("CENTER", b, "CENTER", 0, 1)
    fs:SetTextColor(PAL.mute[1], PAL.mute[2], PAL.mute[3])
    local ul = b:CreateTexture(nil, "OVERLAY")
    ul:SetTexture(PAL.gold[1], PAL.gold[2], PAL.gold[3], 1)
    ul:SetHeight(2)
    ul:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 4, 0)
    ul:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -4, 0)
    ul:Hide()
    local k = td.key
    b:SetScript("OnEnter", function() hov:Show() end)
    b:SetScript("OnLeave", function() hov:Hide() end)
    b:SetScript("OnClick", function() M.SelectTab(k) end)
    table.insert(tabBtns, { key = k, fs = fs, ul = ul })
  end
  hairline(f, -86, 14, -14)
  -- bodies
  for _, td in ipairs(TABS) do MakeBody(f, td.key) end
  -- footer
  hairline(f, -(winH - 30), 14, -14)
  local closeB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  closeB:SetWidth(80) closeB:SetHeight(20)
  closeB:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 6)
  closeB:SetText("Close")
  closeB:SetScript("OnClick", function() f:Hide() end)
  M.frame = f
  f:Hide()
end

function M.Show(tab)
  M.EnsureSize()
  if not M.frame then M.Build() end
  if tab then M.activeTab = tab end
  if M.activeTab == "versions" and Z.VersionGrid then Z.VersionGrid.Request() end
  M.Refresh()
  M.frame:Show()
end

function M.Toggle(tab)
  if not M.frame then M.Build() end
  if M.frame:IsVisible() and (not tab or tab == M.activeTab) then
    M.frame:Hide()
  else
    M.Show(tab)
  end
end

function M.Hide()
  if M.frame then M.frame:Hide() end
end
