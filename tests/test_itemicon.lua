-- tests/test_itemicon.lua
-- The ONE shared item-icon implementation (ItemIcon.lua): every icon in
-- the addon (sheet cards, log header, raider window, loot rows, loot
-- detail) runs this same code — hover details, ctrl dress-up, click
-- link — so the five sites can never drift apart.
local T = { pass = 0, fail = 0, errors = {} }

local function eq(a, b, msg)
  if a ~= b then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  else T.pass = T.pass + 1 end
end
local function ok(v, msg)
  if not v then T.fail = T.fail + 1 table.insert(T.errors, "FAIL " .. (msg or "expected truthy"))
  else T.pass = T.pass + 1 end
end

ZugLoot = {}
dofile("Util.lua")
dofile("ItemIcon.lua")
local II = ZugLoot.ItemIcon

-- This file must not leak client globals: later suites (test_sim) rely
-- on GetItemInfo/ChatFrameEditBox/DressUpItemLink being nil, and earlier
-- ones set their own stubs. Snapshot + restore at the end.
local savedGlobals = {
  GameTooltip = GameTooltip, GetItemInfo = GetItemInfo,
  IsControlKeyDown = IsControlKeyDown, DressUpItemLink = DressUpItemLink,
  ChatFrameEditBox = ChatFrameEditBox,
}

local FULL = "|cffa335ee|Hitem:17063:0:0:0|h[Thunderfury]|h|r"

-- Widget double: records scripts, texture target for texture-less callers.
local function newBtn()
  local b = { scripts = {} }
  function b:SetScript(k, f) self.scripts[k] = f end
  function b:GetScript(k) return self.scripts[k] end
  return b
end

-- Client-global doubles (reset per case below).
local tips, inserted, tried, printed
local function resetClient(opts)
  opts = opts or {}
  tips = {}
  inserted = {}
  tried = {}
  printed = {}
  GameTooltip = {
    SetOwner = function(self) return true end,
    SetHyperlink = function(self, link) table.insert(tips, { "hyper", link }) end,
    SetText = function(self, txt) table.insert(tips, { "text", txt }) end,
    AddLine = function(self, txt) table.insert(tips, { "line", txt }) end,
    Show = function(self) end,
    Hide = function(self) end,
  }
  GetItemInfo = opts.noCache and nil or function(id)
    local num = tonumber(string.match(tostring(id), "item:(%d+)") or id)
    if num == 99999 then return nil end -- unseen item: cache cold
    return "Test Sword", "|cffa335ee|Hitem:" .. tostring(num) .. ":0:0:0|h[Test Sword]|h|r",
      4, 0, 0, 0, 0, 0, "Interface\\Icons\\INV_Sword_01"
  end
  IsControlKeyDown = function() return opts.ctrl and true or false end
  DressUpItemLink = function(link) table.insert(tried, link) end
  ChatFrameEditBox = { IsVisible = function() return opts.chat and true or false end,
    Insert = function(self, s) table.insert(inserted, s) end }
  ZugLoot.Print = function(m) table.insert(printed, tostring(m)) end
end
resetClient()

-- 1. Hover, full link: SetHyperlink gets the BARE item string (the form
-- every working 1.12 addon uses — Bagshui/Atlas/CFMQuest/pfLoot). The
-- client resolves it from cache or queries the server.
eq(II.Hover({}, 17063, FULL), "hyper", "full link hover kind")
eq(tips[1][1], "hyper", "full link hover calls SetHyperlink")
eq(tips[1][2], "item:17063:0:0:0", "hover passes the bare item string")

-- 1b. BareLink extraction: inner portion keeps real enchant/suffix data.
eq(II.BareLink(17063, FULL), "item:17063:0:0:0", "bare link from full")
eq(II.BareLink(17063, "item:17063:0:0:0"), "item:17063:0:0:0", "bare link kept")
eq(II.BareLink(17063, nil), "item:17063:0:0:0", "bare link from id")
eq(II.BareLink(nil, "Nemesis Gloves"), nil, "bare name has no link")

