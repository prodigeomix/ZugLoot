# ZugLoot

SR loot addon for Turtle WoW for **both master looters and raiders**.
RollFor-inspired ML console + SR+ support, LootBlare-inspired raider frame.

Full design: see `SPEC.md`.

## Install

Copy the `ZugLoot/` folder into
`<WoW>/Interface/AddOns/` and restart the client (or `/reload`).
No dependencies. Interface 11200.

## Quick start

- ML/RL: `/zl import` paste a raidres export, or put a static sheet at
  `<WoW>/CustomData/ZugLoot_SR.txt` (see `CustomData_example/ZugLoot_SR.txt`)
  and press **Load from File**. Solo (no group) you can still load a sheet
  the same way to preview/sim — it just isn't broadcast until you group up.
- Everyone: `/zl sheet` opens the big tabbed window (Sheet | Raids | Rolls | Versions | Setup).
  The Raids tab lists all raids including the live one — **Activate**
  (or `/zl raid <id>`) switches the active sheet and continues it with won
  marks + history intact.
  Sheet tab shows one card per item: hoverable icon, class-colored
  `Name xN (+SR+)`, `[HR]` / `[rolled xN]` badges, WON marks, and every roll
  session this raid one line per player (class resolved roster-first, sheet
  fallback; solo still gets sheet colors).
- ML: `/zl rf <itemlink>` starts an SR roll; looting a boss lists corpse loot
  as numbered icon/name rows with SR/HR badges — click a row to Award a lone
  reserver directly, `...` for more choices, or roll it (`/zl roll <item>`). Nothing
  auto-awards: on completion the award menu offers the kind winners (SR,
  MS, OS, TMOG) and a class-sorted roster — pick with `/zl award <name>`.
  `/zl sim <itemlink>` / `/zl simboss <boss>` / `/zl simraid <raid>`
  rehearse against the loaded sheet (sheet required): full live replay
  with timers, both windows, the shared loot window (simboss/simraid queue
  boss drops + trash batches; you roll each), the award menu, and
  group-routed chat (raid→RAID, party→PARTY, solo→local); results written
  back; `/zl simstop` stops the queue. `/zl simtmog` demos the TMOG kind
  award. Boss/raid drops come from the live Atlas-CFM loot tables
  (optional dependency, nothing copied).
  The **Reset rolls** button at the top of
  the window (confirmation window first) or `/zl reset` clears sessions + won marks.
- Raider: frame pops on the ML's roll call (warning / ROLL_REQ) under master loot only — group loot stays in Blizzard's Need/Greed frames, solo stays shut (Setup `Roll window: ML/ALL` restores the legacy mirror). `/zl auto on` to auto-roll SRs.
- `/zl ver` shows the addon-version squares grid. `/zl help` lists commands.

## Static file (`CustomData/ZugLoot_SR.txt`)

Easiest: paste the raw raidres.top export string into the file as-is
(single base64 blob, no editing needed). Or paste a CSV export
(`ID,Attendee,Class,Specialization,SR+` header, extra columns ignored —
see `CustomData_example/ZugLoot_SR.txt.csv`), or hand-write the line format:

```
# comments start with #
Blackfang; 17063:2+20, 19137:1
Carbon; 18646:1+60
HARDRES; 17782, 18564
```

Per entry: `itemID[:count][+srplus]`. Lines above a base64 blob or the
CSV header (tool notes, "copy below this line") are ignored.
Requires Nampower (`ReadCustomFile`).
Only ML / raid leader / assistant can import or broadcast.

## Tests (outside WoW)

```
cd ZugLoot
lua tests/run_tests.lua   # stock lua 5.1+ (CI runs 5.1 and 5.4)
luacheck .                # WoW-aware lint, see .luacheckrc
```

PRs run both as required checks (`.github/workflows/ci.yml`) —
merge is blocked until tests + lint pass.

## Commands

`/zl sheet|raids|raid <id>|raidforget <id>|import|loadfile|rf|arf|rr|2x|roll|award|fr|cr|show|hide|time|autoclose|auto|ver|verlist|sim|simboss|simraid|simtmog|simroll|simstop|log|logclear|reset|help`
