-- ZugLoot/RaidArchive.lua
-- PURE raid history: every replaced/imported sheet is snapshotted into
-- DB.raidArchive (newest first, capped) so past raids can be viewed
-- read-only or re-activated ("continue"). No WoW API. Testable under stock lua.
local M = {}

local Util
if ZugLoot and ZugLoot.Util then Util = ZugLoot.Util
else
  local ok, u = pcall(require, "Util")
  if ok then Util = u end
end
if not Util then
  Util = { ArrayCount = function(t) local n = 0 if type(t) == "table" then while t[n+1] ~= nil do n = n + 1 end end return n end }
  Util.TableCount = function(t) local n = 0 if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end return n end
end

M.MAX_KEPT = 20

-- Deep copy for plain data tables (our sheets have no cycles).
function M.DeepCopy(v, seen)
  if type(v) ~= "table" then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, val in pairs(v) do
    out[M.DeepCopy(k, seen)] = M.DeepCopy(val, seen)
  end
  return out
end

function M.CountSessions(sheet)
  local n = 0
  if sheet and sheet.rolls then
    for _, hist in pairs(sheet.rolls) do
      n = n + Util.ArrayCount(hist)
    end
  end
  return n
end

function M.CountWon(sheet)
  local n = 0
  if sheet and sheet.won then
    for _, w in pairs(sheet.won) do
      n = n + Util.TableCount(w)
    end
  end
  return n
end

function M.CountRollers(sheet)
  local seen, n = {}, 0
  if sheet and sheet.items then
    for _, item in pairs(sheet.items) do
      local rollers = item.rollers or {}
      local i = 1
      while rollers[i] ~= nil do
        if rollers[i].name and not seen[rollers[i].name] then
          seen[rollers[i].name] = true
          n = n + 1
        end
        i = i + 1
      end
    end
  end
  return n
end

-- Snapshot a live sheet into a storable record. now = epoch seconds.
function M.SnapshotSheet(sheet, now)
  if not sheet then return nil end
  local meta = sheet.meta or {}
  return {
    raidID = meta.raidID or ("unknown-" .. tostring(now or 0)),
    importedBy = meta.importedBy or "?",
    importedAt = meta.importedAt or 0,
    source = meta.source or "?",
    archivedAt = now or 0,
    nItems = Util.TableCount(sheet.items or {}),
    nRollers = M.CountRollers(sheet),
    nSessions = M.CountSessions(sheet),
    nWon = M.CountWon(sheet),
    data = {
      meta = M.DeepCopy(meta),
      items = M.DeepCopy(sheet.items or {}),
      hardres = M.DeepCopy(sheet.hardres or {}),
      won = M.DeepCopy(sheet.won or {}),
      rolls = M.DeepCopy(sheet.rolls or {}),
    },
  }
end

function M.GetArchive(db)
  if not db then return {} end
  db.raidArchive = db.raidArchive or {}
  return db.raidArchive
end

-- Archive the currently active sheet (if any). Dedupes by raidID: re-archiving
-- the same raid replaces its snapshot so progress follows the raid.
-- Returns the snapshot, or nil when there was nothing to archive.
function M.ArchiveActive(db, now)
  local sheet = db and db.sheet
  if not sheet then return nil end
  local snap = M.SnapshotSheet(sheet, now)
  if not snap then return nil end
  local arch = M.GetArchive(db)
  -- Remove any older snapshot of the same raid.
  local i = 1
  while arch[i] ~= nil do
    if arch[i].raidID == snap.raidID then
      table.remove(arch, i)
    else
      i = i + 1
    end
  end
  table.insert(arch, 1, snap)
  while Util.ArrayCount(arch) > M.MAX_KEPT do
    table.remove(arch)
  end
  return snap
end

function M.Find(db, raidID)
  local arch = M.GetArchive(db)
  local i = 1
  while arch[i] ~= nil do
    if arch[i].raidID == raidID then return arch[i] end
    i = i + 1
  end
  return nil
end

-- Refresh the live sheet's archive entry in place (same dedupe slot as
-- ArchiveActive, but the sheet stays live). This is what puts a freshly
-- loaded sheet into the list immediately, even though it was never
-- unloaded/replaced. Returns the snapshot, or nil with no live sheet.
function M.SyncActive(db, now)
  local sheet = db and db.sheet
  if not sheet then return nil end
  local snap = M.SnapshotSheet(sheet, now)
  if not snap then return nil end
  local arch = M.GetArchive(db)
  -- Replace the live raid's slot in place (keeps list position stable).
  local i = 1
  while arch[i] ~= nil do
    if arch[i].raidID == snap.raidID then
      arch[i] = snap
      return snap
    end
    i = i + 1
  end
  table.insert(arch, 1, snap)
  while Util.ArrayCount(arch) > M.MAX_KEPT do
    table.remove(arch)
  end
  return snap
end

-- Lightweight rows for the Raids tab, newest first. The live sheet is
-- always included (synced first) so a just-loaded raid shows up even if
-- it was never unloaded.
-- Row: { raidID, importedBy, importedAt, archivedAt, source,
--        nItems, nRollers, nSessions, nWon, active }
function M.ListSummaries(db, now)
  M.SyncActive(db, now)
  local out = {}
  local arch = M.GetArchive(db)
  local activeID = db and db.sheet and db.sheet.meta and db.sheet.meta.raidID
  local i = 1
  while arch[i] ~= nil do
    local s = arch[i]
    table.insert(out, {
      raidID = s.raidID,
      importedBy = s.importedBy,
      importedAt = s.importedAt,
      archivedAt = s.archivedAt,
      source = s.source,
      nItems = s.nItems,
      nRollers = s.nRollers,
      nSessions = s.nSessions,
      nWon = s.nWon,
      active = (s.raidID == activeID),
    })
    i = i + 1
  end
  return out
end

-- Restore an archived snapshot as the live sheet (deep copy, so the archive
-- keeps its frozen copy). Returns sheet or nil + error string.
function M.RestoreSheet(db, raidID)
  local snap = M.Find(db, raidID)
  if not snap then return nil, "no archived raid " .. tostring(raidID) end
  local sheet = {
    meta = M.DeepCopy(snap.data.meta or {}),
    items = M.DeepCopy(snap.data.items or {}),
    hardres = M.DeepCopy(snap.data.hardres or {}),
    won = M.DeepCopy(snap.data.won or {}),
    rolls = M.DeepCopy(snap.data.rolls or {}),
  }
  db.sheet = sheet
  return sheet
end

if ZugLoot then ZugLoot.RaidArchive = M end
return M
