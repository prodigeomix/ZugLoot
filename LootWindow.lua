-- ZugLoot/LootWindow.lua
-- RollFor-LootFrame-style (modern skin) loot list for the master looter:
-- a numbered list; each row shows the item icon, the item name
-- (quality-colored), and the SR/HR badge on the right. Clicking a row opens
-- the row detail: direct Award when there is exactly one SR/HR holder,
-- "..." (More) for the full choice list (award anyone / initiate roll),
-- Close to dismiss the detail and keep working the overview.
--
-- Data layer (M.items, M.detail) is plain tables so tests drive it
-- headless; frames are client-only (nil-guarded, mock-safe).
-- Item: { itemID, link, texture, quality, quantity, slot, badge, status,
--         source, index }
--   badge: "HR" | "SR" | "SR:n" | ""; status: "open"|"rolling"|"done";
--   source: "loot"|"sim"; index: 1-based row number (RollFor modern skin).
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.LootWindow = M

M.items = {}
M.title = "ZugLoot Loot"
M.frame = nil
M.rows = {}

-- Row detail state (plain data): { itemID, link, badge, rollers={names},
-- single=bool (exactly one SR/HR holder), status, source }.
M.detail = nil
M.detailFrame = nil

M.ROW_HEIGHT = 24
M.ICON_SIZE = 20
-- Wide enough for "Award <name>" on ONE line (RollFor sizes rows to the
-- widest content). 320 fits ~35-char names next to the ... / Close buttons.
M.DETAIL_WIDTH = 320

function M.Clear()
  M.items = {}
  M.detail = nil
  M.Refresh()
  M.RefreshDetail()
end

-- Replace the list (loot scan / sim queue). Plain array of
-- { itemID, link, texture, quality, quantity, slot, badge, sr }; status
-- starts "open", index follows list order (RollFor modern skin numbering).
-- badge wins over sr; sr feeds the legacy badge derivation.
function M.SetItems(list, source)
  M.items = {}
  local n = Z.Util.ArrayCount(list or {})
  for i = 1, n do
    local e = (list or {})[i]
    if e and e.itemID then
      local badge = e.badge
      if (badge == nil or badge == "") and e.sr and e.sr > 0 then
        badge = (e.sr == 1) and "SR" or ("SR:" .. e.sr)
      end
      local row = {
        index = i,
        itemID = e.itemID,
        link = e.link or ("item:" .. tostring(e.itemID)),
        name = e.name,
        texture = e.texture,
        quality = e.quality or 0,
        quantity = e.quantity,
        slot = e.slot,
        badge = badge or "",
        status = "open",
        source = source or "loot",
      }
      M.EnsureResolved(row) -- sheet-style name/icon/link, not "item:<id>"
      table.insert(M.items, row)
    end
  end
  M.Refresh()
end

function M.Find(itemID)
  for i = 1, Z.Util.ArrayCount(M.items) do
    if M.items[i].itemID == itemID then return M.items[i] end
  end
  return nil
end

function M.SetStatus(itemID, status)
  local it = M.Find(itemID)
  if it then it.status = status end
  M.Refresh()
end

function M.MarkRolling(itemID) M.SetStatus(itemID, "rolling") end
function M.MarkDone(itemID) M.SetStatus(itemID, "done") end
function M.MarkOpen(itemID) M.SetStatus(itemID, "open") end

function M.AllDone()
  for i = 1, Z.Util.ArrayCount(M.items) do
    if M.items[i].status ~= "done" then return false end
  end
  return true
end

function M.Hide()
  if M.frame and M.frame.Hide then M.frame:Hide() end
  M.CloseDetail()
end

function M.Show(title)
  if title then M.title = title end
  if not CreateFrame then return end
  if not M.frame then M.BuildFrame() end
  if not M.frame then return end
  M.Refresh()
  if M.frame then M.frame:Show() end
end

