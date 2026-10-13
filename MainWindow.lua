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

local WIN_W, WIN_H = 660, 540

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
  { key = "rolls",    label = "ROLLS" },
  { key = "versions", label = "VERSIONS" },
  { key = "setup",    label = "SETUP" },
}

-- per-tab scroll bodies: tabKey -> { sf, child, sb, y }
local bodies = {}
local tabBtns = {}
local headerFS = nil

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
local BODY_TOP, BODY_BOTTOM, BODY_LEFT, BODY_WIDTH = -118, 14, 14, 596

local function MakeBody(parent, key)
  local sf = CreateFrame("ScrollFrame", "ZugLootBody_" .. key, parent)
  sf:SetPoint("TOPLEFT", parent, "TOPLEFT", BODY_LEFT, BODY_TOP)
  sf:SetWidth(BODY_WIDTH) sf:SetHeight(WIN_H + BODY_TOP - BODY_BOTTOM)
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

local function ClearBody(key)
  local b = bodies[key]
  if not b then return end
  for i = 1, Z.Util.ArrayCount(b.rows) do
    if b.rows[i] and b.rows[i].Hide then b.rows[i]:Hide() end
  end
  b.rows = {}
  b.child:SetHeight(10)
  b.sb:SetMinMaxValues(0, 0) b.sb:SetValue(0)
  if b.sf.SetVerticalScroll then b.sf:SetVerticalScroll(0) end
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
  if maxScroll <= 8 then b.sb:Hide() else b.sb:Show() end
end

-------------------------------------------------------------------------------
-- Sheet tab: item cards
-------------------------------------------------------------------------------
local function RollerLine(r)
  local s = r.name .. " x" .. tostring(r.rolls or 1)
  if r.sr_plus and r.sr_plus > 0 then
    s = s .. " |cFFFFD700(+" .. r.sr_plus .. ")|r"
  end
  if r.won then s = s .. "  |cFFFF0000[WON]|r" end
  return s
end

local function RollLine(e, isWinner)
  local s = e.name .. " " .. tostring(e.base)
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
        wtxt = " => " .. table.concat(sess.winners, ", ")
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
    title:SetText(tostring(r.raidID) .. activeTag)
    local sub = FS(row, "GameFontHighlightSmall", "")
    sub:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -22)
    sub:SetWidth(BODY_WIDTH - 110) sub:SetJustifyH("LEFT")
    local when = "?"
    if r.archivedAt and r.archivedAt > 0 then
      if date then when = date("%Y-%m-%d %H:%M", r.archivedAt)
      elseif os and os.date then when = os.date("%Y-%m-%d %H:%M", r.archivedAt) end
    end
    sub:SetText("by " .. tostring(r.importedBy) .. " · " .. tostring(r.source or "?") .. " · " .. when
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
-- Rolls tab: flat session log (newest first), each drop on its own block
-------------------------------------------------------------------------------
function M.RenderRolls()
  local key = "rolls"
  ClearBody(key)
  local b = bodies[key]
  local drops = (Z.DB and Z.DB.drops) or {}
  local n = Z.Util.ArrayCount(drops)
  if n == 0 then
    local row = CreateFrame("Frame", nil, b.child)
    row:SetWidth(BODY_WIDTH) row:SetHeight(40)
    local fs = FS(row, "GameFontHighlight", "(no drops logged yet)")
    fs:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -8)
    TrackRow(key, row, 40)
    return
  end
  for i = n, 1, -1 do
    local d = drops[i]
    local row = CreateFrame("Frame", nil, b.child)
    row:SetWidth(BODY_WIDTH)
    local title = FS(row, "GameFontNormal", "")
    title:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
    title:SetWidth(BODY_WIDTH - 16) title:SetJustifyH("LEFT")
    local linkTxt = d.link or ("item:" .. tostring(d.itemID or "?"))
    local wtxt = d.winner and ("  |cFF00FF00-> " .. d.winner .. "|r") or ""
    title:SetText(linkTxt .. "  |cff888888[" .. tostring(d.source or "?") .. " / " .. tostring(d.outcome or "?") .. "]|r" .. wtxt)
    row:SetHeight(28)
    TrackRow(key, row, 28)
  end
