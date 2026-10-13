# ZugLoot (skeleton v0.1.0)

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
- Everyone: `/zl sheet` opens the big tabbed window (Sheet | Rolls | Versions | Setup).
  Sheet tab shows one card per item: hoverable icon, `Name xN (+SR+)`, `[HR]` /
  `[rolled xN]` badges, WON marks, and every roll session this raid one line
  per player.
- ML: `/zl rf <itemlink>` starts an SR roll. `/zl sim <itemlink>` practices without a raid.
- Raider: frame pops on ML warning / ROLL_REQ / group-loot drops. `/zl auto on` to auto-roll SRs.
- `/zl ver` shows the addon-version squares grid. `/zl help` lists commands.

## Static file (`CustomData/ZugLoot_SR.txt`)

Easiest: paste the raw raidres.top export string into the file as-is
(single base64 blob, no editing needed). Or hand-write the line format:

```
# comments start with #
Blackfang; 17063:2+20, 19137:1
Carbon; 18646:1+60
HARDRES; 17782, 18564
```

Per entry: `itemID[:count][+srplus]`. Requires Nampower (`ReadCustomFile`).
Only ML / raid leader / assistant can import or broadcast.

## Tests (outside WoW)

```
cd ZugLoot
lua tests/run_tests.lua
```

## Commands

`/zl sheet|import|loadfile|rf|arf|rr|2x|fr|cr|show|hide|time|autoclose|auto|ver|verlist|sim|simboss|log|logclear|reset|help`
