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
-- iconLink is ALWAYS a full color link when the client knows the item
-- (shift-click inserts a real link, never "item:NNNN"): resolved via
-- the shared link-first chain, which upgrades bare ids.
-- ALL behavior (hover/ctrl/shift) runs the ONE shared ItemIcon module
-- (ItemIcon.lua): sheet cards, the log header, the raider window and
-- the loot window all call the same handlers, so they can never drift.
local function ItemIcon(parent, itemID, size)
  local b = CreateFrame("Button", nil, parent)
  b:SetWidth(size or 36) b:SetHeight(size or 36)
  local tex = b:CreateTexture(nil, "ARTWORK")
  tex:SetAllPoints(b)
  local _, link, quality, _, _, _, _, _, icon = nil, nil, nil, nil, nil, nil, nil, nil, nil
  if Z.LootWindow and Z.LootWindow.ResolveItemInfo then
    local _, fullLink, q, texPath = Z.LootWindow.ResolveItemInfo(itemID, nil, nil, nil, nil)
    if fullLink and fullLink ~= "" then link = fullLink end
    if q ~= nil then quality = q end
    if texPath and texPath ~= "" then icon = texPath end
  elseif GetItemInfo then
    _, link, quality, _, _, _, _, _, icon = GetItemInfo(tonumber(itemID))
  end
  tex:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
  b.iconLink = link
  b.itemID = itemID
  M.zlCardLinks = M.zlCardLinks or {}
  M.zlCardLinks[tonumber(itemID) or itemID] = link
  M.zlCardIcons = M.zlCardIcons or {}
  M.zlCardIcons[tonumber(itemID) or itemID] = b -- placement for try-on assert
  -- quality border
  local q = QUALITY_RGB[quality or 4] or QUALITY_RGB[4]
  local bd = b:CreateTexture(nil, "OVERLAY")
  bd:SetTexture(q[1], q[2], q[3], 0.9)
  bd:SetHeight(1) bd:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0) bd:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
  if Z.ItemIcon and Z.ItemIcon.Wire then
    Z.ItemIcon.Wire(b, function()
      return { itemID = b.itemID, link = b.iconLink,
        onLink = function(full) b.iconLink = full end }
    end)
  end
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
  -- 3 even columns across the body. Cards flow row-major (1-2-3, 4-5-6)
  -- and every column scrolls with the SAME scroll body, so the styling
  -- (zebra, icons, tooltips) is untouched — only the placement changes.
  local NCOL = 3
  local GAP = 8
  local colW = math.floor((BODY_WIDTH - (NCOL - 1) * GAP) / NCOL)
  local nCards = Z.Util.ArrayCount(cards)
  -- Column heights first (equal rows would strand short cards): each
  -- card's height from its line count, columns stack independently and
  -- the tracked row takes the tallest column. Rollers flow in TWO
  -- columns inside the card, so a roller row costs ceil(n/2) lines;
  -- roll HISTORY lives in the detail window (click), not on the card.
  local function rollerRows(card)
    local n = Z.Util.ArrayCount(card.rollers)
    if n == 0 then return 1 end -- the "(no SRs — open roll)" line
    return math.ceil(n / 2)
  end
  local function cardH(card)
    local h = 30 + (rollerRows(card) * 13) + 6 -- padding, no hint line
    if h < 52 then h = 52 end
    return h
  end
  local function buildCard(parent, card, w, ci)
    -- Clickable card: a Button (frames can't take OnClick — the client
    -- errors "unnamed doesn't have an OnClick script").
    local row = CreateFrame("Button", nil, parent)
    row:SetWidth(w)
    -- icon
    local icon = ItemIcon(row, card.itemID, 36)
    icon:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
    -- title: name + badges
    local title = FS(row, "GameFontNormal", "")
    title:SetPoint("TOPLEFT", row, "TOPLEFT", 48, -4)
    title:SetWidth(w - 56) title:SetJustifyH("LEFT")
    local nice = ItemName(card.itemID, card.quality)
    -- My SR: this item has MY name on its roller list — a gold square
    -- around the card (no text badge) so my items pop at a glance.
    local me = UnitName and UnitName("player") or nil
    local mySR = false
    if me and me ~= "" then
      for i = 1, Z.Util.ArrayCount(card.rollers) do
        if card.rollers[i] and card.rollers[i].name == me then
          mySR = true break
        end
      end
    end
    if mySR and row.CreateTexture then
      local hl = row:CreateTexture(nil, "OVERLAY")
      if hl.SetTexture then hl:SetTexture(1, 0.82, 0, 0.28) end
      if hl.SetAllPoints then hl:SetAllPoints(row) end
      if hl.Show then hl:Show() end
      row.zlMineHL = hl
    end
    local badges = ""
    if card.hardres then badges = badges .. "  |cFFFF8000[HR]|r" end
    if card.unsr then badges = badges .. "  |cff888888[not SR'd]|r" end
    local nRolls = Z.Util.ArrayCount(card.rollSessions)
    title:SetText(nice .. badges)
    -- Drop count top-right: #N sessions this raid (#0 = never rolled).
    -- Replaces the old [xN] title badge + "not rolled yet" hint line.
    local dropN = FS(row, "GameFontNormalSmall", "#" .. nRolls)
    dropN:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -6)
    dropN:SetJustifyH("RIGHT")
    if dropN.SetTextColor then
      if nRolls > 0 then dropN:SetTextColor(0.3, 1, 0.3)
      else dropN:SetTextColor(0.55, 0.55, 0.6) end
    end
    M.zlCardDrops = M.zlCardDrops or {}
    M.zlCardDrops[card.itemID] = nRolls
    M.zlCardMine = M.zlCardMine or {}
    M.zlCardMine[card.itemID] = mySR
    -- body: SR rollers in TWO columns (left half, right half).
    local nR = Z.Util.ArrayCount(card.rollers)
    M.zlCardCols = M.zlCardCols or {}
    if nR > 0 then
      M.zlCardCols[card.itemID] = { left = math.ceil(nR / 2), right = nR - math.ceil(nR / 2) }
      local half = math.ceil(nR / 2)
      local left, right = {}, {}
      for i = 1, nR do
        local line = RollerLine(card.rollers[i])
        if i <= half then table.insert(left, line)
        else table.insert(right, line) end
      end
      local bodyL = FS(row, "GameFontHighlightSmall", table.concat(left, "\n"))
      bodyL:SetPoint("TOPLEFT", row, "TOPLEFT", 48, -22)
      bodyL:SetWidth(math.floor((w - 60) / 2)) bodyL:SetJustifyH("LEFT") bodyL:SetJustifyV("TOP")
      if Z.Util.ArrayCount(right) > 0 then
        local bodyR = FS(row, "GameFontHighlightSmall", table.concat(right, "\n"))
        bodyR:SetPoint("TOPLEFT", row, "TOPLEFT", 48 + math.floor((w - 60) / 2) + 8, -22)
        bodyR:SetWidth(math.floor((w - 60) / 2)) bodyR:SetJustifyH("LEFT") bodyR:SetJustifyV("TOP")
      end
    else
      local emptyTxt = "|cff888888(no SRs — open roll)|r"
      if card.unsr then emptyTxt = "|cff888888(not on SR sheet — open roll)|r" end
      local bodyE = FS(row, "GameFontHighlightSmall", emptyTxt)
      bodyE:SetPoint("TOPLEFT", row, "TOPLEFT", 48, -22)
      bodyE:SetWidth(w - 56) bodyE:SetJustifyH("LEFT") bodyE:SetJustifyV("TOP")
    end
    -- No hint line (the #N corner count says it all; the card still
    -- opens the roll-log window on click).
    local h = cardH(card)
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
      nRolls > 0 and (nRolls .. " roll session(s) this raid — click for the log") or "no rolls yet — click for the log")
    -- Left click: roll-log window for this item (icon keeps its own
    -- link-in-chat click; the card body opens the log).
    local logID = card.itemID
    if row.RegisterForClicks then
      pcall(row.RegisterForClicks, row, "LeftButtonUp")
    end
    row:SetScript("OnClick", function() M.ShowItemLog(logID) end)
    return row
  end
  -- Row-major placement into 3 columns: each visual row is one tracked
  -- TrackRow entry (single scroll body => everything scrolls together).
  -- ci: card index; col = (ci-1) % 3; vy = stacked row heights.
  local ri = 0
  while ri * NCOL < nCards do
    local rowF = CreateFrame("Frame", nil, b.child)
    rowF:SetWidth(BODY_WIDTH)
    local rh = 0
    rowF.zlCells = {} -- placement record for the layout assert
    for c = 0, NCOL - 1 do
      local ci = ri * NCOL + c + 1
      if ci <= nCards then
        local card = cards[ci]
        local cell = buildCard(rowF, card, colW, ci)
        local cx = c * (colW + GAP)
        cell:SetPoint("TOPLEFT", rowF, "TOPLEFT", cx, 0)
        table.insert(rowF.zlCells, { x = cx, w = colW })
        local ch = cardH(card)
        if ch > rh then rh = ch end
      end
    end
    rowF:SetHeight(rh)
    TrackRow(key, rowF, rh)
    ri = ri + 1
  end
