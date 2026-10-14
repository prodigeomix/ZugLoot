-- ZugLoot/LootWindow.lua
-- RollFor-LootFrame-style (modern skin) loot list — universal: whoever
-- opens the corpse runs it (solo, any loot method, ML or not):
-- a numbered list covering EVERY corpse slot (RollFor parity): coin plus
-- all qualities. Threshold+ items are roll rows (SR/HR badge on the right;
-- clicking opens the row detail); coin and below-threshold items are free
-- rows (one click loots the slot, no rolling). The detail STAYS OPEN as
-- the roll window (RollFor preview ->
-- rolling -> winners flow): choose SR (direct award on a single holder) /
-- Roll / Close; while rolling it lists every valid roll with its kind
-- (SR/MS/OS/TMOG); when the roll finishes it becomes the award window
-- (winner rows + ... for anyone else). Close returns to the overview.
--
-- Data layer (M.items, M.detail) is plain tables so tests drive it
-- headless; frames are client-only (nil-guarded, mock-safe).
-- Item: { itemID, link, texture, quality, quantity, slot, badge, status,
--         source, index }
--   badge: "HR" | "SR" | "SR:n" | ""; status: "open"|"rolling"|"done";
--   source: "loot"|"sim"; index: 1-based row number (RollFor modern skin).
-- Detail: BuildDetail fields + phase ("pick"|"rolling"|"award"),
--   sessionID (roll it tracks), rolls ({name, roll, rollType, effective}),
--   menu (award data once finished), countdown (seconds left, client paint).
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.LootWindow = M

M.items = {}
M.title = "ZugLoot Loot"
M.frame = nil
M.rows = {}

-- Class-colored display name (data stays raw everywhere).
local function PName(name)
  if Z.ClassColors and Z.ClassColors.ColoredName then
    return Z.ClassColors.ColoredName(name)
  end
  return tostring(name or "")
end

-- Row detail state (plain data): { itemID, link, badge, rollers={names},
-- single=bool (exactly one SR/HR holder), status, source }.
-- Parked states: one saved detail per item (M.parked[itemID]) so the ML can
-- close an item after a roll and come back later — rolls, winner menu and
-- all. Deleted on award, never resurrected.
M.detail = nil
M.detailFrame = nil
M.parked = {}

M.ROW_HEIGHT = 24
M.ICON_SIZE = 20
-- Button bar: floating flow layout (justify each row, wrap when narrow).
M.BTN_HEIGHT = 22
M.BTN_GAP = 8
M.BTN_MARGIN = 10
M.BTN_MORE_W = 44
M.BTN_CLOSE_W = 60
-- Wide enough for "Award <name>" on ONE line (RollFor sizes rows to the
-- widest content). 320 fits ~35-char names next to the ... / Close buttons.
M.DETAIL_WIDTH = 320

function M.Clear()
  M.items = {}
  M.detail = nil
  M.parked = {}
  M.DisarmWatchdogs()
  M.Refresh()
  M.RefreshDetail()
end

