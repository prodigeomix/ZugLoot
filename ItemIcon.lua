-- ZugLoot/ItemIcon.lua
-- ONE shared implementation for every item-icon interaction in the addon.
-- Five sites show item icons (sheet cards, item-log header, raider roll
-- window, loot overview rows, loot detail header) and all five now run
-- this same code, so they can never drift apart again:
--   hover       = full GameTooltip item details (SetHyperlink when the
--                 client knows the item, name + hint otherwise — never a
--                 dead tooltip; bare ids upgrade through the cache live)
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

-- Hover: full item tooltip when the client knows the item, else the item
-- name (or item:id) + hint. onLink(full) fires when a bare id upgraded,
-- so the site can stash it (later hovers + clicks skip the lookup).
-- Returns "hyper", "text", or nil (no tooltip API).
function M.Hover(owner, itemID, link, name, onLink)
  if not (GameTooltip and owner) then return nil end
  local full = M.UpgradeLink(itemID, link)
  if full and full ~= link and onLink then pcall(onLink, full) end
  if GameTooltip.SetOwner then
    local ok = pcall(GameTooltip.SetOwner, GameTooltip, owner, "ANCHOR_RIGHT")
    if not ok then return nil end
  end
  if full and GameTooltip.SetHyperlink then
    pcall(GameTooltip.SetHyperlink, GameTooltip, full)
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
  if full then return "hyper" end
  return "text"
end

function M.Hide()
  if GameTooltip and GameTooltip.Hide then
    pcall(GameTooltip.Hide, GameTooltip)
  end
end

-- Click: ctrl tries the item on; otherwise resolve to a full link and
-- insert it into an open chat box (print it when none is open).
-- Returns "dressup" / "insert" / "print", or nil when nothing applied
-- (no modifier consumed: row callers fall through to the normal action).
function M.HandleClick(itemID, link, name, onLink)
  local id = tonumber(itemID)
  if not id and link then
    id = tonumber(string.match(tostring(link), "item:(%d+)"))
  end
  -- Ctrl-click: try it on (DressUp), like normal item links. Checked
  -- first, same order everywhere.
  if IsControlKeyDown and IsControlKeyDown() and DressUpItemLink and id then
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
  if full and ChatFrameEditBox and ChatFrameEditBox.IsVisible
      and ChatFrameEditBox:IsVisible() then
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
