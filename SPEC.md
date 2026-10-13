# ZugLoot — Specification (v0.1 skeleton)

Loot addon for Turtle WoW (1.12, Interface 11200) for **both master looters and raiders**.
Inspiration: **RollFor** (master-looter automation, SR integration, version broadcast,
tie handling, raid-roll) and **LootBlare** (big obvious raider frame, SR/MS/OS/TMOG
buttons with roll caps, raid-warning triggered rolls).

## 1. Goals / non-goals

Goals:

- One addon, two faces: a **master-looter console** (RollFor-like) and a **raider
  loot window** (LootBlare-like, incl. group-loot display).
- **SR sheets**: import, secure distribution, SR+ math, fancy in-game sheet view,
  one-win-per-item enforcement, drop log.
- **Auto-roll + auto-resolve**: raiders can auto-roll SR items; if the whole raid
  runs ZugLoot the ML can auto-resolve SR drops without waiting on chat rolls.
- **Visibility**: raid-wide version grid (squares), drop log, simulation mode.
- **Testability**: pure loot logic (parse / resolve) runs both in-game and under
  stock `lua` outside the client (`tests/`).

Non-goals (skeleton): DKP/EPGP, full boss loot database for every raid, LibStub
dependencies, minimap button art. These are extension points, not blockers.

## 2. Roles & security

| Role | How detected (1.12 APIs) | Powers |
|------|--------------------------|--------|
| Master Looter (ML) | `GetLootMethod()` returns `"master"` + `GetLootMaster()` == player | Start/finish/cancel rolls, award loot, broadcast sheet |
| Raid leader / assistant | `IsRaidLeader()` / `IsRaidOfficer()` (fallback: party leader) | Import + broadcast sheet (same as ML) |
| Raider | everyone else | View sheet, roll, auto-roll, sim |

Rules:

1. **Only ML or raid leader/assistant may broadcast a sheet.** This is enforced
   *twice*:
   - sender side: `SRSecurity.CanBroadcast()` gates sending; `ApplySheet` only
     broadcasts when it is true;
   - receiver side: `Comm.OnSheetReceived` verifies the sender `IsML(sender) or
     IsRaidLeaderOrAssistant(sender)` against the *current* roster and drops +
     warns on violation.
1b. **Solo (out of party/raid) may always load a sheet locally** (paste or
   `Load from File`) for preview/sim/sheet-view. No broadcast happens solo
   (`Comm.Channel()` is nil there; `VER_REQ`/`AWARD` also skip). `CanImport()`
   covers local loading; `CanBroadcast()` covers pushing to the group.
2. Sheet broadcasts carry `raidID` (= leader name + import timestamp) and `version`.
   Receivers overwrite only if `raidID` is newer; stale sheets never clobber fresh ones.
3. Raiders get a **read-only** copy. There is no addon-message path for a raider to
   push sheet edits.
4. Comm prefix: `ZugLoot` (chat addon channel `CHAT_MSG_ADDON`). Message types:
   `SHEET:<ver>:<raidID>:<payload>`, `ROLL_REQ:<sessionID>:<itemLink>:<mode>`,
   `ROLL_ANS:<sessionID>:<name>:<rollType>`, `VER_REQ`, `VER_ANS:<version>`,
   `AWARD:<itemID>:<winner>`, `LOG:<entry>`.

## 3. SR sheet model

```lua
Sheet = {
  meta    = { raidID = "Leader-epoch", importedAt = 0, importedBy = "Name", source = "paste|file" },
  items   = { [itemID] = { quality = 4, rollers = { { name="X", rolls=2, sr_plus=30 }, ... } } },
  hardres = { [itemID] = { quality = 5 } },
  won     = { [itemID] = { ["PlayerName"] = true } },  -- one copy per player per raid
}
```

- `rolls` = how many times the player SR'd that item (duplicate reservations count,
  e.g. `x2`). Displayed as `Name x2`.
- `sr_plus` = highest SR+ bonus across that player's duplicate reservations for the
  item (RollFor parity: keep `max`, never sum). `nil/0` = no bonus.