-- 2. Hover, bare id of a SEEN item: bare string to the tooltip, full
-- link stashed via onLink for later shift-clicks.
tips = {}
local upgraded = nil
eq(II.Hover({}, 17063, "item:17063:0:0:0", nil,
  function(full) upgraded = full end), "hyper", "bare-id hover kind")
eq(tips[1][1], "hyper", "bare-id hover shows the item tooltip")
eq(tips[1][2], "item:17063:0:0:0", "bare-id hover passes the item string")
ok(upgraded and string.find(upgraded, "|Hitem:", 1, true), "onLink stashes the upgrade")

-- 3. Hover, bare id of an UNSEEN item: the item string STILL goes to
-- SetHyperlink — the client queries the server, so details appear even
-- with a cold cache (never a dead tooltip).
tips = {}
eq(II.Hover({}, 99999, "item:99999:0:0:0"), "hyper", "unseen hover kind")
eq(tips[1][1], "hyper", "unseen hover still calls SetHyperlink")
eq(tips[1][2], "item:99999:0:0:0", "unseen hover passes the item string")

-- 4. Hover, bare NAME (Pysanka-style call, no id at all): name + hint.
tips = {}
eq(II.Hover({}, nil, "Nemesis Gloves", "Nemesis Gloves"), "text", "bare-name hover kind")
eq(tips[1][2], "Nemesis Gloves", "bare-name hover shows the name")

-- 5. Ctrl-click: dress-up, checked before everything else.
resetClient({ ctrl = true })
eq(II.HandleClick(17063, FULL), "dressup", "ctrl-click kind")
eq(#tried, 1, "ctrl-click tries on once")
ok(string.find(tried[1], "17063", 1, true), "ctrl-click targets the item")

-- 6. Click with an open chat box: full link inserted, never a bare id.
resetClient({ chat = true })
eq(II.HandleClick(17063, "item:17063:0:0:0"), "insert", "chat click kind")
eq(#inserted, 1, "chat click inserts once")
ok(string.find(inserted[1], "|Hitem:", 1, true), "chat click inserts a full link")

-- 7. Click with no chat box open: printed instead of lost.
resetClient({})
eq(II.HandleClick(17063, FULL), "print", "no-box click kind")
eq(#printed, 1, "no-box click prints the link")

-- 8. Click on an UNSEEN bare id: nothing inserted, nothing printed.
resetClient({ chat = true })
eq(II.HandleClick(99999, "item:99999:0:0:0"), nil, "unseen click applies nothing")
eq(#inserted, 0, "unseen click inserts nothing")
eq(#printed, 0, "unseen click prints nothing")

-- 9. Wire: hover + click scripts, live state at event time (no stale
-- build-time snapshot — details/rows change under the widget).
resetClient({ chat = true })
local btn = newBtn()
local live = { itemID = 17063, link = "item:17063:0:0:0" }
II.Wire(btn, function() return live end)
ok(btn:GetScript("OnEnter"), "wire sets hover")
ok(btn:GetScript("OnLeave"), "wire sets leave")
ok(btn:GetScript("OnClick"), "wire sets click")
btn:GetScript("OnEnter")() -- bare id, seen: upgrades + full tooltip
eq(tips[1][1], "hyper", "wired hover shows the item tooltip")
live.link = FULL -- detail flipped items underneath: click reads it live
btn:GetScript("OnClick")()
eq(inserted[1], FULL, "wired click reads live state")

-- 10. Wire is nil-safe (headless/partial frames never error).
ok(II.Wire(nil, function() end) == nil, "wire nil button")
ok(II.Wire(newBtn(), nil) ~= nil, "wire nil getter keeps the button")
eq(II.Hover(nil, 17063, FULL), nil, "hover nil owner")
GameTooltip = nil
eq(II.Hover({}, 17063, FULL), nil, "hover nil tooltip")
II.Hide() -- must not error

-- Restore the client globals (no leaks into later suites).
GameTooltip = savedGlobals.GameTooltip
GetItemInfo = savedGlobals.GetItemInfo
IsControlKeyDown = savedGlobals.IsControlKeyDown
DressUpItemLink = savedGlobals.DressUpItemLink
ChatFrameEditBox = savedGlobals.ChatFrameEditBox

return T