end

-------------------------------------------------------------------------------
-- Item roll-log window: left-click a sheet card to open it. Loot icon +
-- item name on top (pretty header), then every roll session newest-first
-- with winner + full per-player lines. Standalone window (own frame, own
-- close), nil-safe headless (data via ItemLogLines for tests).
-------------------------------------------------------------------------------
M.itemLogFrame = nil
M.itemLogItem = nil

-- Pure lines for an item's roll log (headless-testable): header +
-- newest-first sessions. Returns { header={itemID, name}, lines={...} }.
function M.ItemLogLines(itemID)
  local sheet = Z.DB and Z.DB.sheet
  local name = ItemName(itemID, sheet and sheet.items[itemID] and sheet.items[itemID].quality or 4)
  local out = { header = { itemID = itemID, name = name }, lines = {} }
  if not sheet then return out end
  local cards = Z.ItemCards and Z.ItemCards.BuildCards(sheet) or {}
  local card = nil
  for i = 1, Z.Util.ArrayCount(cards) do
    if cards[i].itemID == itemID then card = cards[i] break end
  end
  if not card then return out end
  local nS = Z.Util.ArrayCount(card.rollSessions)
  for s = nS, 1, -1 do
    local sess = card.rollSessions[s]
    local wtxt = ""
    if Z.Util.ArrayCount(sess.winners or {}) > 0 then
      local wn = {}
      for w = 1, Z.Util.ArrayCount(sess.winners) do
        table.insert(wn, PName(sess.winners[w]))
      end
      wtxt = " => " .. table.concat(wn, ", ")
    end
    local when = ""
    if sess.t and sess.t > 0 and Z.Util.FormatTime then
      when = " " .. Z.Util.FormatTime(sess.t)
    end
    table.insert(out.lines, "|cFFFFD700— drops/rolls #" .. s .. " (" .. tostring(sess.mode or "?") .. ")" .. wtxt .. when .. "|r")
    for m = 1, Z.Util.ArrayCount(sess.lines) do
      local e = sess.lines[m]
      local isW = false
      for w = 1, Z.Util.ArrayCount(sess.winners or {}) do
        if sess.winners[w] == e.name then isW = true break end
      end
      table.insert(out.lines, "    " .. RollLine(e, isW))
    end
    for t = 1, Z.Util.ArrayCount(sess.trades or {}) do
      local tr = sess.trades[t]
      table.insert(out.lines, "    |cff00FFFF" .. tostring(tr.from) .. " traded to " .. tostring(tr.to) .. " (transmog)|r")
    end
  end
  return out