- `won` is runtime-only (per raid, cleared on new sheet / `/zl reset`). It is what
  powers "won items are visible but marked; that raider can't win another copy".

### 3.1 Supported import formats

1. **raidres.top / raidres.fly.dev / softres.it export** (paste path): base64-encoded
   JSON with any of `reservations[]` (new: `character.name`, `raidItemId`,
   `srPlus` as number|string|`{value,isValid}`), `softreserves[]`
   (`name/role/items[{id,quality,sr_plus}]`), `hardreserves[]`. `sr_plus` also
   accepts `rollBonus`/`roll_bonus` (softres.it). Numeric strings coerced.
   `isValid=false` still counts (raidres defaults it to false when validation is
   off) — value is what matters.
2. **Static file** (`CustomData/ZugLoot_SR.txt`, via Load from File): accepts
   *either* a raw raidres export blob pasted into the file (base64, exactly
   what raidres.top gives you) *or* the static line format below. Paste-import
   accepts both as well; format is auto-detected (export first, lines second).
3. **Static line format** (hand-written sheets, either path):
   `#` comments, blank lines ignored.
   ```
   # Player; itemID[:count][: +srplus], ...
   Blackfang; 17063:2+20, 19137:1
   Carbon; 18646:1+60
   HARDRES; 17782, 18564
   ```
   Grammar per entry: `itemID` (required number), `:count` (default 1),
   `+srplus` (default 0). `HARDRES;` line lists hard-reserved item IDs.
3. Anything else → import error naming the first bad line (never half-imports).

### 3.2 SR+ calculation (normative)

- `effective = baseRoll(1..cap) + (sr_plus or 0)`.
- Roll caps (LootBlare parity): SR 1–100, MS 1–100, OS 1–99, TMOG 1–98.
  SR sessions only accept SR-range rolls (1–100) from eligible rollers.
- Eligible for an SR item = on that item's roller list AND not already in
  `won[itemID]` AND (raid roster check optional: offline players flagged, not deleted).
- Winner = highest `effective`. Ties among top → tie-roll session restricted to
  tied players. Miss-rolls (player without SR rolling on an SR item) are recorded
  but **ignored** for winner selection and flagged in output (`MISSRROLL`).
- Non-SR items: open roll, highest base roll wins (MS > OS > TMOG priority display
  only; winner is still highest roll in highest priority class that rolled —
  LootBlare-style sorting).
- Two-copies drops (`2x<link>`): top two distinct winners by same rules.
- One-win-per-item: after award, `won[itemID][winner]=true`. Sheet view renders
  `WON: Name`; resolver excludes them from later sessions for that itemID.

## 4. UI

### 4.1 SR sheet view (`SRView.lua`) — both roles

