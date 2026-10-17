-- ZugLoot/SRImport.lua
-- Import UI: paste frame (Paste button + Load-from-File) for sheets
-- (CustomData/ZugLoot_SR.txt).
-- Broadcast gated to ML / raid leader+assistant.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.SRImport = M

local pasteFrame = nil
local editBox = nil
local pasteBtn = nil

-- Test hook: live import frame (for the strata/level assert).
function M.DebugImportFrame()
  return pasteFrame
end

-- Test hook: tracked buttons of the import dialog.
function M.DebugImportButtons()
  return { paste = pasteBtn }
end

-- Test hook: live sheet edit box (for the paste assert).
function M.DebugImportBox()
  return editBox
end

-- Focus the sheet box (so Ctrl+V pastes natively) and, when a client
-- clipboard hook is present, drop the clipboard text in directly.
-- Nil-safe / headless-safe so tests can exercise the full path
-- without the client. Always focuses; empty clipboard leaves the
-- box text untouched. Returns the pasted text ("" when none).
function M.PasteClipboard()
  if editBox and editBox.SetFocus then pcall(editBox.SetFocus, editBox) end
  local clip = nil
  for i = 1, 2 do
    local probe = (i == 1) and Z.ClipboardText or GetClipboardText
    if probe then
      local ok, txt = pcall(probe)
      if ok and txt ~= nil then clip = txt break end
    end
  end
  clip = tostring(clip or "")
  if editBox and clip ~= "" and editBox.SetText then
    editBox:SetText(clip)
    if editBox.HighlightText then
      pcall(editBox.HighlightText, editBox, 0, -1)
    end
  end
  return clip
end

-- Keep the import sheet above the main window: same DIALOG strata the
-- frame already uses, but pinned to a level over the main frame (nil-
-- safe on mock frames). Called at build time and on every show, since
-- the main window rebuilds (new frame object/level) on size changes.
local function RaiseImportAboveMain()
  if not pasteFrame then return end
  if pasteFrame.SetToplevel then pcall(pasteFrame.SetToplevel, pasteFrame, true) end
  if pasteFrame.SetFrameStrata then pcall(pasteFrame.SetFrameStrata, pasteFrame, "DIALOG") end
  if pasteFrame.SetFrameLevel then
    local lvl = 100
    local main = Z.MainWindow and Z.MainWindow.frame
    if main and main.GetFrameLevel then
      local ok, ml = pcall(main.GetFrameLevel, main)
      if ok and tonumber(ml) then lvl = tonumber(ml) + 10 end
    end
    pcall(pasteFrame.SetFrameLevel, pasteFrame, lvl)
  end
  if pasteFrame.Raise then pcall(pasteFrame.Raise, pasteFrame) end
end

-- 5.0 (client) uses string.gfind, 5.1+ uses string.gmatch.
local Gfind = string.gmatch or string.gfind