end

function M.ShowItemLog(itemID)
  M.itemLogItem = itemID
  if not CreateFrame then return end -- headless: data via ItemLogLines
  if M.itemLogFrame then
    if M.itemLogFrame.Hide then M.itemLogFrame:Hide() end
    M.itemLogFrame = nil
  end
  local sheet = Z.DB and Z.DB.sheet
  local data = M.ItemLogLines(itemID)
  local f = CreateFrame("Frame", "ZugLootItemLog", UIParent)
  if type(f) ~= "table" or type(f.SetWidth) ~= "function"
      or type(f.CreateFontString) ~= "function" then
    return -- minimal stubs: data layer already built above
  end
  f:SetWidth(420) f:SetHeight(300)
  f:SetPoint("CENTER", UIParent, "CENTER", 120, 60)
  f:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  f:SetBackdropColor(0, 0, 0, 0.95)
  f:SetMovable(true) f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() f:StartMoving() end)
  f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
  f:SetClampedToScreen(true)
  -- Above the main window: same strata but a higher level, so the log
  -- never slides under it (nil-safe on mock frames).
  if f.SetFrameStrata then pcall(f.SetFrameStrata, f, "DIALOG") end
  if f.SetFrameLevel then
    local lvl = 10
    if M.frame and M.frame.GetFrameLevel then
      local ok, ml = pcall(M.frame.GetFrameLevel, M.frame)
      if ok and tonumber(ml) then lvl = tonumber(ml) + 10 end
    end
    pcall(f.SetFrameLevel, f, lvl)
  end
  -- Pretty header: loot icon (quality border) + item name + drop count.
  local icon = ItemIcon(f, itemID, 40)
  icon:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
  local nS = 0
  if sheet and Z.ItemCards then
    local cards = Z.ItemCards.BuildCards(sheet)
    for i = 1, Z.Util.ArrayCount(cards) do
      if cards[i].itemID == itemID then nS = Z.Util.ArrayCount(cards[i].rollSessions) break end
    end
  end
  local title = FS(f, "GameFontNormalLarge", data.header.name)
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 60, -14)
  title:SetWidth(340) title:SetJustifyH("LEFT")
  local sub = FS(f, "GameFontHighlightSmall",
    nS > 0 and ("dropped x" .. nS .. " this raid") or "not dropped yet this raid")
  sub:SetPoint("TOPLEFT", f, "TOPLEFT", 60, -34)
  sub:SetWidth(340) sub:SetJustifyH("LEFT")
  sub:SetTextColor(PAL.mute[1], PAL.mute[2], PAL.mute[3])
  local xb = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  xb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
  xb:SetScript("OnClick", function() f:Hide() end)
  -- Session lines, newest first.
  local body = FS(f, "GameFontHighlightSmall", table.concat(data.lines, "\n"))
  body:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -64)
  body:SetWidth(396) body:SetJustifyH("LEFT") body:SetJustifyV("TOP")
  local n = Z.Util.ArrayCount(data.lines)
  f:SetHeight(math.max(140, 110 + n * 13))
  if f.Show then f:Show() end
  M.itemLogFrame = f
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
  M.zlGridCells = {} -- placement record for the role-icon assert
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
    -- Role icon left (bow = ranged, sword = melee, book = healer),
    -- from the sheet/live class (spec-aware). Unknown: no icon.
    local roleTex = nil
    if Z.ClassColors and Z.ClassColors.RawClassOf and Z.ClassColors.RoleIcon then
      local raw = Z.ClassColors.RawClassOf(nm)
      roleTex = raw and Z.ClassColors.RoleIcon(raw) or nil
    end
    local nameX = 0
    if roleTex and cell.CreateTexture then
      local ric = cell:CreateTexture(nil, "ARTWORK")
      if ric.SetTexture then ric:SetTexture(roleTex) end
      if ric.SetWidth then ric:SetWidth(14) ric:SetHeight(14) end
      if ric.SetPoint then ric:SetPoint("LEFT", cell, "LEFT", 3, 0) end
      if ric.Show then ric:Show() end
      cell.zlRoleIcon = roleTex -- placement record for the layout assert
      nameX = 9
    end
    -- Full name in the member's class color, outlined for contrast
    -- against the status fill (1.12 FontString outline primitive).
    local label = nm
    if Z.ClassColors and Z.ClassColors.ClassColorHex and Z.ClassColors.ClassOf then
      label = "|c" .. Z.ClassColors.ClassColorHex(Z.ClassColors.ClassOf(nm)) .. nm .. "|r"
    end
    local fs = FS(cell, "GameFontNormal", label)
    fs:SetPoint("CENTER", cell, "CENTER", nameX, 0)
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
    -- Spec line: human-readable spec only (name color already says the
    -- class). Missing spec = no line, not a placeholder.
    local tipSpec = nil
    if Z.ClassColors and Z.ClassColors.RawClassOf and Z.ClassColors.SpecName then
      local rawSpec = Z.ClassColors.RawClassOf(nm)
      tipSpec = rawSpec and Z.ClassColors.SpecName(rawSpec) or nil
    end
    local tipWhat = col == "GREEN" and "In group, SR ready"
      or col == "AMBER" and "In group, SR ready — outdated addon, update"
      or col == "GREY" and "Not in group, SR ready"
      or "In group, SR not ready"
    Tip(cell, PName(nm), tipSpec or tipSub, tipSpec and (tipSub .. "  " .. tipWhat) or tipWhat)
    cell.zlTipSpec = tipSpec -- placement record for the spec assert
    table.insert(M.zlGridCells, { name = nm, roleIcon = cell.zlRoleIcon, spec = cell.zlTipSpec })
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