function M.BuildFrame()
  if M.frame then return M.frame end
  if not CreateFrame then return nil end
  local f = CreateFrame("Frame", "ZugLootLootFrame", UIParent)
  if type(f) ~= "table" or type(f.SetWidth) ~= "function"
      or type(f.CreateFontString) ~= "function" then
    return nil -- no usable client frame (minimal test stubs)
  end
  f:SetWidth(340) f:SetHeight(120)
  f:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
  f:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  f:SetBackdropColor(0, 0, 0, 0.9)
  f:SetMovable(true) f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() f:StartMoving() end)
  f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
  f:SetClampedToScreen(true)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", f, "TOP", 0, -10)
  title:SetText(M.title)
  f.title = title
  local closeB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  closeB:SetWidth(70) closeB:SetHeight(20)
  closeB:SetPoint("BOTTOM", f, "BOTTOM", 0, 8)
  closeB:SetText("Close")
  closeB:SetScript("OnClick", function() f:Hide() end)
  M.frame = f
  return f
end

-- Row display line (headless/text): "1. [link] SR" (+status tag).
-- Mirrors what the client row paints: number, name, right-side badge.
function M.RowText(it)
  local s = tostring(it.index) .. ". " .. M.DisplayName(it)
  if it.badge and it.badge ~= "" then s = s .. " " .. it.badge end
  if it.status == "rolling" then s = s .. " [rolling]"
  elseif it.status == "done" then s = s .. " [done]" end
  return s
end

-- Item presentation (RollFor ItemUtils parity):
-- DisplayName: the readable name — never the raw link. Prefers the slot
-- name captured at scan time, else parses "[Name]" out of the link, else
-- the itemID fallback.
-- TooltipLink: the "item:...." part for SetHyperlink.
function M.DisplayName(it)
  if it.name and it.name ~= "" then return tostring(it.name) end
  local link = tostring(it.link or "")
  local nm = string.match(link, "%[(.-)%]")
  if nm and nm ~= "" then return nm end
  return "item:" .. tostring(it.itemID)
end

function M.TooltipLink(it)
  local link = tostring(it.link or "")
  local inner = string.match(link, "|H(item:[^|]+)|h")
  if inner then return inner end
  local id = tonumber(it.itemID)
  if id then return "item:" .. id .. ":0:0:0" end
  return link ~= "" and link or nil
end

-- Shared item resolution: the sheet list reads name, full link, quality
-- and texture from GetItemInfo(tonumber(itemID)) — the loot list does the
-- same here. Slot/scan data is only a fallback; without it a row degrades
-- to "item:<id>" with a blank icon (the reported bug: sim rows carry bare
-- "1001" links that can never yield a name or texture on their own).
-- Missing client cache (GetItemInfo -> nil) keeps the fallbacks.
function M.ResolveItemInfo(itemID, link, quality, texture, name)
  local rName, rLink, rQ, rTex = name, link, quality, texture
  if GetItemInfo then
    -- 1.12 takes the item LINK (the sheet's per-id call only works for
    -- cache-warm keys). Try the row link first, then the numeric id.
    if link and link ~= "" then
      local ok, n, l, q, _, _, _, _, _, t = pcall(GetItemInfo, link)
      if ok then
        if n and n ~= "" then rName = n end
        if l and l ~= "" then rLink = l end
        if q ~= nil then rQ = q end
        if t and t ~= "" then rTex = t end
      end
    end
    local id = tonumber(itemID)
    if id and (rName == nil or rName == "" or rTex == nil or rTex == "") then
      local ok, n, l, q, _, _, _, _, _, t = pcall(GetItemInfo, id)
      if ok then
        if n and n ~= "" and (rName == nil or rName == "") then rName = n end
        if l and l ~= "" and (rLink == nil or rLink == "" or not string.find(tostring(rLink), "|Hitem:", 1, true)) then rLink = l end
        if q ~= nil and (rQ == nil or rQ == 0) then rQ = q end
        if t and t ~= "" and (rTex == nil or rTex == "") then rTex = t end
      end
    end
  end
  if (rName == nil or rName == "") and rLink then
    local nm = string.match(tostring(rLink), "%[(.-)%]")
    if nm and nm ~= "" then rName = nm end
  end
  return rName, rLink, rQ, rTex
end