end

-------------------------------------------------------------------------------
-- Versions tab: squares grid, one per raid member
-------------------------------------------------------------------------------
local VER_COLORS = {
  GREEN  = { 0.2, 0.9, 0.2 },
  YELLOW = { 1.0, 0.82, 0.0 },
  RED    = { 1.0, 0.3, 0.3 },
  GREY   = { 0.4, 0.4, 0.4 },
}

function M.RenderVersions()
  local key = "versions"
  ClearBody(key)
  local b = bodies[key]
  local names = Z.VersionGrid.RosterNames()
  local perRow = 12
  local sq = 28
  local row = CreateFrame("Frame", nil, b.child)
  row:SetWidth(BODY_WIDTH) row:SetHeight(40)
  local hint = FS(row, "GameFontHighlightSmall", "ZugLoot " .. tostring(Z.VERSION) .. " — green=current, yellow=outdated, red=no addon. (auto-refreshes on open)")
  hint:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
  hint:SetWidth(BODY_WIDTH - 16) hint:SetJustifyH("LEFT")
  TrackRow(key, row, 30)
  local grid = CreateFrame("Frame", nil, b.child)
  grid:SetWidth(BODY_WIDTH)
  local ri = 0
  for i = 1, Z.Util.ArrayCount(names) do
    local nm = names[i]
    local col = Z.VersionGrid.ColorFor(nm)
    local cell = CreateFrame("Frame", nil, grid)
    cell:SetWidth(sq) cell:SetHeight(sq)
    local r = math.floor((i - 1) / perRow)
    local c = math.mod(i - 1, perRow)
    cell:SetPoint("TOPLEFT", grid, "TOPLEFT", 4 + c * (sq + 6), -4 - r * (sq + 6))
    local t = cell:CreateTexture(nil, "BACKGROUND")
    local cc = VER_COLORS[col] or VER_COLORS.GREY
    t:SetTexture(cc[1], cc[2], cc[3], 1)
    t:SetAllPoints(cell)
    local fs = FS(cell, "GameFontNormalSmall", string.sub(nm, 1, 2))
    fs:SetPoint("CENTER", cell, "CENTER", 0, 0)
    fs:SetTextColor(0, 0, 0)
    cell:EnableMouse(true)
    local seen = Z.VersionGrid.seen[nm]
    Tip(cell, nm, "v" .. tostring((seen and seen.version) or "no addon"), col == "GREEN" and "ready for auto-resolve" or "needs update / no addon")
    if i == Z.Util.ArrayCount(names) then ri = r end
  end
  local gh = 8 + (ri + 1) * (sq + 6)
  grid:SetHeight(gh)
  TrackRow(key, grid, gh)
  local rowB = CreateFrame("Frame", nil, b.child)
  rowB:SetWidth(BODY_WIDTH) rowB:SetHeight(36)
  local btn = CreateFrame("Button", nil, rowB, "UIPanelButtonTemplate")
  btn:SetWidth(140) btn:SetHeight(22)
  btn:SetPoint("TOPLEFT", rowB, "TOPLEFT", 4, -6)
  btn:SetText("Refresh versions")
  btn:SetScript("OnClick", function() Z.VersionGrid.Request() M.Refresh() end)
  TrackRow(key, rowB, 36)
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
  local b1 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  b1:SetWidth(150) b1:SetHeight(24)
  b1:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -52)
  b1:SetText("Import (paste)")
  b1:SetScript("OnClick", function() Z.SRImport.ShowPaste() end)
  local b2 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  b2:SetWidth(150) b2:SetHeight(24)
  b2:SetPoint("LEFT", b1, "RIGHT", 8, 0)
  b2:SetText("Load from File")
  b2:SetScript("OnClick", function() Z.SRImport.LoadFromFile() end)
  Tip(b1, "Import", "Paste a raidres export or line-format sheet.", "ML / raid leader only in group; solo preview allowed.")
  Tip(b2, "Load from File", "Reads CustomData/ZugLoot_SR.txt (blob or lines).", "Requires Nampower.")
  local b3 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  b3:SetWidth(150) b3:SetHeight(24)
  b3:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -84)
  if Z.CharDB and Z.CharDB.autoRoll then b3:SetText("Auto-roll: ON") else b3:SetText("Auto-roll: OFF") end
  b3:SetScript("OnClick", function()
    Z.AutoRoll.Set((Z.CharDB and Z.CharDB.autoRoll) and "off" or "on")
    M.Refresh()
  end)
  Tip(b3, "Auto-roll", "Automatically /roll SR items when the ML starts a roll.")
  local b4 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  b4:SetWidth(150) b4:SetHeight(24)
  b4:SetPoint("LEFT", b3, "RIGHT", 8, 0)
  b4:SetText("Clear won marks")
  b4:SetScript("OnClick", function() Z.SRImport.RequestResetRollLog() end)
  Tip(b4, "Clear won marks", "Same as Reset rolls: confirmation window first.")
  local info = FS(row, "GameFontHighlightSmall",
    "Roll time: " .. tostring(Z.DB and Z.DB.rollTime or 15) .. "s  (/zl time N)\n" ..
    "Drops logged: " .. tostring(Z.Util.ArrayCount((Z.DB and Z.DB.drops) or {})) .. "  (see Rolls tab)\n" ..
    "Simulate (needs sheet, writes back): /zl sim <link> — /zl simboss <boss>")
  info:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -118)
  info:SetWidth(BODY_WIDTH - 16) info:SetJustifyH("LEFT")
  TrackRow(key, row, 200)
