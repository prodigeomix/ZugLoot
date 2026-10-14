-- ZugLoot/SRImport.lua
-- Import UI: paste frame + Load-from-File button (CustomData/ZugLoot_SR.txt).
-- Broadcast gated to ML / raid leader+assistant.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.SRImport = M

local pasteFrame = nil
local editBox = nil

-- Serialize normalized sheet to a compact string for SHEET broadcast.
-- Format: line format (lossless for our model) — no JSON lib needed in client.
function M.SerializeSheet(sheet)
  local lines = {}
  for _, id in ipairs(Z.SRData.SortedItemIDs(sheet)) do
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
  if sheet.players then
    local pl = {}
    for name, p in pairs(sheet.players) do
      local c = type(p) == "table" and p.class or p
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
  -- Per-name lines with single entries parse via line format.
  return Z.SRData.ParseLineFormat(text)
end

function M.ApplySheet(sheet, source, importer)
  sheet.meta.source = source
  sheet.meta.importedAt = (time and time()) or 0
  sheet.meta.importedBy = importer or (UnitName and UnitName("player")) or "?"
  sheet.meta.raidID = sheet.meta.raidID or (sheet.meta.importedBy .. "-" .. tostring(sheet.meta.importedAt))
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
  -- CanImport() is true solo (preview) and for ML/leader in group.
  if not Z.SRSecurity.CanImport() then
    Z.Print("Only the master looter or raid leader/assistant can import sheets.")
    return
  end
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
    pasteFrame:SetWidth(420) pasteFrame:SetHeight(300)
    pasteFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    pasteFrame:SetMovable(true) pasteFrame:EnableMouse(true)
    pasteFrame:RegisterForDrag("LeftButton")
    pasteFrame:SetScript("OnDragStart", function() pasteFrame:StartMoving() end)
    pasteFrame:SetScript("OnDragStop", function() pasteFrame:StopMovingOrSizing() end)
    pasteFrame:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    pasteFrame:SetBackdropColor(0, 0, 0, 0.9)
    local title = pasteFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", pasteFrame, "TOP", 0, -10)
    title:SetText("ZugLoot Import")
    editBox = CreateFrame("EditBox", "ZugLootImportBox", pasteFrame)
    editBox:SetWidth(380) editBox:SetHeight(180)
    editBox:SetPoint("TOP", pasteFrame, "TOP", 0, -40)
    editBox:SetMultiLine(true) editBox:SetAutoFocus(false)
    editBox:SetFontObject(GameFontHighlightSmall)
    editBox:SetBackdrop({ bgFile = "Interface/ChatFrame/ChatFrameBackground", edgeSize = 1 })
    local importBtn = CreateFrame("Button", nil, pasteFrame, "UIPanelButtonTemplate")
    importBtn:SetWidth(120) importBtn:SetHeight(24)
    importBtn:SetPoint("BOTTOMLEFT", pasteFrame, "BOTTOMLEFT", 20, 15)
    importBtn:SetText("Import!")
    importBtn:SetScript("OnClick", function()
      if not Z.SRSecurity.CanImport() then
        Z.Print("Only the master looter or raid leader/assistant can import sheets.")
        return
      end
      M.DoPasteImport(editBox:GetText())
      pasteFrame:Hide()
    end)
    local fileBtn = CreateFrame("Button", nil, pasteFrame, "UIPanelButtonTemplate")
    fileBtn:SetWidth(150) fileBtn:SetHeight(24)
    fileBtn:SetPoint("BOTTOM", pasteFrame, "BOTTOM", 10, 15)
    fileBtn:SetText("Load from File")
    fileBtn:SetScript("OnClick", function() M.LoadFromFile() pasteFrame:Hide() end)
    local closeBtn = CreateFrame("Button", nil, pasteFrame, "UIPanelButtonTemplate")
    closeBtn:SetWidth(80) closeBtn:SetHeight(24)
    closeBtn:SetPoint("BOTTOMRIGHT", pasteFrame, "BOTTOMRIGHT", -20, 15)
    closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function() pasteFrame:Hide() end)
  end
  -- Non-privileged users may still open the frame to inspect, but Import is gated.
  pasteFrame:Show()
end
