-- ZugLoot/SRImport.lua
-- Import UI: paste frame + Load-from-File button (CustomData/ZugLoot_SR.txt).
-- Broadcast gated to ML / raid leader+assistant.
ZugLoot = ZugLoot or {}
local Z = ZugLoot
local M = {}
Z.SRImport = M

local pasteFrame = nil
local editBox = nil
local importScroll = nil
local importBorder = nil
local importHintText = nil
local importHintTex = nil

-- Static sheet box geometry: fixed width, ~10 lines tall. Neither
-- the box nor the dialog ever resizes; long pastes scroll inside.
M.IMPORT_BOX_W = 502
M.IMPORT_BOX_H = 150

-- Raidres hint below the box: captioned screenshot showing the two
-- "RollFor export" buttons. Baked 512x512 uncompressed TGA (client-
-- readable); live content occupies the top 271px, cropped at show
-- time via SetTexCoord and displayed at full box width (502x266).
M.HINT_IMAGE = "Interface\\AddOns\\ZugLoot\\Media\\ZL-RollForHint.tga"
M.HINT_TEX_BOTTOM = 271 / 512
M.HINT_IMG_W = 502
M.HINT_IMG_H = 266

-- Test hook: live import frame (for the strata/level assert).
function M.DebugImportFrame()
  return pasteFrame
end

-- Test hook: live hint text + hint image (caption/screenshot asserts).
function M.DebugImportHint()
  return importHintText, importHintTex
end

-- Test hook: live sheet edit box + its scroll frame + the border frame
-- (geometry/focus asserts).
function M.DebugImportBox()
  return editBox
end
function M.DebugImportScroll()
  return importScroll
end
function M.DebugImportBorder()
  return importBorder
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

-- Progress escaping for the ROLLH/WON line tails below. Player names are
-- letters-only on the client, but the tails split on , ; : + — so names
-- carrying any of those (hand-made tests, fuzz) are escaped %X-style.
-- Encode: % first, then the delimiters. Decode: reverse (single-letter
-- codes, %P -> % LAST — a literal "%C" arrived as "%PC").
-- Layers with the outer ESC escape (% -> %P, | -> %B): inner "%C"
-- becomes "%PC" on the wire, outer decode restores "%C" first, then
-- the inner decode below restores "," — same layering META relies on.
local function pesc(s)
  s = tostring(s or "")
  s = string.gsub(s, "%%", "%%P")
  s = string.gsub(s, "|", "%%B")
  s = string.gsub(s, ",", "%%C")
  s = string.gsub(s, ";", "%%S")
  s = string.gsub(s, ":", "%%N")
  s = string.gsub(s, "%+", "%%A")
  return s
end
local function punesc(s)
  s = tostring(s or "")
  s = string.gsub(s, "%%A", "+")
  s = string.gsub(s, "%%N", ":")
  s = string.gsub(s, "%%S", ";")
  s = string.gsub(s, "%%C", ",")
  s = string.gsub(s, "%%B", "|")
  s = string.gsub(s, "%%P", "%%")
  return s
end

local ROLLTYPE_LETTER = { SR = "S", MS = "M", OS = "O", TMOG = "T" }
local LETTER_ROLLTYPE = { S = "SR", M = "MS", O = "OS", T = "TMOG" }

