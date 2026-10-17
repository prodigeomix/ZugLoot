-- ZugLoot/ItemIcon.lua
-- ONE shared implementation for every item-icon interaction in the addon.
-- Five sites show item icons (sheet cards, item-log header, raider roll
-- window, loot overview rows, loot detail header) and all five now run
-- this same code, so they can never drift apart again:
--   hover       = full GameTooltip item details via SetHyperlink with the
--                 BARE item string (the form working 1.12 addons use:
--                 bag/loot addons all pass "item:...", never
--                 the full color link). The client itself queries the server
--                 for uncached items, so details appear even with a cold
--                 cache — never a dead tooltip. Only a bare NAME (no id at
--                 all) falls back to name + hint text.
--   ctrl-click  = try it on (DressUpItemLink, like normal item links)
--   click/shift = full item link into an open chat box (printed when no
--                 box is open); never a bare "item:NNNN" id
-- Pure-safe at load (no client calls outside the functions); every client
-- global is nil-guarded for headless/tests.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.ItemIcon = M

M.HINT = "Details load when the client has seen this item."

local function hasFullLink(link)
  return link and string.find(tostring(link), "|Hitem:", 1, true)
    and true or false
end

-- Upgrade a bare "item:NNNN" link through the client cache. Returns the
-- full color link, or nil when the client hasn't seen the item. Bare
-- NAMES never resolve here (no id to look up) — they keep the text
-- fallback. Direct GetItemInfo(tonumber(id)) only, never the sheet-style
-- chain: its name-known BuildLink synthesis would fake a "full" link for
-- unseen items and kill the fallback.
function M.UpgradeLink(itemID, link)
  if hasFullLink(link) then return link end
  if not link or not GetItemInfo then return nil end
  local id = string.match(tostring(link), "item:(%d+)")
  if not id then id = itemID end
  id = tonumber(id)
  if not id then return nil end
  local ok, _, fullLink = pcall(GetItemInfo, id)
  if ok and hasFullLink(fullLink) then return fullLink end
  return nil
end

-- Bare item string for SetHyperlink: the inner "item:..." portion of a
-- full color link (keeps real enchant/suffix data), a bare link as-is
-- (even suffix-less "item:NNNN" — Atlas passes those), else synthesized
-- from the id. Nil only when there is no id at all (bare names).
function M.BareLink(itemID, link)
  local s = tostring(link or "")
  local inner = string.match(s, "|H(item:[^|]+)|h")
  if inner and inner ~= "" then return inner end
  if string.find(s, "^item:") then return s end
  local id = tonumber(itemID) or tonumber(string.match(s, "item:(%d+)"))
  if id then return "item:" .. tostring(id) .. ":0:0:0" end
  return nil
end

-- Hover: item details via SetHyperlink with the bare item string. The
-- client resolves it from cache or queries the server, so details show
-- even for items the client hasn't seen yet. onLink(full) still fires
-- when a bare id upgraded through the cache, so the site can stash the
-- full link for later shift-clicks. Only a bare NAME (no id) falls back
-- to name + hint text. Returns "hyper", "text", or nil (no tooltip).
function M.Hover(owner, itemID, link, name, onLink)
  if not (GameTooltip and owner) then return nil end
  local hyper = M.BareLink(itemID, link)
  local full = M.UpgradeLink(itemID, link)
  if full and full ~= link and onLink then pcall(onLink, full) end
  if GameTooltip.SetOwner then
    local ok = pcall(GameTooltip.SetOwner, GameTooltip, owner, "ANCHOR_RIGHT")
    if not ok then return nil end
  end
  if hyper and GameTooltip.SetHyperlink then
    pcall(GameTooltip.SetHyperlink, GameTooltip, hyper)
  else
    local title = name or ("item:" .. tostring(itemID))
    if GameTooltip.SetText then
      pcall(GameTooltip.SetText, GameTooltip, tostring(title), 1, 1, 1)
    end
    if GameTooltip.AddLine then
      pcall(GameTooltip.AddLine, GameTooltip, M.HINT, 0.7, 0.7, 0.7, 1)
    end
  end
  if GameTooltip.Show then pcall(GameTooltip.Show, GameTooltip) end
  if hyper then return "hyper" end
  return "text"