end

-------------------------------------------------------------------------------
-- Shell
-------------------------------------------------------------------------------
local RENDER = {
  sheet = M.RenderSheet,
  raids = M.RenderRaids,
  rolls = M.RenderRolls,
  versions = M.RenderVersions,
  setup = M.RenderSetup,
}

function M.Refresh()
  if not M.frame then return end
  local sheet = Z.DB and Z.DB.sheet
  local nItems = sheet and Z.Util.TableCount(sheet.items) or 0
  local nRolls = sheet and Z.Util.TableCount(sheet.rolls or {}) or 0
  headerFS:SetText("raid: " .. tostring(sheet and sheet.meta and sheet.meta.raidID or "—")
    .. "   |   " .. tostring(nItems) .. " items   |   " .. tostring(nRolls) .. " rolled")
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
    end
  end
  local fn = RENDER[M.activeTab]
  if fn then fn() end
end

function M.SelectTab(key)
  M.activeTab = key
  M.Refresh()
end

function M.Build()
  local f = CreateFrame("Frame", "ZugLootMainWindow", UIParent)
  f:SetWidth(WIN_W) f:SetHeight(WIN_H)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
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
  headerFS = FS(f, "GameFontHighlightSmall", "")
  headerFS:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
  headerFS:SetWidth(WIN_W - 120) headerFS:SetJustifyH("LEFT")
  headerFS:SetTextColor(PAL.mute[1], PAL.mute[2], PAL.mute[3])
  local xb = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  xb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
  xb:SetScript("OnClick", function() f:Hide() end)
  -- Reset-rolls button, top of the window next to the close button.
  -- Opens a confirmation window; in party/raid only ML / raid leader may use it.
  local resetB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  resetB:SetWidth(96) resetB:SetHeight(20)
  resetB:SetPoint("TOPRIGHT", f, "TOPRIGHT", -34, -32)
  resetB:SetText("Reset rolls")
  resetB:SetScript("OnClick", function() Z.SRImport.RequestResetRollLog() end)
  Tip(resetB, "Reset rolls",
    "Clear all recorded rolls and won marks for this raid. The SR sheet itself is kept.",
    "Solo: always allowed. In party/raid: master looter or raid leader only.")
  M.resetBtn = resetB
  hairline(f, -56, 14, -14)
  -- tab rail (Aegis BuildSpecTabs pattern: buttons + gold underline)
  local n = Z.Util.ArrayCount(TABS)
  local w = math.floor(560 / n)
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
  hairline(f, -(WIN_H - 30), 14, -14)
  local closeB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  closeB:SetWidth(80) closeB:SetHeight(20)
  closeB:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 6)
  closeB:SetText("Close")
  closeB:SetScript("OnClick", function() f:Hide() end)
  M.frame = f
  f:Hide()
end

function M.Show(tab)
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