-- Serialize normalized sheet to a compact string for SHEET broadcast.
-- Format: line format (lossless for our model) — no JSON lib needed in client.
-- First line is META (raid identity for the receiver's header/archive):
--   META;raidID=<id>,name=<raid name>,by=<importer>,at=<epoch>,src=<source>
-- Commas inside values are sent as %C (the line format splits PLAYERS /
-- entries on commas, and DeserializeSheet must see META first anyway).
-- Tag-less META lines are skipped by ParseLineFormat-looking parsers that
-- don't know META (unknown heads fall through harmlessly — see below).
function M.SerializeSheet(sheet)
  local lines = {}
  local meta = sheet.meta or {}
  local function mval(v)
    local s = tostring(v or "")
    s = string.gsub(s, "%%", "%%P") -- escape % first (symmetric w/ wire)
    s = string.gsub(s, ",", "%%C")
    return s
  end
  table.insert(lines, "META;raidID=" .. mval(meta.raidID)
    .. ",name=" .. mval(meta.raidName)
    .. ",by=" .. mval(meta.importedBy)
    .. ",at=" .. mval(meta.importedAt)
    .. ",src=" .. mval(meta.source))
  -- Wire order stays numeric (keepNumeric): receivers sort for display.
  for _, id in ipairs(Z.SRData.SortedCardIDs(sheet, { keepNumeric = true })) do
    local rollers = Z.SRData.GetRollers(sheet, id)
    for i = 1, Z.Util.ArrayCount(rollers) do
      local r = rollers[i]
      local plus = (r.sr_plus and r.sr_plus > 0) and ("+" .. r.sr_plus) or ""
      table.insert(lines, r.name .. ";" .. id .. ":" .. (r.rolls or 1) .. plus)
    end
  end
  local hr = {}
  for id in pairs(sheet.hardres or {}) do table.insert(hr, tostring(id)) end
  if Z.Util.ArrayCount(hr) > 0 then
    table.insert(lines, "HARDRES;" .. table.concat(hr, ","))
  end
  -- Class fallback store: one PLAYERS line keeps name->class across the
  -- broadcast (line format has no other place for it). ParseLineFormat
  -- consumes it back into sheet.players; unknown classes are skipped.
  -- Sends the RAW value when kept (spec suffix for role icons).
  if sheet.players then
    local pl = {}
    for name, p in pairs(sheet.players) do
      local c
      if type(p) == "table" then c = p.raw or p.class else c = p end
      if name and name ~= "" and c and c ~= "" then
        table.insert(pl, tostring(name) .. "=" .. tostring(c))
      end
    end
    if Z.Util.ArrayCount(pl) > 0 then
      table.sort(pl)
      table.insert(lines, "PLAYERS;" .. table.concat(pl, ","))
    end
  end
  -- NOTE: SerializeSheet lines are "Name;id:count+plus" single-entry lines.
  return table.concat(lines, "|")
end

-- Inverse of the META value escape above (%C -> comma, %P -> %). Order:
-- commas first, % last (a literal "%C" arrived as "%PC").
local function munesc(s)
  s = string.gsub(tostring(s or ""), "%%C", ",")
  s = string.gsub(s, "%%P", "%%")
  return s
end

-- Pull the META line out of a decoded sheet text. Returns meta table +
-- remaining text (META line removed). Absent META (legacy/old clients,
-- hand-written sheets): returns nil + original text — the receiver keeps
-- its fallback stamping (raidID from the message, name "—").
function M.ExtractMeta(text)
  text = tostring(text or "")
  local metaLine = string.match(text, "^META;([^\n]*)\n?")
    or string.match(text, "\nMETA;([^\n]*)")
  if not metaLine then return nil, text end
  local meta = {}
  for k, v in Gfind(metaLine, "([%w]+)=([^,]*),?") do
    if k == "raidID" then meta.raidID = munesc(v)
    elseif k == "name" then meta.raidName = munesc(v)
    elseif k == "by" then meta.importedBy = munesc(v)
    elseif k == "at" then meta.importedAt = tonumber(munesc(v)) or 0
    elseif k == "src" then meta.source = munesc(v) end
  end
  -- Strip the META line (first occurrence) so item parsing never sees it.
  local escapedMeta = string.gsub(metaLine, "(%W)", "%%%1")
  local stripped, n = string.gsub(text, "META;" .. escapedMeta, "", 1)
  if n == 0 then stripped = text end
  return meta, stripped
end

-- Decode a broadcast payload: tagged wire form (B64/ESC, see
-- Comm.EncodeSheetPayload) or legacy raw line text (old clients, tests).
-- ESC unescapes in the SAFE order: %B -> | first, %P -> % last (a
-- literal "%B" arrived as "%PB", so restoring % first would corrupt).
function M.DecodeSheetPayload(payload)
  payload = tostring(payload or "")
  if string.sub(payload, 1, 3) == "B64" then
    if not Base64Decode then return nil, "base64 sheet needs a decoder" end
    local ok, raw = pcall(Base64Decode, string.sub(payload, 4))
    if not ok or not raw or raw == "" then return nil, "bad base64 sheet" end
    return raw
  end
  local text = payload
  local tagged = string.sub(text, 1, 3) == "ESC"
  if tagged then text = string.sub(text, 4) end
  if tagged then
    -- Unescape first (%B -> |, then %P -> % — order matters, see above),
    -- THEN split rows: the wire form joins rows with "|" exactly like
    -- the legacy raw form did.
    text = string.gsub(text, "%%B", "|")
    text = string.gsub(text, "%%P", "%%")
  end
  if not string.find(text, "\n") and string.find(text, "|") then
    text = string.gsub(text, "|", "\n")
  end
  return text
end
function M.DeserializeSheet(payload)
  local text, err = M.DecodeSheetPayload(payload)
  if not text then return nil, err end
  if not string.find(text, ";") then return nil, "empty sheet" end
  -- META envelope first (raid identity for the receiver's header):
  -- parsed aside, stripped from the item text.
  local meta, rest = M.ExtractMeta(text)
  -- Per-name lines with single entries parse via line format.
  local sheet, perr = Z.SRData.ParseLineFormat(rest)
  if not sheet then return nil, perr end
  if meta then
    sheet.meta = sheet.meta or {}
    -- Envelope wins only where it actually carries a value (empty =
    -- unknown, keep the parse defaults, not blank strings).
    if meta.raidID and meta.raidID ~= "" then sheet.meta.raidID = meta.raidID end
    if meta.raidName and meta.raidName ~= "" then sheet.meta.raidName = meta.raidName end
    if meta.importedBy and meta.importedBy ~= "" then sheet.meta.importedBy = meta.importedBy end
    if meta.importedAt and meta.importedAt ~= 0 then sheet.meta.importedAt = meta.importedAt end
    if meta.source and meta.source ~= "" then sheet.meta.source = meta.source end
  end
  return sheet, nil
end

-- Should this incoming sheet replace the live one? Same raid (by raidID)
-- compares CONTENT revision, not the raid: importedAt is the revision
-- stamp (export time on raidres, import time for line format). Older or
-- equal revisions are stale — importing/syncing an old export over a
-- newer update must never roll the raid back. Different raidID (or no
-- live sheet): always accept.
function M.SheetIsStale(cur, incoming)
  if not cur or not cur.meta or not cur.meta.raidID then return false end
  if not incoming or not incoming.meta then return false end
  if incoming.meta.raidID ~= cur.meta.raidID then return false end
  local curAt = tonumber(cur.meta.importedAt) or 0
  local newAt = tonumber(incoming.meta.importedAt) or 0
  return newAt <= curAt
end

function M.ApplySheet(sheet, source, importer)
  sheet.meta = sheet.meta or {}
  -- Revision stamp: a known export time (raidres metadata) wins; line
  -- format and timestamp-less exports stamp NOW. Either way the stale
  -- check below compares real revisions, never import order.
  if not sheet.meta.importedAt or sheet.meta.importedAt == 0 then
    sheet.meta.importedAt = (time and time()) or 0
  end
  sheet.meta.source = source
  sheet.meta.importedBy = importer or (UnitName and UnitName("player")) or "?"
  sheet.meta.raidID = sheet.meta.raidID or (sheet.meta.importedBy .. "-" .. tostring(sheet.meta.importedAt))
  -- Same raid, older-or-equal revision: stale. Refuse BEFORE archiving
  -- (archiving first would snapshot live progress, then drop it).
  if M.SheetIsStale(Z.DB and Z.DB.sheet, sheet) then
    Z.Print("Ignored stale sheet for " .. tostring(sheet.meta.raidID)
      .. " (a newer update is already applied).")
    return false
  end
  -- Keep the outgoing raid around: archive it before replacing.
  if Z.RaidArchive then
    Z.RaidArchive.ArchiveActive(Z.DB, (time and time()) or 0)
  end
  Z.DB.sheet = sheet
  -- List the new raid immediately, even though it was never unloaded.
  if Z.RaidArchive then
    Z.RaidArchive.SyncActive(Z.DB, (time and time()) or 0)
  end
  if Z.SRView then Z.SRView.Refresh() end
  local nItems = Z.Util.TableCount(sheet.items)
  local canBC = Z.SRSecurity and Z.SRSecurity.CanBroadcast and Z.SRSecurity.CanBroadcast()
  if canBC then
    Z.Print("Sheet imported (" .. source .. "): " .. nItems .. " items. Broadcasting...")
    if Z.Comm then Z.Comm.BroadcastSheet(sheet, sheet.meta.raidID) end
  else
    Z.Print("Sheet loaded locally (" .. source .. "): " .. nItems .. " items. Solo preview — joins a group to broadcast.")
  end
  if Z.DropLog then Z.DropLog.Add(nil, nil, "sheet", "import", sheet.meta.importedBy) end
end

-- Accept either format: raidres export blob (base64/json) or static line format.
-- Used by both paste import and Load from File.
function M.ParseAnyImport(text)
  local sheet, err = Z.SRData.ParseRaidResExport(text)
  if not sheet then
    sheet, err = Z.SRData.ParseLineFormat(text)
  end
  return sheet, err
end

function M.DoPasteImport(text)
  local sheet, err = M.ParseAnyImport(text)
  if not sheet then
    Z.Print("Import failed: " .. tostring(err))
    return
  end
  M.ApplySheet(sheet, "paste")
end

function M.LoadFromFile()
  -- Anyone may import (local view only; broadcast stays ML/leader).
  -- CanImport() is therefore always true; kept for API shape.
  local text, err = Z.FileIO.ReadSRFile()
  if not text then
    Z.Print("Load from file failed: " .. tostring(err))
    return
  end
  local sheet, perr = M.ParseAnyImport(text)
  if not sheet then
    Z.Print("File parse failed: " .. tostring(perr))
    return
  end
  M.ApplySheet(sheet, "file")
end

-- Permission for clearing the roll log (rolls history + won marks).
-- Solo: always allowed (local preview data only). In party/raid: only the
-- master looter or raid leader/assistant. Testable: no WoW UI calls.
function M.CanResetRollLog()
  if not Z.SRSecurity then return false end
  if Z.SRSecurity.IsSolo and Z.SRSecurity.IsSolo() then return true end
  return Z.SRSecurity.CanBroadcast and Z.SRSecurity.CanBroadcast()
end

-- Perform the clear. No permission check, no UI — testable core.
-- Returns counts for feedback. Safe with no sheet loaded.
function M.DoResetRollLog()
  local sheet = Z.DB and Z.DB.sheet
  if not sheet then return { rolls = 0, won = 0 } end
  -- Count sessions before clearing (won entries counted per item).
  local nRolls, nWon = 0, 0
  if sheet.rolls then
    for _, hist in pairs(sheet.rolls) do
      nRolls = nRolls + Z.Util.ArrayCount(hist)
    end
  end
  if sheet.won then
    for _, w in pairs(sheet.won) do
      nWon = nWon + Z.Util.TableCount(w)
    end
  end
  -- Sim sessions write into the same history/won marks, so a fresh raid
  -- clears both. Unreserved stubs are roll-session artifacts too: prune them
  -- so the sheet returns to its imported state.
  Z.SRData.ClearWon(sheet)
  if Z.SRData.ClearRolls then Z.SRData.ClearRolls(sheet) end
  if Z.SRData.PruneUnreserved then Z.SRData.PruneUnreserved(sheet) end
  return { rolls = nRolls, won = nWon }
end

local function refreshViews()
  if Z.MainWindow then Z.MainWindow.Refresh() end
  if Z.SRView then Z.SRView.Refresh() end
end

-- Button/slash entry point: permission gate + confirmation window.
-- Outside the client (no StaticPopup API) the confirm is skipped so tests
-- can exercise the full path.
function M.RequestResetRollLog()
  if not M.CanResetRollLog() then
    Z.Print("Only the master looter or raid leader can reset the roll log.")
    return
  end
  if not (StaticPopupDialogs and StaticPopup_Show) then
    local c = M.DoResetRollLog()
    Z.Print("Roll log cleared (" .. c.rolls .. " sessions, " .. c.won .. " won marks).")
    refreshViews()
    return
  end
  StaticPopupDialogs["ZUGLOOT_RESET_ROLLS"] = StaticPopupDialogs["ZUGLOOT_RESET_ROLLS"] or {
    text = "Clear the roll log?\nAll recorded rolls and won marks for this raid will be removed. The SR sheet itself is kept.",
    button1 = "Reset", button2 = "Cancel",
    OnAccept = function()
      local c = M.DoResetRollLog()
      Z.Print("Roll log cleared (" .. c.rolls .. " sessions, " .. c.won .. " won marks).")
      refreshViews()
    end,
    timeout = 0, whileDead = 1,
  }
  StaticPopup_Show("ZUGLOOT_RESET_ROLLS")
end

-- Switch the live sheet to an archived raid (view its details or continue
-- where it left off: won marks + roll history come along). The outgoing
-- sheet is archived first so no progress is lost. No import permission
-- needed: this only rearranges local snapshots, never pulls in new data.
function M.ActivateArchivedRaid(raidID)
  if not Z.RaidArchive then return end
  if not raidID then Z.Print("Usage: /zl raid <raidID> (see the Raids tab)") return end
  local cur = Z.DB and Z.DB.sheet and Z.DB.sheet.meta and Z.DB.sheet.meta.raidID
  if cur == raidID then
    Z.Print(tostring(raidID) .. " is already the active sheet.")
    if Z.MainWindow then Z.MainWindow.Refresh() end
    return
  end
  Z.RaidArchive.ArchiveActive(Z.DB, (time and time()) or 0)
  local sheet, err = Z.RaidArchive.RestoreSheet(Z.DB, raidID)
  if not sheet then
    Z.Print("Activate failed: " .. tostring(err))
    return
  end
  local nItems = Z.Util.TableCount(sheet.items)
  local nSess = Z.RaidArchive.CountSessions(sheet)
  Z.Print("Active sheet: " .. tostring(raidID) .. " (" .. nItems .. " items, " .. nSess .. " past sessions). Previous sheet archived.")
  if Z.MainWindow then Z.MainWindow.Refresh() end
  if Z.SRView then Z.SRView.Refresh() end
  if Z.DropLog then Z.DropLog.Add(nil, nil, "raid", "activate", tostring(raidID)) end
end

function M.ResetWon()
  -- /zl reset keeps its direct behavior (slash, no popup) but shares the
  -- permission gate and clearing core with the button path.
  if not M.CanResetRollLog() then
    Z.Print("Only the master looter or raid leader can reset won marks.")
    return
  end
  local c = M.DoResetRollLog()
  Z.Print("Won marks and roll history cleared (new raid): " .. c.rolls .. " sessions, " .. c.won .. " won marks.")
  refreshViews()
end

function M.ShowPaste()
  if not pasteFrame then
    pasteFrame = CreateFrame("Frame", "ZugLootImportFrame", UIParent)
    pasteFrame:SetWidth(560) pasteFrame:SetHeight(460)
    pasteFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    pasteFrame:SetMovable(true) pasteFrame:EnableMouse(true)
    pasteFrame:RegisterForDrag("LeftButton")
    pasteFrame:SetScript("OnDragStart", function() pasteFrame:StartMoving() end)
    pasteFrame:SetScript("OnDragStop", function() pasteFrame:StopMovingOrSizing() end)
    if pasteFrame.SetResizable then pasteFrame:SetResizable(true) end
    if pasteFrame.SetMinResize then pasteFrame:SetMinResize(420, 320) end
    if pasteFrame.SetClampedToScreen then pasteFrame:SetClampedToScreen(true) end
    -- Above the main window (DIALOG strata + level over the main frame),
    -- or the sheet slides under the window and cannot be clicked.
    RaiseImportAboveMain()
    pasteFrame:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    pasteFrame:SetBackdropColor(0, 0, 0, 0.9)
    local title = pasteFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", pasteFrame, "TOP", 0, -10)
    title:SetText("ZugLoot Import")
    -- Text lives inside a clipping ScrollFrame whose bottom edge stops
    -- above the button strip, so long pastes scroll instead of painting
    -- over the buttons (the old fixed-height EditBox drew past its rect).
    local scroll = CreateFrame("ScrollFrame", "ZugLootImportScroll", pasteFrame)
    scroll:SetPoint("TOPLEFT", pasteFrame, "TOPLEFT", 20, -40)
    scroll:SetPoint("BOTTOMRIGHT", pasteFrame, "BOTTOMRIGHT", -38, 55)
    scroll:EnableMouseWheel(true)
    scroll:SetBackdrop({ bgFile = "Interface/ChatFrame/ChatFrameBackground", edgeSize = 1 })
    editBox = CreateFrame("EditBox", "ZugLootImportBox", scroll)
    if editBox.SetMultiLine then editBox:SetMultiLine(true) end
    if editBox.SetAutoFocus then editBox:SetAutoFocus(false) end
    if editBox.EnableMouse then editBox:EnableMouse(true) end
    if editBox.SetFontObject and GameFontHighlightSmall then editBox:SetFontObject(GameFontHighlightSmall) end
    if editBox.SetJustifyH then editBox:SetJustifyH("LEFT") end
    if editBox.SetJustifyV then editBox:SetJustifyV("TOP") end
    editBox:SetWidth(480) editBox:SetHeight(200)
    editBox:SetText("")
    if editBox.SetMaxLetters then editBox:SetMaxLetters(0) end
    scroll:SetScrollChild(editBox)
    local sb = CreateFrame("Slider", "ZugLootImportBar", pasteFrame, "UIPanelScrollBarTemplate")
    sb:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, -16)
    sb:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 16)
    local upB = getglobal and getglobal("ZugLootImportBarScrollUpButton")
    local dnB = getglobal and getglobal("ZugLootImportBarScrollDownButton")
    if upB and upB.Hide then upB:Hide() end
    if dnB and dnB.Hide then dnB:Hide() end
    if sb.SetThumbTexture then sb:SetThumbTexture("Interface\\Buttons\\WHITE8X8") end
    local th = sb.GetThumbTexture and sb:GetThumbTexture()
    if th then
      if th.SetWidth then th:SetWidth(6) end
      if th.SetHeight then th:SetHeight(24) end
      if th.SetVertexColor then th:SetVertexColor(0.42, 0.43, 0.48, 0.95) end
    end
    if sb.SetMinMaxValues then sb:SetMinMaxValues(0, 0) end
    if sb.SetValueStep then sb:SetValueStep(24) end
    if sb.SetValue then sb:SetValue(0) end
    local function SyncImportScroll()
      if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
      if sb and sb.SetMinMaxValues and scroll.GetVerticalScrollRange then
        local range = scroll:GetVerticalScrollRange()
        if not range or range < 0 then range = 0 end
        sb:SetMinMaxValues(0, range)
      end
    end
    sb:SetScript("OnValueChanged", function()
      if scroll.SetVerticalScroll and sb.GetValue then scroll:SetVerticalScroll(sb:GetValue()) end
    end)
    if scroll.SetScript then
      scroll:SetScript("OnVerticalScroll", function()
        if sb.SetValue and scroll.GetVerticalScroll then sb:SetValue(scroll:GetVerticalScroll()) end
      end)
      scroll:SetScript("OnMouseWheel", function()
        local mn, mx = 0, 0
        if sb.GetMinMaxValues then mn, mx = sb:GetMinMaxValues() end
        local v = 0
        if sb.GetValue then v = sb:GetValue() end
        v = v - ((arg1 or 0) * 32)
        if v < mn then v = mn elseif v > mx then v = mx end
        if sb.SetValue then sb:SetValue(v) end
      end)
      scroll:SetScript("OnSizeChanged", function() SyncImportScroll() end)
    end
    editBox:SetScript("OnTextChanged", function() SyncImportScroll() end)
    editBox:SetScript("OnCursorChanged", function() SyncImportScroll() end)
    editBox:SetScript("OnEscapePressed", function() pasteFrame:Hide() end)
    -- Buttons sit in their own strip below the scroll rect and above it
    -- in frame level, so they stay visible and clickable at any size.
    local baseLvl = 5
    if pasteFrame.GetFrameLevel then baseLvl = pasteFrame:GetFrameLevel() + 2 end
    local importBtn = CreateFrame("Button", nil, pasteFrame, "UIPanelButtonTemplate")
    importBtn:SetWidth(120) importBtn:SetHeight(24)
    importBtn:SetPoint("BOTTOMLEFT", pasteFrame, "BOTTOMLEFT", 20, 15)
    importBtn:SetText("Import!")
    if importBtn.SetFrameLevel then importBtn:SetFrameLevel(baseLvl) end
    importBtn:SetScript("OnClick", function()
      -- Anyone may import (local view only; broadcast stays ML/leader).
      M.DoPasteImport(editBox:GetText())
      pasteFrame:Hide()
    end)
    local fileBtn = CreateFrame("Button", nil, pasteFrame, "UIPanelButtonTemplate")
    fileBtn:SetWidth(150) fileBtn:SetHeight(24)
    fileBtn:SetPoint("BOTTOM", pasteFrame, "BOTTOM", 10, 15)
    fileBtn:SetText("Load from File")
    if fileBtn.SetFrameLevel then fileBtn:SetFrameLevel(baseLvl) end
    fileBtn:SetScript("OnClick", function() M.LoadFromFile() pasteFrame:Hide() end)
    local closeBtn = CreateFrame("Button", nil, pasteFrame, "UIPanelButtonTemplate")
    closeBtn:SetWidth(80) closeBtn:SetHeight(24)
    closeBtn:SetPoint("BOTTOMRIGHT", pasteFrame, "BOTTOMRIGHT", -20, 15)
    closeBtn:SetText("Close")
    if closeBtn.SetFrameLevel then closeBtn:SetFrameLevel(baseLvl) end
    closeBtn:SetScript("OnClick", function() pasteFrame:Hide() end)
    -- Paste lives top-right, above the scroll rect: the bottom strip
    -- (Import! / Load from File / Close) is already full, and a fourth
    -- button there crowds the resize grip. Click focuses the box (so
    -- Ctrl+V pastes natively) and drops the clipboard text in when a
    -- client hook provides it; empty clipboard leaves text untouched.
    pasteBtn = CreateFrame("Button", nil, pasteFrame, "UIPanelButtonTemplate")
    pasteBtn:SetWidth(80) pasteBtn:SetHeight(20)
    pasteBtn:SetPoint("TOPRIGHT", pasteFrame, "TOPRIGHT", -20, -8)
    pasteBtn:SetText("Paste")
    if pasteBtn.SetFrameLevel then pasteBtn:SetFrameLevel(baseLvl) end
    pasteBtn:SetScript("OnClick", function() M.PasteClipboard() end)
    -- Resize grip: drag the corner to grow/shrink; the scroll rect
    -- follows via anchors and the edit width follows the scroll.
    local grip = CreateFrame("Button", nil, pasteFrame)
    grip:SetWidth(16) grip:SetHeight(16)
    grip:SetPoint("BOTTOMRIGHT", pasteFrame, "BOTTOMRIGHT", -4, 4)
    grip:EnableMouse(true)
    if grip.SetNormalTexture then
      grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    end
    grip:SetScript("OnMouseDown", function()
      if pasteFrame.StartSizing then pasteFrame:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function()
      if pasteFrame.StopMovingOrSizing then pasteFrame:StopMovingOrSizing() end
    end)
    if grip.SetFrameLevel then grip:SetFrameLevel(baseLvl) end
    pasteFrame:SetScript("OnSizeChanged", function()
      if scroll.GetWidth and editBox.SetWidth then
        local w = scroll:GetWidth()
        if w and w > 40 then editBox:SetWidth(w) end
      end
      SyncImportScroll()
    end)
    if scroll.GetWidth and editBox.SetWidth then
      local w0 = scroll:GetWidth()
      if w0 and w0 > 40 then editBox:SetWidth(w0) end
    end
    SyncImportScroll()
  end
  -- Non-privileged users may still open the frame to inspect, but Import is gated.
  -- Re-pin on every show: the main window rebuilds on size changes, and a
  -- fresh main frame would otherwise reclaim the top spot.
  RaiseImportAboveMain()
  pasteFrame:Show()
end