end

function M.Hide()
  if GameTooltip and GameTooltip.Hide then
    pcall(GameTooltip.Hide, GameTooltip)
  end
end

-- Modifier state (nil-guarded for headless/tests). Chat-open counts:
-- a plain click while typing must insert the link, never roll/loot.
function M.CtrlDown()
  return (IsControlKeyDown and IsControlKeyDown()) and true or false
end
function M.ShiftDown()
  return (IsShiftKeyDown and IsShiftKeyDown()) and true or false
end
function M.ChatOpen()
  return (ChatFrameEditBox and ChatFrameEditBox.IsVisible
    and ChatFrameEditBox:IsVisible()) and true or false
end
function M.ModifierDown()
  return M.CtrlDown() or M.ShiftDown() or M.ChatOpen()
end

-- Row-click gate: loot overview rows (body AND icon overlay) call this
-- FIRST inside OnRowClick. With any modifier/chat held it runs the
-- shared icon action (ctrl dress-up, shift/chat link) and returns its
-- result so the row action (open detail / loot slot) never fires.
-- Returns nil for a plain click (caller runs the row action), else
-- "dressup" / "insert" / "print" — or "modifier" when the keys
-- were held but nothing applied (unseen item: still swallow, never roll).
function M.RowClick(itemID, link, name, onLink)
  if not M.ModifierDown() then return nil end
  return M.HandleClick(itemID, link, name, onLink) or "modifier"
end

-- Click: ctrl tries the item on; otherwise resolve to a full link and
-- insert it into an open chat box (print it when none is open).
-- _name keeps signature parity with Hover/Wire (callers pass st.name).
-- Returns "dressup" / "insert" / "print", or nil when nothing applied.
function M.HandleClick(itemID, link, _name, onLink)
  local id = tonumber(itemID)
  if not id and link then
    id = tonumber(string.match(tostring(link), "item:(%d+)"))
  end
  -- Ctrl-click: try it on (DressUp), like normal item links. Checked
  -- first, same order everywhere.
  if M.CtrlDown() and DressUpItemLink and id then
    DressUpItemLink("item:" .. tostring(id))
    return "dressup"
  end
  -- Resolve at click time: the cache warms as you play (loot the item,
  -- see it linked), so a later click must give the full link even if the
  -- icon was built while the item was unknown.
  local full = M.UpgradeLink(itemID, link)
  if full and full ~= link and onLink then pcall(onLink, full) end
  if not full and GetItemInfo and link then
    -- Last resort: direct cache read (may still be bare if unseen).
    local ok, _, l = pcall(GetItemInfo, link)
    if ok and hasFullLink(l) then
      full = l
      if onLink then pcall(onLink, full) end
    end
  end
  -- Shift-click inserts/links; an open chat box captures any click.
  -- Plain icon clicks (sheet cards etc.) keep the old print fallback;
  -- loot rows never reach here plain (RowClick gates modifiers first,
  -- the icon overlay overwrites Wire's click with the row action).
  if full and M.ChatOpen() then
    if ChatFrameEditBox.Insert then ChatFrameEditBox:Insert(full) end
    return "insert"
  end
  if full and Z.Print then
    Z.Print(full)
    return "print"
  end
  return nil
end

-- Wire a Button: hover + leave + click all run the shared handlers.
-- get() returns { itemID, link, name, onLink } live at event time (never
-- a stale build-time snapshot: details/rows change under the widget).
function M.Wire(btn, get)
  if not (btn and btn.SetScript and get) then return btn end
  btn:SetScript("OnEnter", function()
    local st = get() or {}
    M.Hover(btn, st.itemID, st.link, st.name, st.onLink)
  end)
  btn:SetScript("OnLeave", function() M.Hide() end)
  btn:SetScript("OnClick", function()
    local st = get() or {}
    M.HandleClick(st.itemID, st.link, st.name, st.onLink)
  end)
  return btn
end

if ZugLoot then ZugLoot.ItemIcon = M end
return M