-- Watchdog: when a click-to-loot call goes silent (issued clean, row
-- dimmed, but no LOOT_SLOT_CLEARED within a few seconds and no error),
-- poke the corpse — re-read the clicked slot. If the item is STILL there
-- the call died server-side: un-dim the row at once and say so (don't
-- wait for a confirm that never comes, don't strand grey rows). If the
-- slot emptied without an event, reconcile. Timer-driven (vanilla-safe);
-- headless no-op without corpse APIs. One watchdog per click; disarmed
-- by confirm (RescanLeftovers), error (UI_ERROR_MESSAGE), or firing.
M.watchdogs = nil
function M.WatchClick(slot, itemID, rowName)
  if not (GetNumLootItems and Z.Timer and Z.Timer.After) then return end
  M.watchdogs = M.watchdogs or {}
  local wd = { slot = slot, itemID = itemID, dead = false }
  table.insert(M.watchdogs, wd)
  Z.Timer.After(4, function()
    wd.dead = true
    if M.watchdogs then
      for i = Z.Util.ArrayCount(M.watchdogs), 1, -1 do
        if M.watchdogs[i] == wd then table.remove(M.watchdogs, i) break end
      end
    end
    -- Armed click still pending AND row still dimmed = silent ignore.
    local armed = Z.MasterLootUI and Z.MasterLootUI.pendingLoot
      and Z.MasterLootUI.pendingLoot[slot]
    local row = M.Find(itemID)
    if not (armed and row and row.status == "done") then return end
    -- Re-read the corpse slot: gone = late confirm arrived unordered,
    -- reconcile; present = server dropped the call, un-dim + report.
    if Z.MasterLootUI and Z.MasterLootUI.VerifySlot then
      local v = Z.MasterLootUI.VerifySlot(itemID, slot)
      if v == "gone" or v == nil then
        if Z.MasterLootUI.RescanLeftovers then Z.MasterLootUI.RescanLeftovers() end
        return
      end
    end
    if Z.MasterLootUI then Z.MasterLootUI.pendingLoot[slot] = nil end
    row.status = "open"
    M.Refresh()
    Z.Print("Loot didn't go through for " .. tostring(rowName or itemID)
      .. " (slot " .. tostring(slot) .. ") — click again to retry.")
  end)
end
function M.DisarmWatchdogs()
  M.watchdogs = nil
end

-- Replace the list (loot scan / sim queue). Plain array of
-- { itemID, link, texture, quality, quantity, slot, badge, sr, coin, free };
-- status starts "open", index follows list order (RollFor modern skin
-- numbering). badge wins over sr; sr feeds the legacy badge derivation.
-- Coin rows use itemID "Coin" (no link); free rows are below-threshold
-- items looted with one click instead of rolled.
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
        link = e.link or ((not e.coin) and ("item:" .. tostring(e.itemID)) or nil),
        name = e.name,
        texture = e.texture,
        quality = e.quality or 0,
        quantity = e.quantity,
        slot = e.slot,
        badge = badge or "",
        coin = e.coin and true or false,
        free = (not e.coin and not e.group) and (e.free and true or false) or false,
        group = (not e.coin) and (e.group and true or false) or false,
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

-- Blizzard frame takeover (RollFor parity): Blizzard's `LootFrame` is a
-- real FrameXML window that pops itself on LOOT_OPENED. Hiding it once is
-- not enough — it re-shows on every loot (page changes, re-opens, group
-- updates). So on login we DETACH it for the whole session:
-- UnregisterAllEvents (it never hears LOOT_OPENED again) + strip its
-- OnHide script (FrameXML hides itself via that hook). From then on OUR
-- loot window is the loot window, always, in every looting situation.
-- All client-global access is nil-guarded so headless/tests never touch it.
-- Session detach flag: once ADDON_LOADED fires the takeover is armed;
-- re-armed per LOOT_OPENED (repeat detach is cheap and idempotent).
M.blizzardTakeover = false
-- takeOver=true detaches (hide Blizzard's frame, ours takes over);
-- takeOver=false restores (re-register LOOT_* events, show on next loot).
-- Events unregistered on 1.12: LOOT_OPENED, LOOT_CLOSED, LOOT_SLOT_CLEARED,
-- plus the OnHide CloseLoot hook — the full set FrameXML subscribes.
-- Restoring ONLY re-registers: Blizzard repopulates itself on the next
-- loot (or immediately if a loot session is currently open).
-- Takeover preference: Z.DB.lootTakeover (persisted). The kill-switch
-- sets it false; the user re-arms via Setup tab or /zl lootframe.
-- takeOver arg forces a direction for this call AND persists it.
function M.TakeoverWanted()
  if Z.DB and Z.DB.lootTakeover == false then return false end
  return true
end
function M.SetTakeoverWanted(want)
  if Z.DB then Z.DB.lootTakeover = want and true or false end
  M.DetachBlizzardLoot(want and true or false)
end
function M.DetachBlizzardLoot(takeOver)
  if takeOver == nil then takeOver = M.TakeoverWanted() end
  local function frameTakeover(f)
    if not f then return end
    if takeOver then
      if f.UnregisterAllEvents then pcall(f.UnregisterAllEvents, f) end
      if f.SetScript then pcall(f.SetScript, f, "OnHide", nil) end
      if f.Hide then pcall(f.Hide, f) end
    else
      if f.RegisterEvent then
        pcall(f.RegisterEvent, f, "LOOT_OPENED")
        pcall(f.RegisterEvent, f, "LOOT_CLOSED")
        pcall(f.RegisterEvent, f, "LOOT_SLOT_CLEARED")
      end
      -- Re-arm FrameXML's own close hook so its window behaves stock.
      if f.SetScript and CloseLoot then
        pcall(f.SetScript, f, "OnHide", function() pcall(CloseLoot) end)
      end
      -- Do NOT Show() here: a frame detached before this loot session
      -- never ran LootFrame_OnShow, its internal page state is nil, and
      -- forcing Show() crashes FrameXML (LootFrame.lua arithmetic on nil
      -- page). The re-registered LOOT_OPENED repopulates it on the NEXT
      -- loot; the CURRENT corpse must be re-looted (close it: walking
      -- away / CloseLoot ends the broken session cleanly).
      -- NOTE: CloseLoot is deliberately NOT auto-called: ending the
      -- player's loot session out from under them would drop loot access
      -- entirely. Print the recovery step instead (once, at restore).
    end
  end
  frameTakeover(LootFrame) -- client global; nil headless (tests never define it)
  frameTakeover(pfLootFrame) -- pfQuest's loot skin, same treatment when present
  M.blizzardTakeover = takeOver
end
-- Per-loot safety net: keep Blizzard's frame down while OUR rows cover
-- the corpse (post-detach this is normally already hidden; cheap to repeat).
-- Safe headless (LootFrame is a client global that tests never define).
function M.HideBlizzardLoot()
  M.DetachBlizzardLoot()
end
-- NOTE: group-loot Need/Greed popups (GroupLootFrame1..N) are deliberately
-- LEFT ALONE: detaching them without rewiring the dice to RollOnLoot would
-- leave group-rolled items unrollable. The takeover scope is the corpse
-- loot window (LootFrame), in every loot method — the master-loot frame
-- replaces Blizzard's in all looting situations.

-- Slot-kind check: coin slots carry no item link. Vanilla exposes
-- LootSlotIsCoin AND LootSlotIsItem (1.12 FrameXML convention, cf.
-- Gatherhud/BigWigs/Aegis_Exchange usage across this client); backported
-- clients expose GetLootSlotType (LOOT_SLOT_MONEY == 2). Nil-safe: false
-- with no client APIs (headless).
function M.IsCoinSlot(slot)
  if LootSlotIsCoin then
    local ok, v = pcall(LootSlotIsCoin, slot)
    if ok and v == 1 then return true end
  end
  if LootSlotIsItem then
    local ok, v = pcall(LootSlotIsItem, slot)
    if ok then return not (v == 1) end
  end
  if GetLootSlotType then
    local ok, t = pcall(GetLootSlotType, slot)
    if ok and t ~= nil then
      if t == 2 then return true end
      if LOOT_SLOT_MONEY and t == LOOT_SLOT_MONEY then return true end
      return false
    end
  end
  return false
end

-- The PARTY's roll threshold (green 2 .. epic 4): items BELOW it never
-- enter a group roll — Blizzard hands them out via plain LootSlot, no
-- Need/Greed frames. Reads the live client setting; falls back to the
-- client default (uncommon) headless or when the API is absent.
function M.GroupRollThreshold()
  if GetLootThreshold then
    local ok, t = pcall(GetLootThreshold)
    if ok and type(t) == "number" then return t end
  end
  return (Z.Limits and Z.Limits.LOOT_THRESHOLD_DEFAULT) or 2
end

-- Should this item go through a GROUP roll (Need/Greed frames) rather
-- than plain LootSlot? Only in a group, only under group loot, only at
-- or above the party's threshold. Everything else is directly lootable.
-- quality: GetLootSlotInfo 4th return (nil-safe: unknown -> not rollable).
function M.IsGroupRollItem(quality)
  if not (Z.SRSecurity and Z.SRSecurity.IsSolo
      and not Z.SRSecurity.IsSolo()) then return false end
  local method = nil
  if GetLootMethod then
    local ok, m = pcall(GetLootMethod)
    if ok then method = m end
  end
  if method == nil and Z.SRSecurity and Z.SRSecurity.LootMethod then
    local ok, m = pcall(Z.SRSecurity.LootMethod)
    if ok then method = m end
  end
  if method ~= "group" then return false end
  if type(quality) ~= "number" then return false end
  return quality >= M.GroupRollThreshold()
end

-- Handed out = gone: drop the row from the list (by itemID; scanning the
-- corpse again re-adds the odd leftover). Parked state for the item dies
-- with it — awarded state is never resurrected. A list with zero rows
-- left is not a record — history lives in the Sheet tab.
-- slotHint narrows to the CLICKED row when duplicate itemIDs share the
-- corpse (two of the same grey): looting one leaves the other listed.
function M.RemoveItem(itemID, slotHint)
  local n = Z.Util.ArrayCount(M.items)
  for i = n, 1, -1 do
    local it = M.items[i]
    if it and it.itemID == itemID
        and (slotHint == nil or it.slot == slotHint) then
      table.remove(M.items, i)
      if slotHint ~= nil then break end
    end
  end
  -- Renumber: rows are the 1-based RollFor modern-skin list order.
  for i = 1, Z.Util.ArrayCount(M.items) do
    M.items[i].index = i
  end
  M.DropParked(itemID)
  if M.detail and M.detail.itemID == itemID then
    M.detail = nil
    if M.detailFrame and M.detailFrame.Hide then M.detailFrame:Hide() end
    M.detailFrame = nil
  end
  M.Refresh()
  -- Nothing left: the corpse is fully distributed. Close the window and
  -- the loot (Clear() also fires on a fresh LOOT_OPENED, so the next
  -- corpse starts clean). Every slot had a row, so nothing is stranded.
  if Z.Util.ArrayCount(M.items) == 0 then
    M.Hide()
    if CloseLoot then pcall(CloseLoot) end
  end
end

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

-- The overview Close button: reconcile with the corpse (confirmed loots
-- drop, failed clicks stay) instead of blindly hiding. Empty tracked list
-- closes the loot out; leftovers stay listed so nothing undistributed is
-- lost by dismissing the window.
function M.CloseOverview()
  if Z.MasterLootUI and Z.MasterLootUI.RescanLeftovers then
    Z.MasterLootUI.RescanLeftovers()
  end
  if Z.Util.ArrayCount(M.items) == 0 then
    M.Hide()
    if CloseLoot then pcall(CloseLoot) end
    return "closed"
  end
  M.Hide()
  return "parked"
end

-- No Blizzard fallback: every corpse slot (coin, greys, green+) has a row
-- in OUR window with a click-to-loot path, so Blizzard's frame is never
-- needed and stays detached. Kept as no-op shims (callers/tests may
-- reference them). Nil-safe headless.
function M.MaybeBlizzardFallback() return false end

function M.HideBlizzardFallback() end

-- Corpse-side refresh: re-scan whatever is left. LOOT_SLOT_CLEARED is the
-- CONFIRMATION that a slot left the corpse (our click or anyone else's):
-- the slot-keyed rescan drops exactly that row and keeps the rest.
-- LOOT_CLOSED with an empty tracked list hides the window.
-- Nil-safe headless (no corpse APIs -> no-op).
function M.OnEvent(event, arg1)
  if event == "LOOT_CLOSED" then
    if Z.Util.ArrayCount(M.items or {}) == 0 then M.Hide() end
  elseif event == "LOOT_SLOT_CLEARED" then
    if Z.MasterLootUI and Z.MasterLootUI.RescanLeftovers then
      Z.MasterLootUI.RescanLeftovers()
    end
  end
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
  local f = CreateFrame("Frame", "ZugLootMasterLootFrame", UIParent)
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
  closeB:SetScript("OnClick", function() M.CloseOverview() end)
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
  if it.coin then return "Coin" end
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

-- Button width estimator (mock-safe: GetStringWidth when available).
function M.ButtonWidth(btn, text)
  local fs = btn.GetFontString and btn:GetFontString()
  local w = 0
  if fs and fs.GetStringWidth then w = fs:GetStringWidth() or 0 end
  if w == 0 then w = string.len(tostring(text)) * 7 end
  w = w + 24
  if w < 80 then w = 80 end
  return w
end

-- Flow layout (pure, headless-testable): pack visible buttons into rows
-- inside `barW`, then justify each row (even side margins, even gaps).
-- Input: { {btn=ref, w=width}... } in bar order. Returns rows of
-- { {btn, x, w}... } with x relative to the bar's left edge, plus the
-- row count. Rows stack upward from the bar bottom (row 1 = bottom).
function M.LayoutBarRows(slots, barW)
  local rows, cur, used = {}, {}, 0
  local gap = M.BTN_GAP
  for i = 1, Z.Util.ArrayCount(slots or {}) do
    local s = slots[i]
    local need = s.w + (Z.Util.ArrayCount(cur) > 0 and gap or 0)
    if Z.Util.ArrayCount(cur) > 0 and used + need > barW then
      table.insert(rows, cur)
      cur, used = {}, 0
      need = s.w
    end
    table.insert(cur, s)
    used = used + need
  end
  if Z.Util.ArrayCount(cur) > 0 then table.insert(rows, cur) end
  -- Justify: even margins + even gaps per row.
  local out = {}
  for r = 1, Z.Util.ArrayCount(rows) do
    local row = rows[r]
    local total = 0
    for i = 1, Z.Util.ArrayCount(row) do total = total + row[i].w end
    local gaps = Z.Util.ArrayCount(row) + 1
    local space = (barW - total) / gaps
    if space < 0 then space = 0 end
    local placed, x = {}, space
    for i = 1, Z.Util.ArrayCount(row) do
      table.insert(placed, { btn = row[i].btn, x = x, w = row[i].w })
      x = x + row[i].w + space
    end
    table.insert(out, placed)
  end
  return out
end

-- Apply a LayoutBarRows result to live buttons: row 1 sits on the bar
-- bottom (BOTTOM + margin), higher rows stack above it.
function M.PlaceBarRows(f, rows, barW)
  if not (f and rows) then return 0 end
  local bh = M.BTN_HEIGHT
  for r = 1, Z.Util.ArrayCount(rows) do
    local y = M.BTN_MARGIN + (r - 1) * (bh + M.BTN_GAP)
    for i = 1, Z.Util.ArrayCount(rows[r]) do
      local cell = rows[r][i]
      local btn = cell.btn
      if btn then
        if btn.SetWidth then btn:SetWidth(cell.w) end
        if btn.ClearAllPoints then btn:ClearAllPoints() end
        if btn.SetPoint then
          btn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", M.BTN_MARGIN + cell.x, y)
        end
        if btn.Show then btn:Show() end
      end
    end
  end
  return Z.Util.ArrayCount(rows)
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
    -- Row click: coin/free rows loot their slot at once (no detail, no
    -- rolling); roll rows open the detail (RollFor: row click selects).
    -- Slot-explicit closure: the click carries THIS row's slot, never a
    -- Find(itemID) lookup (duplicates would loot the wrong row's slot).
    if row.SetScript then
      local clickSlot = it.slot
      row:SetScript("OnClick", function() M.OnRowClick(id, clickSlot) end)
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
    phase = "pick", -- pick -> rolling -> award
    sessionID = nil,
    rolls = {},
    menu = nil,
    countdown = nil,
  }
end

-- Feed a roll into a detail (called from OnSystemRoll): only rolls for
-- the tracked session, first-roll-only, exactly the live list rule.
-- Targets the OPEN detail when it tracks this item, else the PARKED one
-- (multi-roll: timed rolls land on the closed item's saved state).
-- Returns true when the roll landed on a detail.
function M.DetailOnRoll(itemID, sessionID, player, roll, rollType, effective)
  -- Multi-roll: timed rolls land on the closed item's saved state when
  -- the open detail is tracking a different item.
  local d = M.detail
  if not d or d.itemID ~= itemID then
    d = M.parked and M.parked[itemID] or nil
  end
  if not d or d.itemID ~= itemID then return false end
  if d.phase ~= "rolling" then return false end
  if sessionID and d.sessionID and sessionID ~= d.sessionID then return false end
  d.rolls = d.rolls or {}
  for i = 1, Z.Util.ArrayCount(d.rolls) do
    if d.rolls[i].name == player then return false end
  end
  table.insert(d.rolls, { name = player, roll = roll, rollType = rollType,
    effective = effective })
  if d == M.detail then M.RefreshDetail() end
  return true
end

-- The roll finished: hand the award menu to the open detail, which becomes
-- the award window (winner rows + ... for anyone else). Keeps sessionID so
-- late rolls for the same session still land (harmless).
function M.DetailOnFinish(itemID, menu)
  -- The finished item's detail may be parked (closed mid-roll) while
  -- another row is open: hand the menu to whichever copy tracks it.
  local d = M.detail
  if not d or d.itemID ~= itemID then
    d = M.parked and M.parked[itemID] or nil
  end
  if not d or d.itemID ~= itemID then return false end
  d.menu = menu
  d.phase = "award"
  d.countdown = nil
  if d == M.detail then M.RefreshDetail() end
  return true
end

-- Sorted roll rows for paint/text: SR > MS > OS > TMOG, best first.
function M.SortedDetailRolls(d)
  d = d or M.detail
  local order = { SR = 1, MS = 2, OS = 3, TMOG = 4 }
  local out = {}
  for i = 1, Z.Util.ArrayCount((d and d.rolls) or {}) do
    table.insert(out, d.rolls[i])
  end
  table.sort(out, function(a, b)
    local oa, ob = order[a.rollType] or 9, order[b.rollType] or 9
    if oa ~= ob then return oa < ob end
    if (a.effective or a.roll or 0) ~= (b.effective or b.roll or 0) then
      return (a.effective or a.roll or 0) > (b.effective or b.roll or 0)
    end
    return (a.name or "") < (b.name or "")
  end)
  return out
end

-- Park the open detail so its state survives row switching and Close:
-- rolling/award windows, plus any window whose row still has a LIVE
-- session (a mid-roll pick-phase close must keep the session's rolls so
-- switching back shows the live roll). Pure-idle pick windows (no live
-- session, no rolls, no menu) rebuild identically from the row and park
-- nothing. Deep-copies rolls + menu so later rolls/finishes can't alias
-- the saved state.
local function snapshotDetail(d)
  if not d then return nil end
  local liveSess = Z.MasterLootUI and Z.MasterLootUI.sessions
    and Z.MasterLootUI.sessions[d.itemID] or nil
  local hasState = (d.phase or "pick") == "rolling"
    or (d.phase or "pick") == "award"
    or (d.rolls and Z.Util.ArrayCount(d.rolls) > 0)
    or d.menu ~= nil or liveSess ~= nil
  if not hasState then return nil end
  local rolls = {}
  for i = 1, Z.Util.ArrayCount(d.rolls or {}) do
    local r = d.rolls[i]
    table.insert(rolls, { name = r.name, roll = r.roll,
      rollType = r.rollType, effective = r.effective })
  end
  return { itemID = d.itemID, link = d.link, name = d.name,
    tipLink = d.tipLink, badge = d.badge, status = d.status,
    source = d.source, rollers = d.rollers, single = d.single,
    phase = d.phase, sessionID = d.sessionID, rolls = rolls,
    menu = d.menu, countdown = d.countdown }
end

function M.ParkDetail()
  local d = M.detail
  if not d then return end
  local snap = snapshotDetail(d)
  if snap then M.parked = M.parked or {} M.parked[d.itemID] = snap end
end

function M.DropParked(itemID)
  if M.parked then M.parked[itemID] = nil end
end

function M.ParkedDetail(itemID)
  local t = M.parked or (Z.LootWindow and Z.LootWindow.parked)
  if t then return t[itemID] end
  return nil
end

-- Row click entry: coin/free rows loot immediately through Blizzard's
-- frame (the only path that moves the item) and leave the list. Solo,
-- EVERY corpse row loots on click (Blizzard solo behavior: click takes
-- it) — out of group there is nobody to roll against, so even
-- threshold+ rows skip the detail. Sim rows carry no corpse slot and
-- always open the detail. Returns what happened (headless-testable).
-- Click-to-loot: coin/free rows ALWAYS loot on click; solo, EVERY corpse
-- row loots on click (nobody to roll against). Loot first, drop the row
-- only once the corpse CONFIRMS it (LOOT_SLOT_CLEARED, same slot) — never
-- optimistically, so a failed LootSlot (locked, full bags, range) leaves
-- the row up for retry. Sim rows carry no corpse slot: detail as usual.
-- Returns "looting" (call issued), "loot failed" (no call), or
-- "detail" (headless-testable).
-- Group-roll rows (Blizzard's Need/Greed owns them) are display-only:
-- clicking never loots (that would steal the item out from under the
-- group roll); the row drops when Blizzard's roll resolves and the winner
-- loots it (LOOT_SLOT_CLEARED rescan).
-- clickSlot: the CLICKED row's slot from the button closure (never a
-- Find(itemID) lookup — duplicates share itemIDs). Falls back to the
-- row's tracked slot when the closure predates it (headless/tests call
-- with itemID only).
-- Passthrough: when Blizzard's frame is restored (takeover off — e.g.
-- the click-to-loot kill-switch after silent loot calls), our rows are
-- display-only: report it and touch nothing, Blizzard's own frame loots.
function M.OnRowClick(itemID, clickSlot)
  local it = M.Find(itemID)
  if it and it.group then return "group roll" end
  local solo = Z.SRSecurity and Z.SRSecurity.IsSolo
    and Z.SRSecurity.IsSolo()
  if M.blizzardTakeover == false then return "passthrough" end
  local slot = clickSlot or (it and it.slot)
  if it and slot and (it.coin or it.free or solo) then
    local issued = nil
    if Z.MasterLootUI and Z.MasterLootUI.LootCorpseSlot then
      local me = nil
      if UnitName then local ok, nm = pcall(UnitName, "player") if ok then me = nm end end
      issued = Z.MasterLootUI.LootCorpseSlot(it.link, itemID, me, slot)
    end
    -- STRICT true: "noslot" (corpse unreadable), "gone" (item already
    -- off the corpse — rescan to reconcile) and false (refused) must
    -- NEVER dim the row — a dimmed-but-unlooted row is exactly the
    -- reported "gray and says done, still not looted" ghost.
    -- "passthrough" (Blizzard frame restored, hands off): nothing to dim.
    if issued == "gone" then
      if Z.MasterLootUI and Z.MasterLootUI.RescanLeftovers then
        Z.MasterLootUI.RescanLeftovers()
      end
      return "gone"
    end
    if issued == "passthrough" then return "passthrough" end
    if issued == true then
      M.MarkDone(itemID)
      -- Watchdog: if no confirm/error lands within 4s, re-read the slot
      -- and un-dim a still-present row (silent server ignore must never
      -- strand grey rows). Disarmed by confirm/error firing first.
      if M.WatchClick then M.WatchClick(slot, itemID, M.DisplayName(it)) end
      -- Kill-switch watch: clicks only (awards don't feed it — an ML
      -- re-awarding the same item must never restore Blizzard's frame).
      -- TWO consecutive silent clicks (issued clean, never confirmed) on
      -- the same slot+item = dead LootSlot path: restore Blizzard's frame.
      if M.NoteSilentLoot then M.NoteSilentLoot(slot, itemID) end
      if M.lootDebug then
        local link = nil
        if GetLootSlotLink then
          local ok, l = pcall(GetLootSlotLink, slot)
          if ok then link = l end
        end
        local method = nil
        if GetLootMethod then
          local ok, m = pcall(GetLootMethod)
          if ok then method = m end
        end
        -- FULL link (never truncated: names with spaces must be verifiable)
        -- plus loot method, so a wrong-slot vs dead-call cause is conclusive.
        Z.Print("lootdebug: row=" .. tostring(M.DisplayName(it))
          .. " LootSlot(" .. tostring(slot) .. ") of "
          .. tostring(GetNumLootItems and GetNumLootItems())
          .. " method=" .. tostring(method)
          .. " link=" .. tostring(link))
      end
      return "looting"
    end
    return "loot failed"
  end
  return M.OpenDetail(itemID) and "detail" or nil
end

-- /zl lootdebug: verbose click-to-loot logging (slot, corpse size, link).
M.lootDebug = false

-- Silent-call kill-switch: tracks consecutive click-to-loot calls that
-- issued clean but never confirmed (no LOOT_SLOT_CLEARED, no error).
-- LOOT_SLOT_CLEARED disarms via RescanLeftovers (arms clear there); any
-- second silent call while one is still armed = the LootSlot path is dead
-- on this client: restore Blizzard's frame (takeover off) so loot keeps
-- working through the stock UI instead of stranding dimmed rows.
-- Solo-only guard lives at the call site (grouped rolls need our flow).
-- Headless-safe: pure table + client-global touch isolated in Detach.
M.silentLootArms = nil
function M.NoteSilentLoot(slot, itemID)
  local solo = Z.SRSecurity and Z.SRSecurity.IsSolo
    and Z.SRSecurity.IsSolo()
  if not solo then return end
  M.silentLootArms = M.silentLootArms or {}
  for i = 1, Z.Util.ArrayCount(M.silentLootArms) do
    local a = M.silentLootArms[i]
    if a and a.slot == slot and a.itemID == itemID then
      -- Second silent call on the same slot+item: path is dead. Persist
      -- the stand-down (survives corpses AND reloads) so the next corpse
      -- doesn't re-detach into the same broken loop — Blizzard's frame
      -- handles loot until the user re-arms (/zl lootframe, Setup tab).
      M.silentLootArms = nil
      if Z.LootWindow and Z.LootWindow.Clear then Z.LootWindow.Clear() end
      M.SetTakeoverWanted(false)
      -- The current corpse was scanned under a detached frame, so
      -- Blizzard's window can't show it (forced Show would crash
      -- FrameXML on nil page state). Re-loot the corpse for the stock UI.
      Z.Print("ZugLoot loot clicks aren't reaching the server — "
        .. "Blizzard loot frame restored (stays off until /zl lootframe). "
        .. "Close this corpse and loot it again; /zl sheet etc. still work.")
      return
    end
  end
  table.insert(M.silentLootArms, { slot = slot, itemID = itemID })
end

function M.OpenDetail(itemID)
  -- Switching rows parks the current detail first (state saved), then
  -- reopens the requested one: parked state if it has any, else a fresh
  -- pick window. Multi-roll: each item's rolls survive the switching.
  if M.detail and M.detail.itemID ~= itemID then
    M.ParkDetail()
    M.moreDropdown = nil
    M.detail = nil
  end
  -- A parked ROLLING/AWARD detail reopens exactly as it was closed:
  -- rolls, kind rows, winner menu, all intact. Stale IDLE pick snapshots
  -- (no session, no rolls, no menu) are dropped: the row rebuilds an
  -- identical pick window from live data.
  if M.parked and M.parked[itemID] then
    local psnap = M.parked[itemID]
    if (psnap.phase or "pick") == "pick" and (psnap.sessionID == nil or psnap.sessionID == 0)
        and (psnap.rolls == nil or Z.Util.ArrayCount(psnap.rolls) == 0)
        and psnap.menu == nil then
      M.parked[itemID] = nil
    end
  end
  if M.parked and M.parked[itemID] then
    M.detail = M.parked[itemID]
    M.parked[itemID] = nil
    M.RefreshDetail()
    return M.detail
  end
  local d = M.BuildDetail(itemID)
  if not d then return nil end
  M.detail = d
  M.RefreshDetail()
  return d
end

function M.CloseDetail()
  -- Closing parks a rolling/award window (state saved); pick windows
  -- just go away. Awarded items are removed from the list anyway, and
  -- RemoveItem clears any parked state for them.
  M.ParkDetail()
  M.moreDropdown = nil
  M.detail = nil
  if M.detailFrame and M.detailFrame.Hide then M.detailFrame:Hide() end
  M.detailFrame = nil
end

-- Detail display lines (headless/text): title, phase body, actions.
function M.DetailLines(d)
  d = d or M.detail
  local lines = {}
  if not d then return lines end
  local head = tostring(d.name or d.link or ("item:" .. d.itemID))
  if d.badge and d.badge ~= "" then head = head .. " [" .. d.badge .. "]" end
  if d.phase == "rolling" then head = head .. " [rolling]" end
  table.insert(lines, head)
  if d.phase == "rolling" then
    -- Live roll list: every valid roll with its kind (RollFor roll view).
    local rows = M.SortedDetailRolls(d)
    if Z.Util.ArrayCount(rows) == 0 then
      table.insert(lines, "  waiting for rolls...")
    else
      for i = 1, Z.Util.ArrayCount(rows) do
        local r = rows[i]
        local eff = ""
        if r.effective and r.effective ~= r.roll then
          eff = " (=" .. tostring(r.effective) .. ")"
        end
        table.insert(lines, "  " .. tostring(r.rollType) .. ": "
          .. PName(r.name) .. " " .. tostring(r.roll) .. eff)
      end
    end
  elseif (d.phase == "award" or d.phase == "preaward") and d.menu then
    -- Award window (open or parked): winner rows first, then the ...
    -- choices. Continue returns to the roll; award hands it out.
    local winners = d.menu.winners or {}
    for i = 1, Z.Util.ArrayCount(winners) do
      local w = winners[i]
      table.insert(lines, "  winner: " .. PName(w.name)
        .. " (" .. tostring(w.rollType) .. " " .. tostring(w.effective) .. ")")
    end
    if Z.Util.ArrayCount(winners) == 0 then
      table.insert(lines, "  (no eligible rolls — pick anyone or cancel)")
    end
  else
    if Z.Util.ArrayCount(d.rollers) > 0 then
      local rn = {}
      for i = 1, Z.Util.ArrayCount(d.rollers) do
        table.insert(rn, PName(d.rollers[i]))
      end
      table.insert(lines, "  reserved by: " .. table.concat(rn, ", "))
    else
      table.insert(lines, "  no reserves — open roll")
    end
  end
  local actions = M.DetailActions(d)
  local names = {}
  for i = 1, Z.Util.ArrayCount(actions) do table.insert(names, actions[i].label) end
  table.insert(lines, "  actions: " .. table.concat(names, " | "))
  return lines
end

-- Detail actions (data) per phase.
-- pick:    Award (single holder only), ... (More), Close.
-- rolling: Finish (ends the roll and parks it for award), Cancel (cr),
--          Close (window only, roll runs on).
-- preaward: finished roll parked for award — same award rows as award
--          (Award <winner> per kind winner, ... for anyone else) plus
--          Continue (reopens rolling for more rolls) and Close.
-- award:   Award <winner> per winner row, ... (anyone else), Close.
function M.AwardRowActions(d, actions)
  -- Every kind winner gets its own row: overall winner(s) first, then
  -- each contested kind (SR/MS/OS/TMOG) not already listed. The ML
  -- awards the SR, MS, OS or TMOG winner directly; ... covers anyone
  -- else (e.g. when something is wrong with the rolls).
  -- Labels color the name (buttons render FontStrings); the raw name
  -- rides along for the award call.
  local listed = {}
  for i = 1, Z.Util.ArrayCount(d.menu.winners or {}) do
    local w = d.menu.winners[i]
    table.insert(actions, { id = "award-name", label = "Award " .. PName(w.name)
      .. " (" .. tostring(w.rollType) .. ")", name = w.name, via = "winner" })
    listed[w.name] = true
  end
  for _, gt in ipairs({ "SR", "MS", "OS", "TMOG" }) do
    local trow = (d.menu.perType or {})[gt]
    if trow and trow.entry and not listed[trow.entry.name] then
      listed[trow.entry.name] = true
      local via = (gt == "TMOG") and "tmog" or "winner"
      table.insert(actions, { id = "award-name",
        label = "Award " .. PName(trow.entry.name) .. " (" .. gt .. ")",
        name = trow.entry.name, via = via })
    end
  end
  return actions
end

function M.DetailActions(d)
  d = d or M.detail
  local actions = {}
  if not d then return actions end
  if (d.phase or "pick") == "rolling" then
    table.insert(actions, { id = "finish", label = "Finish" })
    table.insert(actions, { id = "cancel", label = "Cancel" })
    table.insert(actions, { id = "close", label = "Close" })
    return actions
  end
  if (d.phase or "pick") == "preaward" and d.menu then
    M.AwardRowActions(d, actions)
    table.insert(actions, { id = "continue", label = "Continue" })
    table.insert(actions, { id = "more", label = "..." })
    table.insert(actions, { id = "close", label = "Close" })
    return actions
  end
  if (d.phase or "pick") == "award" and d.menu then
    M.AwardRowActions(d, actions)
    table.insert(actions, { id = "more", label = "..." })
    table.insert(actions, { id = "close", label = "Close" })
    return actions
  end
  if d.single then
    table.insert(actions, { id = "award", label = "Award " .. PName(d.rollers[1]) })
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
    -- Close FINISHES first: a live roll resolves into parked award rows,
    -- exactly as if Finish was pressed — then the window closes. Nothing
    -- keeps rolling behind a closed window; reopening shows the award
    -- rows (Continue reopens the roll). Idle pick windows just close.
    local MLUI = Z.MasterLootUI
    if (d.phase or "pick") == "rolling"
        and MLUI and MLUI.sessions and MLUI.sessions[itemID] then
      MLUI.Finish(true, itemID)
      -- DetailOnFinish retargeted the (possibly parked) detail; re-read.
      d = M.detail
      if not d or d.itemID ~= itemID then
        d = M.ParkedDetail(itemID)
      end
      if d and (d.phase or "pick") == "award" and d.menu then
        d.phase = "preaward"
      end
    end
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
    -- Initiate the roll from the detail. The detail STAYS OPEN and becomes
    -- the roll window (RollFor: preview flips to the rolling view); the
    -- session hooks below flip it to the award view on finish, and the
    -- view parks for award the moment it finishes.
    -- Sequential holds: refused when THIS item already rolls, or when
    -- ANOTHER item's roll is running (finish, cancel or close it first).
    local MLUI = Z.MasterLootUI
    if MLUI and MLUI.sessions and MLUI.sessions[itemID] then
      return "roll failed"
    end
    if MLUI and MLUI.session then
      return "roll failed"
    end
    -- Re-roll of a parked item: drop the stale snapshot so the fresh
    -- session builds pristine roll state (no phantom duplicate rolls).
    M.DropParked(itemID)
    local ok = false
    if d.source == "sim" then
      if Z.Sim and Z.Sim.RequestRoll then
        Z.Sim.RequestRoll(d.itemID)
        ok = true
      end
    else
      if Z.MasterLootUI and Z.MasterLootUI.StartItemRoll then
        Z.MasterLootUI.StartItemRoll(d.itemID)
        ok = true -- invocation is success (stub or real session)
      end
    end
    if ok then
      local sess = Z.MasterLootUI and Z.MasterLootUI.SessionFor
        and Z.MasterLootUI.SessionFor(itemID)
        or (Z.MasterLootUI and Z.MasterLootUI.session)
      d.phase = "rolling"
      d.sessionID = sess and sess.id or nil
      d.rolls = {}
      d.menu = nil
      d.status = "rolling"
      M.RefreshDetail()
      return "rolling"
    end
    return "roll failed"
  end
  if actionID == "award-name" then
    -- Award a named raider: from an award window (award OR parked
    -- preaward phase) this is the ROLLED award (menu confirm, history,
    -- sim continuation via AwardChosen); pre-roll (More list) it is the
    -- direct no-roll shortcut via AwardDirect.
    -- Stays open on failure, closes on success.
    if ((d.phase or "pick") == "award" or (d.phase or "pick") == "preaward") and d.menu then
      if Z.MasterLootUI and Z.MasterLootUI.AwardChosen then
        -- extra may be a plain name (More list) or {name, via}
        -- (award row). Default via="menu".
        local nm, via = extra, "menu"
        if type(extra) == "table" then nm, via = extra.name, extra.via or "menu" end
        Z.MasterLootUI.AwardChosen({ name = nm, via = via }, d.itemID)
        return "awarded " .. tostring(nm)
      end
      return "award failed"
    end
    if Z.MasterLootUI and Z.MasterLootUI.AwardDirect then
      Z.MasterLootUI.AwardDirect(d.itemID, extra, d.source)
      M.CloseDetail()
      return "awarded " .. tostring(extra)
    end
    return "award failed"
  end
  if actionID == "finish" then
    -- Finish: resolve THIS item's roll, then PARK the window for award.
    -- The award rows live in the loot list (preaward phase); Continue
    -- reopens the roll for more rolls, Close leaves it parked.
    -- Targets this item's session; other rolls run on.
    if Z.MasterLootUI and Z.MasterLootUI.FinishEarly then
      local out = Z.MasterLootUI.FinishEarly(itemID)
      if (d.phase or "pick") == "award" and d.menu then
        d.phase = "preaward"
        M.ParkDetail()
        M.RefreshDetail()
        return "finished"
      end
      return out == "tie" and "tie" or "finishing"
    end
    return "finish failed"
  end
  if actionID == "continue" then
    -- Reopen a parked (finished) roll for more rolls. The SAME session
    -- object re-attaches, so new rolls append to the same list and the
    -- session id is unchanged (stale feed guards stay valid).
    local MLUI = Z.MasterLootUI
    if MLUI and MLUI.sessions and MLUI.sessions[itemID] then
      return "already rolling"
    end
    local sess = MLUI and MLUI.ParkedSession
      and MLUI.ParkedSession(itemID) or nil
    if not sess then
      return "nothing to continue"
    end
    MLUI.UnparkSession(sess)
    if Z.Sim and Z.Sim.ContinueRoll then Z.Sim.ContinueRoll(itemID) end
    d.phase = "rolling"
    d.sessionID = sess.id
    d.status = "rolling"
    if Z.LootWindow and Z.LootWindow.MarkRolling then
      Z.LootWindow.MarkRolling(itemID)
    end
    M.RefreshDetail()
    return "continuing"
  end
  if actionID == "cancel" then
    -- Cancel the ROLL (session back to open); the window stays on the item
    -- in pick phase so the ML can re-roll or choose differently.
    if Z.MasterLootUI and Z.MasterLootUI.Cancel then
      Z.MasterLootUI.Cancel(itemID)
      local dd = M.detail
      if dd and dd.itemID == itemID then
        dd.phase = "pick"
        dd.sessionID = nil
        dd.rolls = {}
        dd.menu = nil
        dd.status = "open"
        M.RefreshDetail()
      end
      local parked = M.parked and M.parked[itemID] or nil
      if parked then
        parked.phase = "pick"
        parked.sessionID = nil
        parked.rolls = {}
        parked.menu = nil
        parked.status = "open"
      end
      return "cancelled"
    end
    return "cancel failed"
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
      table.insert(lines, "  SR: " .. PName(d.rollers[i]))
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
  f:SetPoint("CENTER", parent, "CENTER", 350, 40)
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
  -- Live roll list (RollFor rolling view): one line per valid roll with
  -- its kind. Hidden in pick phase, shown while rolling / awarding.
  local rolls = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  rolls:SetPoint("TOP", sub, "BOTTOM", 0, -6)
  rolls:SetWidth(290) rolls:SetJustifyH("LEFT")
  f.rolls = rolls
  -- Button bar pinned to the BOTTOM (never overlapping the roll list):
  -- primary left, ... + Close right. The primary is context per phase
  -- (re-labeled, never rebuilt):
  -- pick:    "Award <name>" on a single holder, else hidden (use ...).
  -- rolling: "Finish" (finish early -> this window becomes the award view).
  -- award:   "Award <top winner>" (further winners via their own rows).
  -- Width fits the label: measured text + padding, capped to the bar.
  -- NOTE: no SetPoint here — LayoutBar places all buttons (flow layout).
  local awardB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  awardB:SetHeight(M.BTN_HEIGHT)
  awardB:SetText("Award")
  awardB:SetScript("OnClick", function()
    if not M.detail then return end
    local ph = M.detail.phase or "pick"
    if ph == "rolling" then M.doAction(M.detail.itemID, "finish")
    elseif ph == "award" or ph == "preaward" then
      -- First award action row (top winner, incl. TMOG via choice).
      local acts = M.DetailActions(M.detail)
      local first = acts and acts[1]
      if first and first.id == "award-name" then
        M.doAction(M.detail.itemID, "award-name",
          { name = first.name, via = first.via })
      elseif first and first.id == "continue" then
        M.doAction(M.detail.itemID, "continue")
      end
    else M.doAction(M.detail.itemID, "award") end
  end)
  f.awardB = awardB
  -- Second award button: "Award TMOG" (TMOG kind winner). Visible in the
  -- award phase whenever the TMOG kind was contested. Sits right of the
  -- primary so both awards are one click, no ... menu needed.
  local tmogB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  tmogB:SetHeight(M.BTN_HEIGHT)
  tmogB:SetText("Award TMOG")
  tmogB:SetScript("OnClick", function()
    if not M.detail then return end
    local acts = M.DetailActions(M.detail)
    for i = 1, Z.Util.ArrayCount(acts or {}) do
      local a = acts[i]
      if a.id == "award-name" and a.via == "tmog" then
        M.doAction(M.detail.itemID, "award-name",
          { name = a.name, via = a.via })
        return
      end
    end
  end)
  f.tmogB = tmogB
  -- "..." More: a real dropdown (RollFor GuiElements.dropdown parity) —
  -- award anyone on the list, or initiate the roll. Anchored above the
  -- button (drops UP like RollFor's candidate frame) so it never covers
  -- the bar.
  local moreB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  moreB:SetWidth(M.BTN_MORE_W) moreB:SetHeight(M.BTN_HEIGHT)
  moreB:SetText("...")
  moreB:SetScript("OnClick", function()
    if M.detail then M.ToggleMoreDropdown(moreB) end
  end)
  f.moreB = moreB
  -- Close: dismiss, keep the overview.
  local closeB = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  closeB:SetWidth(M.BTN_CLOSE_W) closeB:SetHeight(M.BTN_HEIGHT)
  closeB:SetText("Close")
  f.closeB = closeB
  closeB:SetScript("OnClick", function() M.CloseDetail() end)
  M.detailFrame = f
  return f
end

function M.PaintDetailFrame()
  local f, d = M.detailFrame, M.detail
  if not f or not d then return end
  local phase = d.phase or "pick"
  if f.title and f.title.SetText then
    local head = tostring(d.name or d.link or ("item:" .. d.itemID))
    if d.badge and d.badge ~= "" then head = head .. " [" .. d.badge .. "]" end
    if phase == "rolling" then head = head .. " [rolling]" end
    f.title:SetText(head)
  end
  if f.title and f.title.SetScript then
    f.title:SetScript("OnEnter", function() M.ShowTip(f.title, d.tipLink) end)
    f.title:SetScript("OnLeave", function() M.HideTip() end)
  end
  if f.sub and f.sub.SetText then
    if phase == "rolling" then
      local n = Z.Util.ArrayCount(d.rolls or {})
      local cd = d.countdown and (" (" .. tostring(d.countdown) .. "s)") or ""
      f.sub:SetText("Rolling..." .. cd .. " (" .. n .. " roll" .. (n == 1 and "" or "s") .. ")")
    elseif (phase == "award" or phase == "preaward") and d.menu then
      local winners = d.menu.winners or {}
      if Z.Util.ArrayCount(winners) > 0 then
        local w = {}
        for i = 1, Z.Util.ArrayCount(winners) do
          table.insert(w, PName(winners[i].name) .. " (" .. tostring(winners[i].rollType)
            .. " " .. tostring(winners[i].effective) .. ")")
        end
        f.sub:SetText("Winner: " .. table.concat(w, ", "))
      else
        f.sub:SetText("No eligible rolls — pick anyone (...)")
      end
    elseif Z.Util.ArrayCount(d.rollers) > 0 then
      local rn = {}
      for i = 1, Z.Util.ArrayCount(d.rollers) do
        table.insert(rn, PName(d.rollers[i]))
      end
      f.sub:SetText("Reserved by: " .. table.concat(rn, ", "))
    else
      f.sub:SetText("No reserves — open roll")
    end
  end
  -- Live roll list widget (RollFor rolling view).
  if f.rolls then
    if phase == "pick" then
      if f.rolls.SetText then f.rolls:SetText("") end
      if f.rolls.Hide then f.rolls:Hide() end
    else
      if f.rolls.Show then f.rolls:Show() end
      if f.rolls.SetText then
        local rows = M.SortedDetailRolls(d)
        local t = {}
        for i = 1, Z.Util.ArrayCount(rows) do
          local r = rows[i]
          local eff = ""
          if r.effective and r.effective ~= r.roll then
            eff = " (=" .. tostring(r.effective) .. ")"
          end
          table.insert(t, tostring(r.rollType) .. ": " .. PName(r.name)
            .. " " .. tostring(r.roll) .. eff)
        end
        if Z.Util.ArrayCount(t) == 0 then
          f.rolls:SetText("waiting for rolls...")
        else
          f.rolls:SetText(table.concat(t, "\n"))
        end
      end
    end
  end
  -- Button bar: collect the visible buttons, then flow-layout them
  -- (justify each row, wrap when narrow). Bar order: primary, TMOG,
  -- ..., Close. A lone row spreads edge to edge; overflow wraps above.
  local barW = M.DETAIL_WIDTH - M.BTN_MARGIN * 2
  local slots = {}
  local function showBtn(btn, text)
    if btn.SetText then btn:SetText(text) end
    if btn.Enable then btn:Enable() end
    table.insert(slots, { btn = btn, w = M.ButtonWidth(btn, text) })
  end
  -- Award rows share one renderer across award + preaward (the parked
  -- view is the same award window, plus Continue): primary = top winner,
  -- TMOG button = TMOG kind winner, ... = everyone else.
  local function awardButtons()
    if not (d.menu and (phase == "award" or phase == "preaward")) then
      return
    end
    local acts = M.DetailActions(d)
    local first = acts and acts[1]
    if first and first.id == "award-name" then
      showBtn(f.awardB, first.label)
    elseif f.awardB.Hide then
      f.awardB:Hide() -- no eligible winners: primary hides, ... picks anyone
    end
    if f.tmogB then
      local trow = (d.menu.perType or {}).TMOG
      if trow and trow.entry then
        showBtn(f.tmogB, "Award TMOG (" .. PName(trow.entry.name) .. ")")
      elseif f.tmogB.Hide then
        f.tmogB:Hide()
      end
    end
  end
  if f.awardB then
    local show, label = false, "Award"
    if phase == "rolling" then
      show, label = true, "Finish"
    elseif phase == "preaward" and not d.menu then
      show, label = true, "Continue"
    elseif d.single and (phase == "pick" or (phase == "preaward" and not d.menu)) then
      show, label = true, "Award " .. PName(d.rollers[1])
    end
    if phase == "award" or (phase == "preaward" and d.menu) then
      -- Award window (open or parked): winner rows own the primary slot.
      awardButtons()
    elseif show then
      showBtn(f.awardB, label)
    elseif f.awardB.Hide then
      f.awardB:Hide()
    end
    if f.tmogB and phase ~= "award" and not (phase == "preaward" and d.menu) then
      -- TMOG button only lives on award windows; hidden otherwise
      -- (pick/rolling, or no TMOG roll).
      if f.tmogB.Hide then f.tmogB:Hide() end
    end
  end
  if f.moreB then showBtn(f.moreB, "...") end
  if f.closeB then showBtn(f.closeB, "Close") end
  local barRows = M.PlaceBarRows(f, M.LayoutBarRows(slots, barW), barW)
  if barRows == 0 then barRows = 1 end -- .../Close always slot in
  -- Grow the frame with the roll list (RollFor sizes to content), always
  -- reserving the full button bar (barRows x button + gaps + margin).
  local barH = (barRows or 1) * M.BTN_HEIGHT
    + ((barRows or 1) - 1) * M.BTN_GAP + M.BTN_MARGIN + 4
  if f.SetHeight and f.rolls then
    local n = (phase == "pick") and 0 or Z.Util.ArrayCount(d.rolls or {})
    if phase == "award" or phase == "preaward" then
      n = math.max(n, Z.Util.ArrayCount((d.menu and d.menu.winners) or {}))
    end
    f:SetHeight(math.max(120 + barH, 150 + n * 13))
  end
  -- Rolls text must end above the bar: anchor its bottom, not just top.
  if f.rolls and f.rolls.SetPoint and f.rolls.ClearAllPoints then
    f.rolls:ClearAllPoints()
    f.rolls:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -64)
    f.rolls:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -15, barH + 4)
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
  if (d.phase or "pick") == "pick" and d.status == "open" then
    table.insert(out, { id = "roll", label = "Roll" })
  end
  local seen = {}
  local function addAward(nm)
    if nm and nm ~= "" and not seen[nm] then
      seen[nm] = true
      table.insert(out, { id = "award-name", label = "Award " .. PName(nm), name = nm })
    end
  end
  for i = 1, Z.Util.ArrayCount(d.rollers or {}) do addAward(d.rollers[i]) end
  -- Award windows (open or parked): the ... covers everyone the primary
  -- button does not — winner rows are primary, ... lists the rest of
  -- the candidates.
  if ((d.phase or "pick") == "award" or (d.phase or "pick") == "preaward") and d.menu then
    local cands = d.menu.candidates or {}
    for i = 1, Z.Util.ArrayCount(cands) do
      if cands[i] then addAward(cands[i].name) end
    end
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
    -- Above the ... button (bar is at the bottom; drops UP so it never
    -- covers the buttons).
    dd:SetPoint("BOTTOM", anchor, "TOP", 0, 2)
  elseif dd.SetPoint and M.detailFrame then
    dd:SetPoint("BOTTOM", M.detailFrame, "BOTTOM", 0, 40)
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