-- Fill a row in place (name/link/quality/texture); marks it resolved so
-- later Refresh calls skip the lookup. Safe headless (no GetItemInfo).
function M.EnsureResolved(it)
  if not it or it._resolved then return it end
  local name, link, q, tex = M.ResolveItemInfo(it.itemID, it.link,
    it.quality, it.texture, it.name)
  it.name = name
  if link and link ~= "" then it.link = link end
  if q ~= nil then it.quality = q end
  if tex and tex ~= "" then it.texture = tex end
  it._resolved = true
  return it
end

-- Shared tooltip show/hide (RollFor row OnEnter parity). Guarded for the
-- mock frame API (pcall: the mock's SetOwner is a noop).
function M.ShowTip(owner, tipLink)
  if not tipLink then return end
  if GameTooltip and GameTooltip.SetOwner and GameTooltip.SetHyperlink then
    local ok = pcall(GameTooltip.SetOwner, GameTooltip, owner, "ANCHOR_RIGHT")
    if ok then
      pcall(GameTooltip.SetHyperlink, GameTooltip, tipLink)
      if GameTooltip.Show then GameTooltip:Show() end
    end
  end
end

function M.HideTip()
  if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end
end

-- Quality color helper: client GetItemQualityColor when present, else the
-- Z.Colors hex fallback (keeps headless RowText deterministic).
function M.QualityHex(q)
  if GetItemQualityColor then
    local r, g, b = GetItemQualityColor(q or 0)
    if r then
      return string.format("|cFF%02X%02X%02X",
        math.floor((r or 1) * 255), math.floor((g or 1) * 255), math.floor((b or 1) * 255))
    end
  end
  return "|cFFFFFFFF"
end

function M.Refresh()
  if not M.frame then return end
  if type(M.frame.CreateFontString) ~= "function" then return end
  if M.frame.title and M.frame.title.SetText then
    local open = 0
    for i = 1, Z.Util.ArrayCount(M.items) do
      if M.items[i].status == "open" then open = open + 1 end
    end
    M.frame.title:SetText(M.title .. " (" .. open .. " open)")
  end
  -- Rebuild rows (cheap for a handful of drops).
  for i = 1, Z.Util.ArrayCount(M.rows) do
    if M.rows[i].Hide then M.rows[i]:Hide() end
  end
  M.rows = {}
  if type(CreateFrame) ~= "function" then return end
  local y = -34
  for i = 1, Z.Util.ArrayCount(M.items) do
    local it = M.EnsureResolved(M.items[i])
    local id = it.itemID -- lua 5.0: fresh local per iteration for the closure
    local row = CreateFrame("Button", nil, M.frame)
    if type(row) ~= "table" or type(row.SetWidth) ~= "function"
        or type(row.CreateFontString) ~= "function" then
      M.rows = {} -- minimal-frame stubs: data layer already updated above
      return
    end
    row:SetWidth(310) row:SetHeight(M.ROW_HEIGHT)
    row:SetPoint("TOPLEFT", M.frame, "TOPLEFT", 10, y)
    -- Selection tint in the item's quality color (RollFor modern skin).
    if row.SetBackdrop and it.status == "open" then
      row:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8x8" })
      if row.SetBackdropColor then row:SetBackdropColor(0, 0, 0, 0.1) end
    end
    if it.status ~= "open" and row.SetAlpha then
      row:SetAlpha(0.6) -- rolling/done rows dim, like RollFor disabled rows
    end
    -- 1) row number.
    local idx = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    idx:SetPoint("LEFT", row, "LEFT", 2, 0)
    idx:SetWidth(16) idx:SetJustifyH("CENTER")
    idx:SetText(tostring(it.index))
    -- 2) item icon.
    local icon
    if row.CreateTexture then
      icon = row:CreateTexture(nil, "ARTWORK")
      icon:SetWidth(M.ICON_SIZE) icon:SetHeight(M.ICON_SIZE)
      icon:SetPoint("LEFT", idx, "RIGHT", 2, 0)
      if icon.SetTexture then
        icon:SetTexture(it.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
      end
    end
    -- 3) item name (readable name, quality-colored — never the raw link).
    local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if icon then name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    else name:SetPoint("LEFT", idx, "RIGHT", 4, 0) end
    name:SetWidth(196) name:SetJustifyH("LEFT")
    local label = M.DisplayName(it)
    if it.quantity and it.quantity > 1 then label = label .. " x" .. it.quantity end
    if it.status == "rolling" then label = label .. " [rolling]"
    elseif it.status == "done" then label = label .. " [done]" end
    if name.SetText then
      name:SetText(M.QualityHex(it.quality) .. label .. "|r")
    end
    it._tipLink = M.TooltipLink(it) -- stash for the hover closures below
    -- 4) SR/HR badge on the right.
    if it.badge and it.badge ~= "" then
      local badge = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      badge:SetPoint("RIGHT", row, "RIGHT", -6, 0)
      if badge.SetText then badge:SetText(it.badge) end
      if badge.SetTextColor then
        if it.badge == "HR" then badge:SetTextColor(1, 0.2, 0.2)
        else badge:SetTextColor(1, 0.65, 0.1) end -- SR orange, like RollFor
      end
      -- Make room for the badge: shrink the name field (SetPoint RIGHT
      -- needs anchor plumbing the mock stubs lack; width is enough).
      if name.SetWidth then name:SetWidth(150) end
    end
    -- Whole row clicks through to the detail (RollFor: row click selects).
    if row.SetScript then
      row:SetScript("OnClick", function() M.OpenDetail(id) end)
      -- Hover: item tooltip via the stashed link (never the raw scan link).
      row:SetScript("OnEnter", function()
        M.ShowTip(row, it._tipLink)
      end)
      row:SetScript("OnLeave", function()
        M.HideTip()
      end)
    end
    -- Icon shift/ctrl modifiers: link in chat / dress-up (RollFor parity).
    if icon and icon.SetScript then
      icon:SetScript("OnEnter", function()
        M.ShowTip(icon, it._tipLink)
      end)
      icon:SetScript("OnLeave", function()
        M.HideTip()
      end)
    end
    table.insert(M.rows, row)
    y = y - (M.ROW_HEIGHT + 2)
  end
  if M.frame.SetHeight then
    M.frame:SetHeight(math.max(70, 44 - y))
  end