-- Test hook: roller-column split of one card ({ left, right } line
-- counts). Recorded at build time (mock frames track no children).
function M.DebugCardColumns(itemID)
  local t = M.zlCardCols or {}
  return t[itemID]
end

-- Test hook: whether a card carries the player's own SR (gold badge).
function M.DebugCardMine(itemID)
  local t = M.zlCardMine or {}
  return t[itemID]
end

-- Test hook: a card's shift-click link (must be a full color link, never
-- a bare "item:NNNN" id). Recorded at icon build time.
function M.DebugCardLink(itemID)
  local t = M.zlCardLinks or {}
  return t[itemID]
end

-- Test hook: the sheet icon buttons (for the ctrl-click try-on assert).
-- Icons record themselves at build time (mock frames track no children).
function M.DebugCardIcons()
  return M.zlCardIcons
end

-- Test hook: drop-count corner number per card (#N sessions).
function M.DebugCardDrops(itemID)
  local t = M.zlCardDrops or {}
  return t[itemID]
end

-- Test hook: member-grid cells of the last versions render
-- ({ {name, roleIcon}... }). Recorded at build time (mock frames
-- track no children).
function M.DebugGridCells()
  return M.zlGridCells
end

-- Test hook: tracked visual rows of a tab body for the sheet column
-- layout assert ({ { h, cells = { {x, w}... } }... }). Card cells record
-- their placement at build time (mock frames track no children).
function M.DebugBodyRows(tabKey)
  local bd = bodies[tabKey]
  if not bd then return nil end
  local out = {}
  for i = 1, Z.Util.ArrayCount(bd.rows or {}) do
    local rowF = bd.rows[i]
    table.insert(out, { h = rowF.rowH, cells = rowF.zlCells })
  end
  return out
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
    "Anyone may import (local view); broadcast stays ML / raid leader.")
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
  -- footer (no Close button: X sits top-right next to the other X).
  hairline(f, -(winH - 30), 14, -14)
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