- `/zl sheet` or toolbar button. Movable, closable, `UIDropDown`-free (1.12-safe).
- Sorted **by item**: itemID ascending, grouped with icon + link (cached via
  `GetItemInfo(tonumber(id))` numeric-ID trick, cf. LootBlare fix #8), quality color.
- Per item row: each roller as `|c<classcolor>Name|r xN (+M)`; SR+ in gold.
  Won players struck through + `WON` tag; rows for fully-won-by-you items dimmed.
- Header: raidID, importer, counts (items / rollers / hardres), buttons:
  `Import` (ML/RL only, others see disabled + tooltip "Master looter or raid
  leader only"), `Load from File`, `Close`.
- "Fancy" = class colors, quality borders, zebra rows, icon textures, WON badges,
  tooltips with roller detail. No external libs.

### 4.2 Master-looter console (`MasterLootUI.lua`) — RollFor-like

- `/zl` shows console: loot list (current loot window items w/ SR badges + counts),
  session controls: `SR roll`, `All roll (/arf equivalent)`, `Raid roll`,
  `2x top wins`, `Finish early`, `Cancel`, `Award`.
- Roll sessions: triggered by `/zl rf <link>`, `/zl arf <link>`, `/zl rr <link>`,
  `/zl 2x<link>`, or clicking a loot-list row. Announces via RAID_WARNING
  (LootBlare trigger compatibility) + `ROLL_REQ` addon message (auto-roll path).
- Accepts chat `CHAT_MSG_SYSTEM` rolls (`X rolls Y (1-Z)`), first-roll-only per
  player; detects over-rolls, ties auto re-roll.
- Award flow: click winner → confirmation popup → `GiveMasterLoot` + `AWARD`
  broadcast + `won` marking + DropLog entry.
- Master-loot window hardening: confirmation popup, class-sorted candidate list
  (extension point; skeleton uses default UI + confirm).

### 4.3 Raider loot window (`RaiderLootUI.lua`) — LootBlare-like

- Appears when: (a) ML sends RAID_WARNING with an item link (sender verified as ML),
  or (b) `ROLL_REQ` received, or (c) **group-loot mode**: loot method is group and
  a roll-worthy item (quality ≥ threshold) is announced — same frame, so group
  loot looks identical to master loot from the raider's side (per requirement).
- Contents: item icon + link, countdown bar (duration synced from ML), roll-type
  buttons **SR / MS / OS / TMOG** with caps 100/100/99/98, sorted live roll list
  (SR red, MS yellow, OS green, TM cyan — LootBlare colors), winner banner.
- First-roll-only; extra rolls ignored with notice. Auto-close timer configurable
  (`/zl time N`, `/zl autoclose on|off`).
- Draggable; `/zl show|hide`.

### 4.4 Version grid (`VersionGrid.lua`)

- `/zl ver` requests versions (`VER_REQ` → all clients answer `VER_ANS`).
- Grid of **squares**, one per raid member, colored:
  green = current version, yellow = outdated, red = no addon / no response,
  grey = offline/absent. Tooltip: name, version, auto-roll on/off.
- Text list fallback via `/zl verlist`. Grid doubles as auto-resolve readiness:
  all-green ⇒ ML's `Auto-resolve` button enabled.

### 4.5 Auto-roll (`AutoRoll.lua`)

- Per-character opt-in: `/zl auto on|off` (default off). Stored in `ZugLootCharDB`.
- When a `ROLL_REQ`/warning arrives for an item the player SR'd (and hasn't won),
  auto `/roll`s with SR cap after 1s jitter (avoids thundering herd).
- **Auto-resolve**: if every eligible SR roller is version-grid green with auto-roll
  on, ML resolves immediately from `ROLL_ANS` messages (no chat-roll wait), with a
  5s fallback to normal rolling if answers are missing.

### 4.6 Simulation (`Sim.lua` + `BossData.lua`)

In-game, no raid needed:

- `/zl sim <itemLink> [N]` — fake session for the item using current sheet rollers
  (+ N random fillers): prints each fake roll, effective values, miss-roll demo
  (one filler rolls without SR → flagged/ignored), tie demo, winner.
- `/zl simboss <boss>` — random draws from `BossData[boss]` loot table, resolves
  each via sheet (SR resolution, open raid-rolls for unreserved, results summary).
- Uses the **same** `Resolver` pure module as real sessions and as `tests/`, so
  sim output matches tested logic. Randomness via `math.random`, seeded by time.

### 4.7 Drop log (`DropLog.lua`)

- Every observed drop (ML loot window / announced item) appended:
  `{ time, itemID, itemLink, source(boss/manual), strategy, winner, price:nil }`.
- `/zl log` window (scrollable, newest first), `/zl logclear` (ML/RL only).
- Persisted in `ZugLootDB.drops` (cap 500, ring buffer).

## 5. File layout (skeleton)

```
ZugLoot/
  ZugLoot.toc        Interface 11200, SavedVariables(+PerCharacter), load order
  SPEC.md            this file
  README.md          install + commands
  Core.lua           namespace, version, print, event frame, slash cmds
  Constants.lua      caps, colors, prefix, addon version
  Util.lua           pure helpers (trim/split/itemID/base64) — testable
  FileIO.lua         CustomData wrapper (ReadCustomFile/WriteCustomFile, Nampower)
  SRData.lua         PURE: parse line/base64 formats, SR+ extract, won helpers
  Resolver.lua       PURE: effective-roll winner/tie/missroll/two-win logic
  Comm.lua           addon-message send/receive, sheet guard (security)
  SRSecurity.lua     IsML/IsLeader/CanImport/CanBroadcast
  SRImport.lua       paste frame + "Load from File" (CustomData/ZugLoot_SR.txt)
  SRView.lua         fancy sheet window (sorted by item, xN, +SR+, WON)
  MasterLootUI.lua   ML console + session control + award confirm
  RaiderLootUI.lua   LootBlare-like frame incl. group-loot display
  AutoRoll.lua       auto-roll + auto-resolve eligibility
  VersionGrid.lua    squares grid + version request handling
  BossData.lua       tiny boss→items tables for simboss
  Sim.lua            /zl sim, /zl simboss (uses Resolver)
  DropLog.lua        drop log store + window
  tests/
    run_tests.lua    stock-lua runner (lua tests/run_tests.lua)
    wow_mock.lua     minimal WoW globals shim for in-client files if needed
    test_srdata.lua  SR parse / SR+ / won tests
    test_resolver.lua winner / tie / missroll / one-win / 2x tests
  CustomData_example/
    ZugLoot_SR.txt   static-file format example (copy to <WoW>/CustomData/)
```

Load order respects deps (pure → security/comm → import → views). All files are
Lua 5.0-safe (no `goto`, no bitwise ops, no `//`; `table.getn` avoided — use
`table.getn` shim in `Util` if needed; actually skeleton uses `#`-free counting
via `Util.Count` so it parses on 5.0 and runs on 5.5 tests).

## 6. Slash commands

```
/zl sheet            open sheet view
/zl import           open import frame (ML/RL only for broadcast)
/zl loadfile         import from CustomData/ZugLoot_SR.txt (ML/RL only)
/zl rf <link>        start SR roll (ML)        /zl arf <link>  open roll
/zl rr <link>        raid-roll                 /zl 2x<link>    two-top-win
/zl fr | /zl cr      finish early | cancel session
/zl show|hide        raider frame toggle
/zl time N           roll window seconds       /zl autoclose on|off
/zl auto on|off      auto-roll SR items (per char)
/zl ver | /zl verlist version grid | text list
/zl sim <link> [N]   simulate rolls for item
/zl simboss <boss>   simulate boss drops (BossData)
/zl log | /zl logclear drop log
/zl reset            clear won marks (ML/RL, new raid)
/zl help
```

## 7. Testing

- Outside client: `lua tests/run_tests.lua` (repo root = `ZugLoot/`). Covers:
  line-format parse, base64/raidres transform incl. all `srPlus` spellings,
  max-not-sum SR+, winner/tie/miss-roll/one-win-per-item/2x, file-example parse.
- In game: `/zl sim` + `/zl simboss` exercise the same `Resolver`; import a sheet
  via paste and via `Load from File`; check version grid with a second client.
- Lua 5.0 compliance: skeleton avoids post-5.0 syntax; keep it that way
  (no `~`, `//`, `goto`, integer division; use `math.floor`).

## 8. Requirements traceability

- SR import + ML/RL-only security → §2, `SRSecurity` + `Comm` guards + `SRImport`.
- SR+ calc → §3.2, `SRData.ExtractSRPlus` + `Resolver.Effective`.
- Fancy sheet view, sorted by item, player ×N + SR+, won-but-blocked → §3, §4.1.
- ML interface (RollFor-like) → §4.2. Raider window (LootBlare-like) → §4.3.
- Auto-roll SR + full-raid auto-resolve + version squares grid → §4.4, §4.5.
- In-game sim (SR resolution, rolling, raid roll, miss-roll, results) + outside
  tests → §4.6, §7.
- Drop log → §4.7. Static file import w/ button → §3.1(2), `FileIO` + `SRImport`.
- Group-loot item display (LootBlare-style) → §4.3(c).