end

-- -- Row detail (RollFor preview equivalent) --
--
-- Clicking a row opens a small window for that item:
--   Award        — direct award, only when exactly one SR/HR holder exists
--                  (labels them, like RollFor's single-winner shortcut).
--   ... (More)   — full choice list: award anyone / initiate roll.
--   Close        — dismiss, keep working the overview.
-- Headless it prints the same rows; the ML answers via doAction(...).

-- Build the detail data for an item (pure, headless-testable).
function M.BuildDetail(itemID)
  local it = M.EnsureResolved(M.Find(itemID))
  if not it then return nil end
  local sheet = Z.DB and Z.DB.sheet
  local rollers = {}
  if sheet and Z.SRData and Z.SRData.SRNames then
    rollers = Z.SRData.SRNames(sheet, itemID)
  end
  return {
    itemID = itemID,
    link = it.link,
    name = M.DisplayName(it),
    tipLink = M.TooltipLink(it),
    badge = it.badge or "",
    status = it.status,
    source = it.source,
    rollers = rollers,
    single = Z.Util.ArrayCount(rollers) == 1,
  }
end

function M.OpenDetail(itemID)
  local d = M.BuildDetail(itemID)
  if not d then return nil end
  M.detail = d
  M.RefreshDetail()
  return d
end

function M.CloseDetail()
  M.CloseMoreDropdown()
  M.detail = nil
  if M.detailFrame and M.detailFrame.Hide then M.detailFrame:Hide() end
  M.detailFrame = nil
end

-- Detail display lines (headless/text): title, roller list, actions.
function M.DetailLines(d)
  d = d or M.detail
  local lines = {}
  if not d then return lines end
  local head = tostring(d.name or d.link or ("item:" .. d.itemID))
  if d.badge and d.badge ~= "" then head = head .. " [" .. d.badge .. "]" end
  table.insert(lines, head)
  if Z.Util.ArrayCount(d.rollers) > 0 then
    table.insert(lines, "  reserved by: " .. table.concat(d.rollers, ", "))
  else
    table.insert(lines, "  no reserves — open roll")
  end
  local actions = M.DetailActions(d)
  local names = {}
  for i = 1, Z.Util.ArrayCount(actions) do table.insert(names, actions[i].label) end
  table.insert(lines, "  actions: " .. table.concat(names, " | "))
  return lines
end

-- Detail actions (data): Award (single holder only), ... (More), Close.
function M.DetailActions(d)
  d = d or M.detail
  local actions = {}
  if not d then return actions end
  if d.single then
    table.insert(actions, { id = "award", label = "Award " .. d.rollers[1] })
  end
  table.insert(actions, { id = "more", label = "..." })
  table.insert(actions, { id = "close", label = "Close" })
  return actions
end

-- Headless/text action entry: AwardChosen for award, MoreLines for ...,
-- CloseDetail for close. Returns a string (what happened) for tests.
function M.doAction(itemID, actionID, extra)
  local d = M.detail
  if not d or d.itemID ~= itemID then
    d = M.OpenDetail(itemID)
  end
  if not d then return "unknown item" end
  if actionID == "close" then
    M.CloseDetail()
    return "closed"
  end
  if actionID == "award" then
    if not d.single then return "needs choice (...)" end
    if Z.MasterLootUI and Z.MasterLootUI.AwardDirect then
      Z.MasterLootUI.AwardDirect(d.itemID, d.rollers[1], d.source)
    end
    M.CloseDetail()
    return "awarded " .. d.rollers[1]
  end
  if actionID == "more" then
    return M.MoreLines(d)
  end
  if actionID == "roll" then
    -- Initiate the roll from the detail (RollFor: roll button in preview).
    if d.source == "sim" then
      if Z.Sim and Z.Sim.RequestRoll then Z.Sim.RequestRoll(d.itemID) end
    else
      if Z.MasterLootUI and Z.MasterLootUI.StartItemRoll then
        Z.MasterLootUI.StartItemRoll(d.itemID)
      end
    end
    M.CloseDetail()
    return "rolling"
  end
  if actionID == "award-name" then
    -- Award a named raider from the More list (candidate award).
    if Z.MasterLootUI and Z.MasterLootUI.AwardDirect then
      Z.MasterLootUI.AwardDirect(d.itemID, extra, d.source)
    end
    M.CloseDetail()
    return "awarded " .. tostring(extra)
  end
  return "unknown action"
end

-- The "..." (More) list: every awardable name + roll initiation.
-- Returns lines (headless) and stores them for the client frame.
function M.MoreLines(d)
  d = d or M.detail
  local lines = {}
  if not d then return lines end
  table.insert(lines, "Award " .. tostring(d.name or d.link or ("item:" .. d.itemID)) .. " to?")
  if Z.Util.ArrayCount(d.rollers) > 0 then
    for i = 1, Z.Util.ArrayCount(d.rollers) do
      table.insert(lines, "  SR: " .. d.rollers[i])
    end
  end
  table.insert(lines, "  Roll: start a roll for this item")
  table.insert(lines, "  Anyone: /zl award <name> after the roll, or award now")
  return lines
end

function M.RefreshDetail()
  local d = M.detail
  if not d then
    if M.detailFrame and M.detailFrame.Hide then M.detailFrame:Hide() end
    return
  end
  if not CreateFrame then return end -- headless: data only
  if not M.detailFrame then M.BuildDetailFrame() end
  if not M.detailFrame then return end
  M.PaintDetailFrame()
  M.detailFrame:Show()
end

function M.BuildDetailFrame()
  if M.detailFrame then return M.detailFrame end
  if not CreateFrame then return nil end
  local parent = M.frame or UIParent
  local f = CreateFrame("Frame", "ZugLootLootDetailFrame", parent)
  if type(f) ~= "table" or type(f.SetWidth) ~= "function"
      or type(f.CreateFontString) ~= "function" then
    return nil
  end
  f:SetWidth(M.DETAIL_WIDTH) f:SetHeight(120)
  f:SetPoint("CENTER", parent, "CENTER", 200, 40)
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
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", f, "TOP", 0, -10)
  title:SetWidth(240) title:SetJustifyH("CENTER")
  f.title = title
  local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  sub:SetPoint("TOP", title, "BOTTOM", 0, -4)
  sub:SetWidth(240) sub:SetJustifyH("CENTER")
  f.sub = sub
  -- Award (only meaningful with a single holder; hidden otherwise).
  local awardB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  awardB:SetWidth(120) awardB:SetHeight(22)
  awardB:SetPoint("TOP", sub, "BOTTOM", 0, -8)
  awardB:SetText("Award")
  awardB:SetScript("OnClick", function()
    if M.detail then M.doAction(M.detail.itemID, "award") end
  end)
  f.awardB = awardB
  -- "..." More: a real dropdown (RollFor GuiElements.dropdown parity) —
  -- award anyone on the list, or initiate the roll. Anchored under the
  -- detail like RollFor's candidate frame under the rolling popup.
  local moreB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  moreB:SetWidth(60) moreB:SetHeight(22)
  moreB:SetPoint("TOP", awardB, "BOTTOM", 0, -6)
  moreB:SetText("...")
  moreB:SetScript("OnClick", function()
    if M.detail then M.ToggleMoreDropdown(moreB) end
  end)
  f.moreB = moreB
  -- Close: dismiss, keep the overview.
  local closeB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  closeB:SetWidth(60) closeB:SetHeight(22)
  closeB:SetPoint("LEFT", moreB, "RIGHT", 8, 0)
  closeB:SetText("Close")
  closeB:SetScript("OnClick", function() M.CloseDetail() end)
  M.detailFrame = f
  return f
end

function M.PaintDetailFrame()
  local f, d = M.detailFrame, M.detail
  if not f or not d then return end
  if f.title and f.title.SetText then
    local head = tostring(d.name or d.link or ("item:" .. d.itemID))
    if d.badge and d.badge ~= "" then head = head .. " [" .. d.badge .. "]" end
    f.title:SetText(head)
  end
  if f.title and f.title.SetScript then
    f.title:SetScript("OnEnter", function() M.ShowTip(f.title, d.tipLink) end)
    f.title:SetScript("OnLeave", function() M.HideTip() end)
  end
  if f.sub and f.sub.SetText then
    if Z.Util.ArrayCount(d.rollers) > 0 then
      f.sub:SetText("Reserved by: " .. table.concat(d.rollers, ", "))
    else
      f.sub:SetText("No reserves — open roll")
    end
  end
  if f.awardB then
    if d.single then
      if f.awardB.Show then f.awardB:Show() end
      if f.awardB.SetText then f.awardB:SetText("Award " .. d.rollers[1]) end
      if f.awardB.Enable then f.awardB:Enable() end
    else
      if f.awardB.Hide then f.awardB:Hide() end -- multi/no holder: use ...
    end
  end
end

-- "..." from the client frame: a dropdown menu (RollFor dropdown parity)
-- with one row per choice: award anyone on the list, or initiate the roll.
-- Rows highlight blue on hover; picking one runs it and closes the detail.
-- Headless (tests, /zl text UIs) it falls back to printing MoreLines.
M.moreDropdown = nil

-- Dropdown choice rows for the detail (data, headless-testable):
-- { { id="roll", label="Roll" }, { id="award-name", label="Award <name>" } }
function M.MoreChoices(d)
  d = d or M.detail
  local out = {}
  if not d then return out end
  if d.status == "open" then
    table.insert(out, { id = "roll", label = "Roll" })
  end
  for i = 1, Z.Util.ArrayCount(d.rollers or {}) do
    table.insert(out, { id = "award-name", label = "Award " .. d.rollers[i],
      name = d.rollers[i] })
  end
  return out
end

function M.ToggleMoreDropdown(anchor)
  local d = M.detail
  if not d then return end
  -- Headless: print the choice list (MoreLines parity).
  if not CreateFrame then
    for i = 1, Z.Util.ArrayCount(M.MoreLines(d)) do Z.Print(M.MoreLines(d)[i]) end
    return
  end
  if M.moreDropdown then
    if M.moreDropdown.Hide then M.moreDropdown:Hide() end
    M.moreDropdown = nil
    return -- was open: toggle shut
  end
  local choices = M.MoreChoices(d)
  if Z.Util.ArrayCount(choices) == 0 then return end
  local parent = M.detailFrame or M.frame or UIParent
  local dd = CreateFrame("Frame", "ZugLootLootMoreDropdown", parent)
  if type(dd) ~= "table" or type(dd.SetWidth) ~= "function" then return end
  if dd.SetFrameStrata then pcall(dd.SetFrameStrata, dd, "TOOLTIP") end
  if dd.SetBackdrop then
    dd:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8x8",
      edgeFile = "Interface/Buttons/WHITE8x8", edgeSize = 0.5 })
  end
  if dd.SetBackdropColor then dd:SetBackdropColor(0, 0, 0, 1) end
  if dd.SetBackdropBorderColor then dd:SetBackdropBorderColor(0.2, 0.2, 0.2, 1) end
  if dd.EnableMouse then dd:EnableMouse(true) end
  -- Hide when the mouse leaves the menu (RollFor dropdown parity).
  if dd.SetScript and MouseIsOver then
    dd:SetScript("OnLeave", function()
      if not MouseIsOver(dd) then M.CloseMoreDropdown() end
    end)
  end
  -- One button per choice; width fits the longest label.
  local width, y = 0, -4
  dd.rows = {}
  for i = 1, Z.Util.ArrayCount(choices) do
    local c = choices[i] -- fresh local per iteration for the closure
    local b = CreateFrame("Button", nil, dd)
    if type(b) ~= "table" or type(b.SetWidth) ~= "function" then break end
    b:SetHeight(16)
    b:SetPoint("TOPLEFT", dd, "TOPLEFT", 5, y)
    b:SetPoint("RIGHT", dd, "RIGHT", -5, 0)
    if b.SetBackdrop then b:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8x8" }) end
    local function hover(a)
      if b.SetBackdropColor then b:SetBackdropColor(0.125, 0.624, 0.976, a) end
    end
    hover(0)
    if b.SetScript then
      b:SetScript("OnEnter", function() hover(0.2) end)
      b:SetScript("OnLeave", function() hover(0) end)
      b:SetScript("OnClick", function()
        M.CloseMoreDropdown()
        if M.detail then
          if c.id == "roll" then M.doAction(M.detail.itemID, "roll")
          elseif c.id == "award-name" then M.doAction(M.detail.itemID, "award-name", c.name) end
        end
      end)
    end
    local fs
    if b.CreateFontString then
      fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      fs:SetPoint("LEFT", b, "LEFT", 5, 0)
      if fs.SetText then fs:SetText(c.label) end
      local w = 0
      if fs.GetStringWidth then w = fs:GetStringWidth() or 0 end
      if w == 0 then w = string.len(c.label) * 7 end
      if w > width then width = w end
    end
    table.insert(dd.rows, b)
    y = y - 18
  end
  dd:SetWidth(width + 20)
  dd:SetHeight(-y + 5)
  if dd.ClearAllPoints then dd:ClearAllPoints() end
  if anchor and dd.SetPoint then
    -- Under the ... button, like RollFor's candidate frame under the popup.
    dd:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
  elseif dd.SetPoint and M.detailFrame then
    dd:SetPoint("TOP", M.detailFrame, "BOTTOM", 0, -2)
  end
  if dd.Show then dd:Show() end
  M.moreDropdown = dd
end

function M.CloseMoreDropdown()
  if M.moreDropdown then
    if M.moreDropdown.Hide then M.moreDropdown:Hide() end
    M.moreDropdown = nil
  end
end

-- "..." headless/text entry (kept for /zl text UIs): prints the choice list.
function M.MoreAction()
  local d = M.detail
  if not d then return end
  local lines = M.MoreLines(d)
  for i = 1, Z.Util.ArrayCount(lines) do Z.Print(lines[i]) end
  if Z.MasterLootUI and d.status == "open" then
    Z.Print("Roll it: /zl roll " .. tostring(d.itemID))
  end
end
