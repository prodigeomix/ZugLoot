# Ticket: invalid escape code in chat message (Comm.lua:63)

## Status
Open — deferred, to be picked up later.

## Symptom
When simrolling Ragnaros: waited, then got an error
"invalid escape code in chat message". Blamed line: `Comm.lua:63`
(`SendChatMessage(tostring(msg), "PARTY")` inside `M.SayGroup`).

## Context / notes
- `Comm.lua:63` itself is a plain passthrough — it does not build or
  format the message. The offending escape sequence must already be in
  `msg` when it arrives at `SayGroup`.
- Sim chat routing matches live rolls: raid → `RAID` + `RAID_WARNING`,
  party → `PARTY`, solo → local frame. Error hit the PARTY branch, so
  the user was grouped (party, not raid, not solo) at the time.
- "Waited, then error" suggests it fires on the finish path (roll timer
  expiry → `Sim.finishSim` → `MasterLootUI.Finish` → `AnnounceResult` →
  `SayGroup`/`WarnGroup`), not at Roll time. So the suspect payload is the
  **result text**, not the "ZugLoot rolling:" announce.
- Result text is built in `MasterLootUI.AnnounceResult` (~line 237):
  `"ZugLoot result [" .. dispName .. "]: " .. table.concat(parts, " | ")`
  plus per-kind lines (`SR winner: …`, `MS winner: …`, etc. via WarnGroup).
- No `invalid escape`-style string exists anywhere in the addon
  (grep finds nothing) — the message comes from the client itself,
  i.e. the chat frame choking on a bad `|X` escape in what we send.

## Theories (reporter's, to investigate when picked up)
1. *(reporter's theory — fill in)*
2. *(reporter's theory — fill in)*

## Starting points for investigation
- Suspect pool for a bad `|` sequence: `dispName` / item link text passed
  through chat (bare `tostring(itemID)` sim links like `"1001"` are clean,
  but pfQuest-sourced Ragnaros names/descriptions may carry `|` or `%`
  characters), player names, and the ` | ` separators (benign).
- Candidate hardening once root cause is found: sanitize chat-bound
  strings (strip `|` escapes or validate `|c…|H…|h…|h|r` link structure)
  at a single choke point — `M.SayGroup`/`M.WarnGroup` in `Comm.lua` —
  rather than at every call site.
- Repro: `/zl simboss Ragnaros` (or boss with pfQuest-sourced drops) while
  in a party, let the roll timer expire; watch party chat send.
- Regression test idea: feed item/player names containing `|`, `%`, and
  partial `|c`/`|H` sequences through `AnnounceResult` and assert the
  `SendChatMessage` stub receives escape-clean text.

## Files of interest
- `Comm.lua` (`SayGroup`/`WarnGroup`, lines ~59–78)
- `MasterLootUI.lua` (`AnnounceResult`, ~line 210–295; `BeginSession` announce, ~line 35)
- `Sim.lua` (`finishSim`, `playOne`, `dispName`)
- `pfLoot.lua` (Ragnaros drop/name source — possible `|` origin)
