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
  -- NOTE: SerializeSheet lines are "Name;id:count+plus" single-entry lines.
  return table.concat(lines, "|")
end

function M.DeserializeSheet(payload)
  -- Accept raw line payload (tests) or base64-wrapped (client sends wrapped
  -- only if Base64Encode exists; skeleton client keeps it simple: raw).
  local text = payload
  -- Our SerializeSheet joins multi lines with \n; addon messages strip none.
  -- Convert single-line "a|b" fallback back to lines.
  if not string.find(text, ";") then return nil, "empty sheet" end
  if not string.find(text, "\n") and string.find(text, "|") then
    text = string.gsub(text, "|", "\n")
  end
  -- Per-name lines with single entries parse via line format.
  return Z.SRData.ParseLineFormat(text)
end

function M.ApplySheet(sheet, source, importer)
  sheet.meta.source = source
  sheet.meta.importedAt = (time and time()) or 0
  sheet.meta.importedBy = importer or (UnitName and UnitName("player")) or "?"
  sheet.meta.raidID = sheet.meta.raidID or (sheet.meta.importedBy .. "-" .. tostring(sheet.meta.importedAt))
  Z.DB.sheet = sheet
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

function M.ResetWon()
  if not Z.SRSecurity.CanImport() then
    Z.Print("Only the master looter or raid leader can reset won marks.")
    return
  end
  if Z.DB.sheet then Z.SRData.ClearWon(Z.DB.sheet) end
  Z.Print("Won marks cleared (new raid).")
  if Z.SRView then Z.SRView.Refresh() end
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
