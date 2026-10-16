-- ZugLoot/Minimap.lua
-- Minimap button (ZL badge image): left-click toggles the main window, hover
-- shows a status tooltip (raid, sheet state, role). Draggable around the
-- minimap edge (position persisted per character). In-game only; pure
-- position math is headless-testable (M.AnglePos).
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.Minimap = M

M.BADGE_IMAGE = "Interface\\AddOns\\ZugLoot\\Media\\ZL-Badge.tga"
M.BADGE_SIZE = 32 -- prerendered badge (feathered disc + Griffy gold ZL
-- + halo, ink centered by measured bbox in Media/); single texture,
-- no FontStrings — immune to client font/anchor drift
M.BTN_SIZE = 32
M.RADIUS = 80

-- Pure: button center for a minimap angle (degrees, 0 = top, clockwise).
-- Returns x, y offsets from the minimap center. Headless-testable.
function M.AnglePos(angleDeg, radius)
  local a = math.rad(tonumber(angleDeg) or 0)
  local r = tonumber(radius) or M.RADIUS
  return math.sin(a) * r, math.cos(a) * r
end

function M.GetAngle()
  if Z.CharDB and tonumber(Z.CharDB.minimapAngle) then
    return tonumber(Z.CharDB.minimapAngle)
  end
  return 200 -- default: lower-left, out of the way of tracking icons
end

function M.SetAngle(a)
  if Z.CharDB then Z.CharDB.minimapAngle = tonumber(a) or M.GetAngle() end
end

function M.Place(btn, angleDeg)
  if not (btn and btn.SetPoint and Minimap) then return end
  local x, y = M.AnglePos(angleDeg or M.GetAngle(), M.RADIUS)
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Tooltip lines (pure, headless-testable): title + raid/sheet/role state.
function M.TipLines()
  local lines = { "ZugLoot v" .. tostring(Z.VERSION or "?") }
  local sheet = Z.DB and Z.DB.sheet
  local meta = sheet and sheet.meta
  if meta and meta.raidName and meta.raidName ~= "" then
    table.insert(lines, tostring(meta.raidName))
  elseif meta and meta.raidID then
    table.insert(lines, "ID " .. tostring(meta.raidID))
  else
    table.insert(lines, "no sheet")
  end
  local role = Z.SRSecurity and Z.SRSecurity.RoleLabel
    and Z.SRSecurity.RoleLabel() or ""
  if role ~= "" then table.insert(lines, role) end
  table.insert(lines, "Click: open/close  •  Drag: move")
  return lines
end

M.button = nil
M.dragging = false

function M.ShowTip(btn)
  if not (GameTooltip and GameTooltip.SetOwner) then return end
  local ok = pcall(GameTooltip.SetOwner, GameTooltip, btn, "ANCHOR_LEFT")
  if not ok then return end
  local lines = M.TipLines()
  if GameTooltip.SetText and lines[1] then
    GameTooltip:SetText(lines[1], 1, 0.82, 0)
  end
  if GameTooltip.AddLine then
    -- 5.0-safe: no # operator (parse-time error on the 1.12 client).
    local n = 0
    if Z.Util and Z.Util.ArrayCount then n = Z.Util.ArrayCount(lines) end
    for i = 2, n do
      GameTooltip:AddLine(lines[i], 1, 1, 1, 1)
    end
  end
  if GameTooltip.Show then GameTooltip:Show() end
end

function M.Build()
  if M.button then return M.button end
  if not CreateFrame then return nil end
  local b = CreateFrame("Button", "ZugLootMinimapButton", Minimap)
  if type(b) ~= "table" or type(b.SetWidth) ~= "function"
      or type(b.CreateTexture) ~= "function" then
    return nil -- minimal stubs: data layer (AnglePos/TipLines) still works
  end
  b:SetWidth(M.BTN_SIZE) b:SetHeight(M.BTN_SIZE)
  b:SetFrameStrata("MEDIUM")
  if b.SetFrameLevel then pcall(b.SetFrameLevel, b, 8) end
  if b.SetHighlightTexture then
    pcall(b.SetHighlightTexture, b, "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  end
  if b.RegisterForClicks then
    pcall(b.RegisterForClicks, b, "LeftButtonUp", "RightButtonUp")
  end
  -- ZL badge: ONE prerendered image (feathered disc + Griffy gold ZL
  -- + halo, Media/ZL-Badge.tga). No FontStrings: the client only
  -- places a texture, so font loading, line-box anchoring, and ring
  -- offsets can never drift the letters again.
  local badge = b:CreateTexture(nil, "BACKGROUND")
  badge:SetWidth(M.BADGE_SIZE) badge:SetHeight(M.BADGE_SIZE)
  badge:SetPoint("CENTER", b, "CENTER", 0, 0)
  if badge.SetTexture then badge:SetTexture(M.BADGE_IMAGE) end
  b.badge = badge
  local ring = b:CreateTexture(nil, "OVERLAY")
  ring:SetWidth(54) ring:SetHeight(54)
  ring:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  if ring.SetTexture then
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  end
  if ring.SetVertexColor then
    -- Gold-tinted ring: ties the border to the letters (white ring +
    -- gold letters would read as two separate marks). Addon gold.
    ring:SetVertexColor(1, 0.82, 0, 1)
  end
  b:EnableMouse(true)
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnEnter", function() M.ShowTip(b) end)
  b:SetScript("OnLeave", function()
    if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end
  end)
  b:SetScript("OnClick", function()
    if Z.MainWindow and Z.MainWindow.Toggle then Z.MainWindow.Toggle() end
  end)
  -- Drag around the edge: angle from cursor, persisted per character.
  b:SetScript("OnDragStart", function() M.dragging = true end)
  b:SetScript("OnDragStop", function()
    M.dragging = false
    M.DragToCursor()
  end)
  b:SetScript("OnUpdate", function()
    if M.dragging then M.DragToCursor() end
  end)
  M.Place(b, M.GetAngle())
  M.button = b
  return b
end

-- Reposition from the cursor while dragging: angle = atan2 of the cursor
-- relative to the minimap center. Nil-safe (no-op without cursor APIs).
function M.DragToCursor()
  local b = M.button
  if not (b and Minimap and Minimap.GetCenter and GetCursorPosition) then return end
  local okC, cx, cy = pcall(Minimap.GetCenter, Minimap)
  if not okC or not cx then return end
  local okP, px, py = pcall(GetCursorPosition)
  if not okP or not px then return end
  -- Cursor is in UI pixels scaled; minimap center too — angle only.
  local dx, dy = px - cx, py - cy
  local angle = math.deg(math.atan2(dx, dy))
  if angle < 0 then angle = angle + 360 end
  M.SetAngle(angle)
  M.Place(b, angle)
end

function M.Show()
  local b = M.button or M.Build()
  if b and b.Show then b:Show() end
end

function M.Hide()
  if M.button and M.button.Hide then M.button:Hide() end
end
