-- ZugLoot/ItemCards.lua
-- PURE aggregation for the sheet tab: one "card" per item with everything the
-- row needs (SR list, SR+/HR flags, WON marks, roll history). No WoW API;
-- the window (MainWindow.lua) renders these. Testable under stock lua.
local M = {}

local Util
if ZugLoot and ZugLoot.Util then Util = ZugLoot.Util
else
  local ok, u = pcall(require, "Util")
  if ok then Util = u end
end

local SRData
if ZugLoot and ZugLoot.SRData then SRData = ZugLoot.SRData
else
  local ok, s = pcall(require, "SRData")
  if ok then SRData = s end
end

-- Build card list for a sheet, sorted by itemID ascending.
-- card = { itemID, quality, hardres=bool,
--          rollers = { {name, rolls, sr_plus, won} }, -- sheet order
--          rollSessions = { {t, mode, winners={names}, lines={ {name, base, sr_plus, effective, missroll, excludedWon} }} },
--          rolled = bool (any session this raid), winnerNames = {latest winners} }
function M.BuildCards(sheet)
  local cards = {}
  if not sheet then return cards end
  local ids = SRData.SortedItemIDs(sheet)
  for i = 1, Util.ArrayCount(ids) do
    local id = ids[i]
    local item = sheet.items[id] or {}
    local rollers = {}
    local src = item.rollers or {}
    for j = 1, Util.ArrayCount(src) do
      local r = src[j]
      table.insert(rollers, {
        name = r.name,
        rolls = r.rolls or 1,
        sr_plus = r.sr_plus,
        won = SRData.HasWon(sheet, id, r.name),
      })
    end
    local sessions = {}
    local hist = SRData.GetRolls(sheet, id)
    for k = 1, Util.ArrayCount(hist) do
      local h = hist[k]
      local lines = {}
      for m = 1, Util.ArrayCount(h.entries or {}) do
        local e = h.entries[m]
        table.insert(lines, {
          name = e.name, base = e.base, sr_plus = e.sr_plus or 0,
          effective = e.effective or e.base,
          missroll = e.missroll, excludedWon = e.excludedWon,
        })
      end
      table.insert(sessions, { t = h.t, mode = h.mode, winners = h.winners or {}, lines = lines })
    end
    local rolled = Util.ArrayCount(sessions) > 0
    local winnerNames = {}
    if rolled then
      local last = sessions[Util.ArrayCount(sessions)]
      for w = 1, Util.ArrayCount(last.winners or {}) do
        table.insert(winnerNames, last.winners[w])
      end
    end
    table.insert(cards, {
      itemID = id,
      quality = item.quality or 4,
      hardres = sheet.hardres and sheet.hardres[id] ~= nil,
      rollers = rollers,
      rollSessions = sessions,
      rolled = rolled,
      winnerNames = winnerNames,
    })
  end
  return cards
end

-- One-line summary per card for text render / chat fallback.
-- e.g. "item 17063 [SRx2] Blackfang x2 (+20), Carbon x1 (+130) | rolls#1: Carbon 95(+130=225), Blackfang 40(+20=60) => Carbon"
function M.CardSummary(card)
  local parts = {}
  table.insert(parts, "item " .. tostring(card.itemID))
  if card.hardres then table.insert(parts, "[HR]") end
  local rl = {}
  for i = 1, Util.ArrayCount(card.rollers) do
    local r = card.rollers[i]
    local s = r.name .. " x" .. tostring(r.rolls)
    if r.sr_plus and r.sr_plus > 0 then s = s .. " (+" .. r.sr_plus .. ")" end
    if r.won then s = s .. " [WON]" end
    table.insert(rl, s)
  end
  if Util.ArrayCount(rl) > 0 then table.insert(parts, table.concat(rl, ", ")) end
  for s = 1, Util.ArrayCount(card.rollSessions) do
    local sess = card.rollSessions[s]
    local lines = {}
    for m = 1, Util.ArrayCount(sess.lines) do
      local e = sess.lines[m]
      local t = e.name .. " " .. tostring(e.base)
      if e.sr_plus and e.sr_plus > 0 then t = t .. "(+" .. e.sr_plus .. "=" .. e.effective .. ")" end
      if e.missroll then t = t .. " [miss]" end
      if e.excludedWon then t = t .. " [already won]" end
      table.insert(lines, t)
    end
    local w = Util.ArrayCount(sess.winners) > 0 and (" => " .. table.concat(sess.winners, ",")) or ""
    table.insert(parts, "rolls#" .. s .. ": " .. table.concat(lines, ", ") .. w)
  end
  return table.concat(parts, " | ")
end

if ZugLoot then ZugLoot.ItemCards = M end
return M