-- Single progress-name unescape for the WON line parser (SRData owns
-- the sheet, SRImport owns the wire escaping).
function M.DecodeSessionName(s) return punesc(s) end

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
  -- Unreserved stubs (rolled but never SR'd): UNSR;<id>:q<quality>,...
  -- (ids numeric ascending). Stubs carry no rollers, so the item loop
  -- above emits nothing for them — without this line they (and their
  -- sessions/marks) would land invisibly on receivers. The :q marker
  -- keeps stub parts unambiguous against player id:count entries.
  -- Quality rides along for the card color (q0 = unknown, default).
  do
    local ids = {}
    for id, item in pairs(sheet.items or {}) do
      if type(item) == "table" and item.unsr == true then
        table.insert(ids, tonumber(id) or id)
      end
    end
    if Z.Util.ArrayCount(ids) > 0 then
      table.sort(ids)
      local up = {}
      for i = 1, Z.Util.ArrayCount(ids) do
        local id = ids[i]
        local q = sheet.items[id] and sheet.items[id].quality or nil
        table.insert(up, tostring(id) .. ":q" .. tostring(tonumber(q) or 0))
      end
      table.insert(lines, "UNSR;" .. table.concat(up, ","))
    end
  end
  -- Won marks: WON;<id>=<name>+<name>,... (ids numeric ascending).
  -- Receivers mirror them straight onto sheet.won (the sender already
  -- applied the log floor, so no quality check on receive).
  if sheet.won then
    local ids = {}
    for id in pairs(sheet.won) do table.insert(ids, tonumber(id) or id) end
    table.sort(ids)
    local wp = {}
    for i = 1, Z.Util.ArrayCount(ids) do
      local id = ids[i]
      local names = {}
      for nm in pairs(sheet.won[id] or {}) do
        if nm and nm ~= "" then table.insert(names, pesc(nm)) end
      end
      if Z.Util.ArrayCount(names) > 0 then
        table.sort(names)
        table.insert(wp, tostring(id) .. "=" .. table.concat(names, "+"))
      end
    end
    if Z.Util.ArrayCount(wp) > 0 then
      table.insert(lines, "WON;" .. table.concat(wp, ","))
    end
  end
  -- Roll history: one ROLLH;<session tail> line per recorded session
  -- (ids numeric ascending, sessions in record order) so a synced sheet
  -- shows what was rolled, not just the reservations.
  if sheet.rolls then
    local ids = {}
    for id in pairs(sheet.rolls) do table.insert(ids, tonumber(id) or id) end
    table.sort(ids)
    for i = 1, Z.Util.ArrayCount(ids) do
      local hist = sheet.rolls[ids[i]]
      for s = 1, Z.Util.ArrayCount(hist or {}) do
        local tail = M.EncodeSession(ids[i], hist[s])
        if tail then table.insert(lines, "ROLLH;" .. tail) end
      end
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



-- Encode one roll session to its wire tail (shared by the ROLLH sheet
-- lines and the ROLLLOG delta message):
--   <itemID>,<t>,<mode>,<w1>+<w2>,<name>:<base>:<eff>:<T>:<plus>:<flags>,...
-- T is the single-letter kind; flags concatenate m (missroll),
-- x (won-excluded), o (over cap). No winners encodes as "-" (a bare
-- name can never be "-", and Split drops empty fields — positions
-- must never go missing). Numbers fall back to 0 on decode.
function M.EncodeSession(itemID, sess)
  if not itemID or not sess then return nil end
  local winners = sess.winners or {}
  local wtxt = "-"
  if Z.Util.ArrayCount(winners) > 0 then
    local w = {}
    for i = 1, Z.Util.ArrayCount(winners) do
      table.insert(w, pesc(winners[i]))
    end
    wtxt = table.concat(w, "+")
  end
  local parts = { tostring(itemID), tostring(sess.t or 0),
    pesc(sess.mode or "SR"), wtxt }
  for i = 1, Z.Util.ArrayCount(sess.entries or {}) do
    local e = sess.entries[i]
    if e and e.name and e.name ~= "" then
      local flags = (e.missroll and "m" or "")
        .. (e.excludedWon and "x" or "")
        .. (e.overCap and "o" or "")
      local base = tonumber(e.base) or 0
      local eff = tonumber(e.effective) or base
      table.insert(parts, pesc(e.name) .. ":" .. base .. ":" .. eff .. ":"
        .. (ROLLTYPE_LETTER[e.rollType] or "M") .. ":"
        .. (tonumber(e.sr_plus) or 0) .. ":" .. flags)
    end
  end
  return table.concat(parts, ",")
end

-- Inverse of EncodeSession: tail -> itemID, session table (shape matches
-- Resolver.ToHistoryEntry minus missrolls/excluded counts, which the
-- item log never displays). STRICT: malformed tails return nil, so the
-- line-format parser can fall back to the player path (a hand-written
-- line for someone named "Rollh" must never be eaten — e.g.
-- Rollh;1001,1002,1003,1004 is four bare reservations, not a session:
-- field 3 is numeric, while genuine modes always contain a letter).
function M.DecodeSession(tail)
  local parts = Z.Util.Split(tostring(tail or ""), ",")
  if Z.Util.ArrayCount(parts) < 4 then return nil end
  local itemID = tonumber(parts[1])
  if not itemID then return nil end
  if not string.find(tostring(parts[3] or ""), "%a") then return nil end
  if (parts[4] or "") == "" then return nil end
  local winners = {}
  if parts[4] ~= "-" and parts[4] ~= "" then
    for _, w in ipairs(Z.Util.Split(parts[4], "+")) do
      local nm = punesc(w)
      if nm ~= "" then table.insert(winners, nm) end
    end
  end
  local entries = {}
  for i = 5, Z.Util.ArrayCount(parts) do
    local f = Z.Util.Split(parts[i], ":")
    local nm = punesc(f[1] or "")
    if nm ~= "" then
      local base = tonumber(f[2]) or 0
      local flags = tostring(f[6] or "")
      table.insert(entries, { name = nm, base = base,
        effective = tonumber(f[3]) or base,
        rollType = LETTER_ROLLTYPE[f[4]] or "MS",
        sr_plus = tonumber(f[5]) or 0,
        missroll = string.find(flags, "m", 1, true) and true or nil,
        excludedWon = string.find(flags, "x", 1, true) and true or nil,
        overCap = string.find(flags, "o", 1, true) and true or nil })
    end
  end
  return itemID, { t = tonumber(parts[2]) or 0, mode = punesc(parts[3]),
    winners = winners, entries = entries, missrolls = 0, excluded = {} }
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
  if not sheet then
    Z.Print("Import failed: no sheet data.")
    return false
  end
  -- Refuse empty imports BEFORE stamping/archiving: a blank paste or an
  -- empty export must never clobber the live sheet — or broadcast as
  -- "(sheet is empty)" to the raid.
  if Z.SRData and Z.SRData.SheetIsEmpty and Z.SRData.SheetIsEmpty(sheet) then
    Z.Print("Import failed: sheet has no reservations (0 items, no hard reserves) — "
      .. "check the pasted text is the full RollFor export from raidres. "
      .. "Live sheet kept.")
    return false
  end
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

-- Accept the raidres RollFor export blob (base64/json) or the static
-- line format. CSV is NOT accepted: CSV-looking input is refused with
-- a pointer at the RollFor export. Used by paste import + Load from File.
function M.ParseAnyImport(text)
  local sheet, rrErr = Z.SRData.ParseRaidResExport(text)
  if sheet then return sheet, nil end
  -- A paste carrying a raidres payload candidate (JSON / long-base64
  -- line) was *trying* to be a RollFor export: report the specific
  -- raidres error (truncated, bad JSON, unsupported encoding) and NEVER
  -- fall through to CSV/line format — whose "missing ';'" is
  -- misleading here (';' is not valid base64). CSV import stays
  -- disabled, so this path must not reach the CSV parser either.
  -- Short fragments (a truncated copy, a partial line) have no payload
  -- line but are clearly not line format either: a single `;`-less line
  -- in the base64 alphabet is a broken RollFor copy, not a hand-written
  -- sheet, so the raidres error wins there too. (Minimum length keeps
  -- trivial words like "hello" on the line-format path.)
  local isCandidate = Z.SRData.ExtractPayload and Z.SRData.ExtractPayload(text)
  if not isCandidate then
    local t = (Z.Util and Z.Util.Trim and Z.Util.Trim(text)) or tostring(text or "")
    local stripped = string.gsub(t, "%s", "")
    local hasHeader = Z.SRData.HasCSVHeader and Z.SRData.HasCSVHeader(text)
    if not hasHeader
      and string.len(stripped) >= 16
      and not string.find(t, ";", 1, true)
      and not string.find(t, "\n")
      and string.find(stripped, "^[A-Za-z0-9+/=]+$") then
      isCandidate = true
    end
  end
  if isCandidate then
    return nil, rrErr
  end
  -- A CSV whose header matched must report the RollFor-only rule — NOT
  -- fall through to a confusing line-format error like "line 1: missing ';'".
  if Z.SRData.HasCSVHeader and Z.SRData.HasCSVHeader(text) then
    return nil, "only RollFor export is supported — paste the RollFor export "
      .. "from raidres (CSV imports are disabled)"
  end
  return Z.SRData.ParseLineFormat(text)
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

-- Delete one archived raid (Raids tab Delete button, /zl raidforget).
-- Testable core: no permission check, no UI. Refuses the ACTIVE raid
-- (deleting the live sheet out from under the raid would strand every
-- window — activate another raid first) and unknown ids. Returns true
-- on delete, false otherwise. Local snapshots only: never touches the
-- network, so no broadcast permission needed.
function M.DoDeleteArchivedRaid(raidID)
  if not Z.RaidArchive then return false end
  if not raidID or raidID == "" then
    Z.Print("Usage: /zl raidforget <raidID> (see the Raids tab)")
    return false
  end
  local cur = Z.DB and Z.DB.sheet and Z.DB.sheet.meta and Z.DB.sheet.meta.raidID
  if cur == raidID then
    Z.Print("Can't delete the active raid (" .. tostring(raidID)
      .. ") — activate another raid first, then delete this one.")
    return false
  end
  if not Z.RaidArchive.Forget(Z.DB, raidID) then
    Z.Print("Delete failed: no archived raid " .. tostring(raidID) .. ".")
    return false
  end
  Z.Print("Deleted archived raid " .. tostring(raidID) .. ".")
  refreshViews()
  if Z.DropLog then Z.DropLog.Add(nil, nil, "raid", "delete", tostring(raidID)) end
  return true
end

-- Button/slash entry point with confirmation window. Outside the
-- client (no StaticPopup API) the confirm is skipped so tests can
-- exercise the full path (same shape as RequestResetRollLog).
function M.RequestDeleteArchivedRaid(raidID)
  if not raidID or raidID == "" then
    Z.Print("Usage: /zl raidforget <raidID> (see the Raids tab)")
    return
  end
  if not (StaticPopupDialogs and StaticPopup_Show) then
    M.DoDeleteArchivedRaid(raidID)
    return
  end
  StaticPopupDialogs["ZUGLOOT_DELETE_RAID"] = StaticPopupDialogs["ZUGLOOT_DELETE_RAID"] or {
    text = "Delete this archived raid?\nIts sheet, roll history and won marks will be permanently removed. This cannot be undone.",
    button1 = "Delete", button2 = "Cancel",
    OnAccept = function()
      M.DoDeleteArchivedRaid(raidID)
    end,
    timeout = 0, whileDead = 1,
  }
  StaticPopup_Show("ZUGLOOT_DELETE_RAID")
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
    pasteFrame:SetWidth(560) pasteFrame:SetHeight(540)
    pasteFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    pasteFrame:SetMovable(true) pasteFrame:EnableMouse(true)
    pasteFrame:RegisterForDrag("LeftButton")
    pasteFrame:SetScript("OnDragStart", function() pasteFrame:StartMoving() end)
    pasteFrame:SetScript("OnDragStop", function() pasteFrame:StopMovingOrSizing() end)
    -- Fixed-size dialog: no resize grip, no anchors that stretch.
    -- The sheet box is a static input; the frame never grows it.
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
    -- Static sheet box: the BORDER lives on its own backdrop frame
    -- (NOT on the EditBox: InputBoxTemplate is a single-line skin and
    -- smears when stretched tall), and the scroll area sits 10px
    -- inside that border on all sides. Text insets alone can't contain
    -- the text: a pasted base64 blob is one unbreakable line, so rows
    -- can render flush to the scroll child's edges — the 10px moat
    -- keeps every glyph off the edge decorations regardless. All
    -- static sizes; long pastes scroll inside, nothing ever grows.
    -- Clicking anywhere (text or moat ring) focuses the box for Ctrl+V.
    local borderF = CreateFrame("Frame", "ZugLootImportBorder", pasteFrame)
    borderF:SetPoint("TOPLEFT", pasteFrame, "TOPLEFT", 20, -40)
    borderF:SetWidth(M.IMPORT_BOX_W)
    borderF:SetHeight(M.IMPORT_BOX_H)
    borderF:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    borderF:SetBackdropColor(0.05, 0.05, 0.05, 1)
    borderF:EnableMouse(true)
    importBorder = borderF
    local scroll = CreateFrame("ScrollFrame", "ZugLootImportScroll", borderF)
    scroll:SetPoint("TOPLEFT", borderF, "TOPLEFT", 10, -10)
    scroll:SetWidth(M.IMPORT_BOX_W - 20)
    scroll:SetHeight(M.IMPORT_BOX_H - 20)
    scroll:EnableMouse(true)
    scroll:EnableMouseWheel(true)
    editBox = CreateFrame("EditBox", "ZugLootImportBox", scroll)
    if editBox.SetMultiLine then editBox:SetMultiLine(true) end
    if editBox.SetAutoFocus then editBox:SetAutoFocus(false) end
    if editBox.EnableMouse then editBox:EnableMouse(true) end
    if editBox.SetFontObject and GameFontHighlightSmall then editBox:SetFontObject(GameFontHighlightSmall) end
    if editBox.SetJustifyH then editBox:SetJustifyH("LEFT") end
    -- Belt and braces inside the moat: the scroll frame owns the
    -- scroll child's position (SetPoint on it is ignored), so inner
    -- padding comes from text insets.
    editBox:SetWidth(M.IMPORT_BOX_W - 24) editBox:SetHeight(M.IMPORT_BOX_H - 20)
    if editBox.SetTextInsets then editBox:SetTextInsets(6, 6, 6, 6) end
    editBox:SetText("")
    if editBox.SetMaxLetters then editBox:SetMaxLetters(0) end
    scroll:SetScrollChild(editBox)
    importScroll = scroll
    local sb = CreateFrame("Slider", "ZugLootImportBar", borderF, "UIPanelScrollBarTemplate")
    sb:SetPoint("TOPLEFT", scroll, "TOPRIGHT", -14, -16)
    sb:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", -14, 16)
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
    if borderF.SetScript then
      -- Click-to-focus on the moat ring around the scroll area.
      borderF:SetScript("OnMouseDown", function()
        if editBox.SetFocus then editBox:SetFocus() end
      end)
    end
    if scroll.SetScript then
      -- Click-to-focus: the whole box is one big click target.
      scroll:SetScript("OnMouseDown", function()
        if editBox.SetFocus then editBox:SetFocus() end
      end)
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
    -- Raidres hint below the edit box: caption + annotated screenshot
    -- (red boxes around both "RollFor export" buttons). Static sizes;
    -- the baked TGA is 512x512 with live content in the top 271px,
    -- cropped via SetTexCoord and shown at full box width. Buttons
    -- stay anchored to BOTTOM, so the taller frame just moves them down.
    local hint = pasteFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hint:SetPoint("TOPLEFT", borderF, "BOTTOMLEFT", 0, -8)
    if hint.SetJustifyH then hint:SetJustifyH("LEFT") end
    hint:SetText("Paste RollFor export from raidres")
    importHintText = hint
    local hintTex = pasteFrame:CreateTexture(nil, "ARTWORK")
    if hintTex.SetTexture then hintTex:SetTexture(M.HINT_IMAGE) end
    if hintTex.SetTexCoord then hintTex:SetTexCoord(0, 1, 0, M.HINT_TEX_BOTTOM) end
    hintTex:SetWidth(M.HINT_IMG_W) hintTex:SetHeight(M.HINT_IMG_H)
    hintTex:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -4)
    importHintTex = hintTex
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
    SyncImportScroll()
  end
  -- Non-privileged users may still open the frame to inspect, but Import is gated.
  -- Re-pin on every show: the main window rebuilds on size changes, and a
  -- fresh main frame would otherwise reclaim the top spot.
  RaiseImportAboveMain()
  pasteFrame:Show()
  -- Focus the box on open so Ctrl+V pastes immediately.
  if editBox and editBox.SetFocus then editBox:SetFocus() end
end
