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
| Loot runner (anyone) | whoever opens the corpse — solo, any loot method, ML or not | Collect loot, start/finish/cancel rolls, award loot |
| Master Looter (ML) | `GetLootMethod()` returns `"master"` + `GetLootMaster()` == player | As loot runner, plus group-chat announces + `ROLL_REQ` to rollers |
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
1b. **Anyone may load a sheet locally** (paste or `Load from File`, solo or
grouped) for their own view/sim — importing never pushes anything.
Broadcasting stays ML/leader-only (`CanBroadcast()`); synced sheets are
trusted from ML/leader only (`CanAcceptFrom()`). No broadcast happens solo
(`Comm.Channel()` is nil there; `VER_REQ`/`AWARD` also skip).
2. Sheet broadcasts carry `raidID` (= leader name + import timestamp), `version`,
   and a META envelope (raid name + revision stamp). Same-raid updates keep
   the raidID and apply by revision (`importedAt`: raidres export time, else
   import time) — older-or-equal revisions are stale and refused on ALL paths
   (paste, file, sync), BEFORE archiving, so an old export can never roll a
   newer update back. Different raidIDs always apply.
3. Raiders get a **read-only** copy. There is no addon-message path for a raider to
   push sheet edits.
4. Comm prefix: `ZugLoot` (chat addon channel `CHAT_MSG_ADDON`). Message types:
   `SHEET:<ver>:<raidID>:<payload>`, `ROLL_REQ:<sessionID>:<itemLink>:<mode>`,
   `ROLL_ANS:<sessionID>:<name>:<rollType>`, `VER_REQ`, `VER_ANS:<version>`,
   `AWARD:<itemID>:<winner>`, `LOG:<entry>`.

## 3. SR sheet model

```lua
Sheet = {
  meta    = { raidID = "Leader-epoch", raidName = "Molten Core"|nil, importedAt = 0, importedBy = "Name", source = "paste|file" },
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
- `raidName` = instance name from the raidres export (`metadata.instances[1]`,
  else `metadata.instance`); nil for hand-written line sheets. Shown in the
  window header next to the ID.
- `importedAt` = import timestamp = the raid's start time for display and
  raid-list ordering (see Raids tab).

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

### 3.2 Roll types (normative): each kind judged by itself

- Ranges (LootBlare parity): SR 1–100, MS 1–100, OS 1–99, TMOG 1–98.
  A roll only counts inside its own range — anything above the TYPE cap is
  an over-roll (flagged, never wins). `effective = base + sr_plus`, where
  the SR bonus applies to SR rolls by sheet rollers ONLY (MS/OS/TMOG never
  take sr_plus).
- Each kind crowns its own winner (`perType`: best SR, best MS, best OS,
  best TMOG) from the RANGE the player chose — 1-100 is SR only with the
  reserve on the item, otherwise MS; 1-99 OS; 1-98 TMOG. Ties re-roll
  WITHIN the kind.
- Overall winner by priority SR > MS > OS: the best SR beats any MS/OS
  roll (TMOG 15 vs SR 58 → SR wins outright). TMOG never takes an overall
  winner slot — it crowns its own kind winner, directly awardable.
- Miss-rolls = SR-range rolls from players WITHOUT the reserve (fake SR
  claims): recorded but ignored. MS/OS rolls are valid kind contests from
  anyone (the sheet only holds SR rollers); TMOG never misses.
- Eligible = not already in `won[itemID]` — for the SR contest ONLY
  (one-win-per-item; excluded SR rolls stay visible with `[already won]`,
  never silently dropped). MS/OS/TMOG stay contestable after a win (e.g.
  rolling transmog after winning mainspec).
- Open rolls (`arf`, off-sheet): every kind is a fair contest — highest
  effective wins regardless of type letter (TMOG still excluded from the
  overall slot).
- Two-copies drops (`2x<link>`): winner + runner-up (same kind first, then
  other kinds in priority order).
- TMOG is directly awardable: the award window offers `Award <name> (TMOG)`
  for the kind winner next to the outright winner rows. The ML awards the
  SR, MS, OS or TMOG winner; anything after the award (e.g. a trade) is
  outside the addon. Chat follows the raid-roll style (Pysanka parity):
  one `Name: roll (TYPE)` line per roller (already-won tagged inline),
  then `Name wins Item (raid-roll).` on award.
- Raid-roll (`/zl rr <link>`, loot ... `Raid-roll` choice — RollFor +
  Pysanka parity): the raid is announced numbered (`[1]:Name, ...`,
  chunked), the ML rolls 1-N with `/roll`, the number IS the winner
  (frozen roster, so leavers/joiners mid-roll change nothing; only the
  ML's 1-N roll counts, first number only). Finish/award reuse the
  normal path, including the `(raid-roll).` award line.
- One-win-per-item: after award, `won[itemID][winner]=true`. Sheet view renders
  `WON: Name`; resolver excludes them from later sessions for that itemID.
  Excluded rollers stay visible everywhere: their rolls are kept in a separate
  `excluded` list (never silently dropped), shown with an `[already won]` tag in
  the raid result line, the live raider roll list (greyed), sim output, and the
  Sheet tab history lines (`Resolver.ToHistoryEntry` carries them into
  `sheet.rolls`).

### 3.3 Unreserved drops (not on the sheet)

- When a finished roll session (live or sim) had rolls for an itemID absent
  from `sheet.items`, a stub `{ quality, rollers = {}, unsr = true }` is added
  via `SRData.EnsureUnreserved` — never touching existing entries, so real SR
  data can't be clobbered. Empty sessions (no rolls) add nothing.
- Cards: unreserved items render at the **bottom** of the Sheet tab
  (`SRData.SortedCardIDs`: SR'd numeric first, stubs last), with a grey
  `[not SR'd]` title badge and a `(not on SR sheet — open roll)` body line.
  `CardSummary` / `SRView.RenderText` tag them `[not SR'd]` too.
- Stubs are local roll-session artifacts: `SerializeSheet` emits no lines for
  them (empty rollers), so they never pollute broadcasts; roll-log reset
  prunes them (`PruneUnreserved`) and the sheet returns to imported state.

## 4. UI

### 4.1 Main window (`MainWindow.lua`) — both roles, Aegis-SBR-skinned

- `/zl sheet` opens the big tabbed window (900×640 target, clamped to screen
  minus margins, min 480×360, re-clamped + rebuilt on resolution/UI-scale
  change, clamped-to-screen dragging; movable, flat dark palette,
  gold accent strip, tab rail with gold underline on the active tab, per-tab
  scroll bodies with scrollbar + mouse wheel). Tabs: **Sheet** (default) |
  **Raids** | **Members** | **Setup**. `/zl log` prints the drop log to
  chat, `/zl ver` opens Members, `/zl raids` opens Raids. Header row:
  Reset rolls | Get sheet (always visible; solo prints “nobody to ask”) | Import | File —
  Setup holds options only (no duplicate import/clear buttons). (`SRView`/
  `VersionGrid` standalone frames retired into tabs; their modules keep
  pure logic + slash commands. DropLog has no tab: `Show()` prints.)
- Minimap die button (`Minimap.lua`, `INV_Misc_Dice_02` on the classic
  tracking-ring look): click toggles the main window, hover shows
  version/raid/role, drag repositions (angle persisted per character).
- **Sheet tab**, one card per item in **3 even columns** (row-major flow,
  single shared scroll body — columns scroll together; card styling
  unchanged): SR rollers in **two columns** inside each card, drop count as
  a green `[xN]` badge, **left-click opens the item roll-log window** (loot
  icon + name header, every session newest-first): SR'd items alphabetical
  by name (client cache, else sheet name, else item:id fallback; numeric
  ids break ties),
  unreserved items (rolled but never SR'd — auto-added at the bottom, see §3.3):
  - icon button (texture via `GetItemInfo(tonumber(id))` numeric-ID trick, cf.
    LootBlare fix #8; quality-color bottom border). **Hover = full GameTooltip
    item details** (`SetHyperlink` when the client knows the item, fallback
    text otherwise). Click inserts the link into an open chat box.
  - title: quality-colored name + `[HR]` tag + green `[rolled xN]` badge +
    grey `[not SR'd]` badge for unreserved items.
  - SR list: `Name xN (+SR+)` (SR+ in gold), `[WON]` marks for already-won.
  - roll history: every finished session this raid as its own block
    (`— rolls #k (mode) => winners`), **one line per player**:
    `Carbon 95(+130=225)` with `WINNER:` prefix, `[miss — no SR]` /
    `[already won]` flags where applicable.
  - zebra rows; row hover tooltip summarizes SR/HR + roll state.
- Card data comes from pure `ItemCards.BuildCards(sheet)` (tested); roll
  sessions persist in `sheet.rolls[itemID]` (capped at 25/item), recorded by
  `MasterLootUI.AnnounceResult` for every finished session.
- Header: brand row carries a prominent green `ACTIVE RAID: <name> | started
  <date>` (grey `no active raid` when no sheet; name "—" for line sheets
  without instance info); sub-line `ID <raidID> | <raid name> | started <date>
  | N items | M rolled`. Setup tab: Import (paste),
  Load from File, auto-roll toggle, clear won marks, **Reset all settings**
  (factory reset with confirmation: sheet, raid history, drop log and all
  options back to defaults; local data only, no permission gate),
  roll-time/log stats.
- **Raids tab**: imported raids with the **latest raid at the top**, ordered
  by raid datetime = the sheet's `meta.importedAt` import timestamp (the
  closest thing to a raid start time the sheet carries; `archivedAt` is only
  a fallback for legacy snapshots). Archive position never affects order, so
  re-archiving an old raid can't shuffle it above newer ones. The live sheet
  is always listed too (synced on load and on every render, so a just-loaded
  raid shows up even though it was never unloaded). Each row is titled with
  the raid name (+ green `[ACTIVE]` on the live one; "—" when unknown) and
  lists `ID <raidID>`, `started <date>`, importer, source, and counts
  (items / players / sessions / won). **Activate** makes a raid the live
  sheet and continues it — won marks + roll history come along, and the
  outgoing sheet is archived first so no progress is lost (`/zl raid <raidID>`
  does the same from chat). History lives in `ZugLootDB.raidArchive` (capped
  at 20, deduped by raidID); every import, incoming broadcast, and activation
  archives the outgoing sheet first (pure `RaidArchive` module, tested).

### 4.2 Loot console (`MasterLootUI.lua`) — RollFor-like, universal

- `/zl` shows console: loot list (current loot window items w/ SR badges + counts),
  session controls: `SR roll`, `All roll (/arf equivalent)`, `Raid roll`,
  `2x top wins`, `Finish early`, `Cancel`, `Award`.
Roll sessions: triggered by `/zl rf <link>`, `/zl arf <link>`, `/zl rr <link>`,
`/zl 2x<link>`, or the loot-window Roll button (`/zl roll <item>`). Announce via
RAID_WARNING (LootBlare trigger compatibility) + `ROLL_REQ` addon message
(auto-roll path). Accept chat `CHAT_MSG_SYSTEM` rolls (`X rolls Y (1-Z)`),
first-roll-only per player; over-rolls flagged, ties auto re-roll.
Raider clients pop their roll window off the ML/RL's RAID_WARNING roll
call ONLY (`MatchRollCall`: `Roll for X: /roll ...` dice line or full
item link — Pysanka parity). Drop lists, winners, countdowns, stop
lines, raid-roll numbering, bare names and non-ML senders never trigger.
- **Loot window** (`LootWindow.lua`, raider-window style (220px dark
  frame, icon + quality-colored name rows, roll detail with header icon
  + two-column roll list) — always ours, never Blizzard's): on
  `LOOT_OPENED`, whoever opened the corpse (solo, any loot method, ML or
  not), EVERY corpse slot gets a row (RollFor parity): coin first, then
  roll-worthy items (quality ≥ `minLootQuality`, default rare+), then
  below-threshold leftovers as one-click free rows. Blizzard's `LootFrame`
  is DETACHED session-wide (RollFor `main.lua:on_player_login` parity:
  `UnregisterAllEvents` + `OnHide` stripped at `ADDON_LOADED`, re-armed
  per `LOOT_OPENED`) — one-shot hiding is NOT enough, FrameXML re-shows
  the frame on every loot — so our rows are the loot window in every
  looting situation. NOTHING falls back to Blizzard: coin/free rows loot
  their slot on click; grouped, roll rows open the detail, while SOLO every
  row loots on click (Blizzard solo behavior — nobody to roll against, so
  no detail opens). Group loot honors the PARTY threshold
  (`GetLootThreshold`, green→epic): items at/above it enter a real group
  roll — listed with a `ROLL` badge, click never loots (Blizzard's
  Need/Greed frames own them, mirrored in our dice frame which votes via
  `RollOnLoot`, never chat `/roll`); items below it are directly lootable
  (grey/white never roll). Slot quality comes from the slot's own
  `GetLootSlotInfo`, never the maybe-cold item cache. Click-to-loot is
  CONFIRM-driven, never optimistic: the click issues the corpse call and
  dims the row; the row drops only when `LOOT_SLOT_CLEARED` confirms the
  slot left the corpse — a failed call (locked slot, full bags, out of
  range) leaves the row up for retry, and a pcall-level blowup surfaces
  in chat instead of dimming the row into a "done but not looted" ghost.
  BoP takes confirm via `LOOT_BIND_CONFIRM` → `ConfirmLootSlot`.
  Kill-switch: two consecutive solo clicks that issue clean but never
  confirm (no `LOOT_SLOT_CLEARED`, no error) restore Blizzard's frame and
  stand our rows down to display-only (`passthrough`) — a dead `LootSlot`
  path must yield to the stock UI, never strand dimmed rows. Confirms,
  errors, and failed-but-present rescans all disarm the watch; awards
  never arm it; the watch is corpse-scoped (a new corpse starts clean).
  Open-session flag (`MasterLootUI.lootOpen`, true between `LOOT_OPENED`
  and `LOOT_CLOSED`): with no session open there is no call that can land.
  Clicks and live awards both check it FIRST — before range, before slot
  verify — and block with `"not looting"` / `"Not awarding <name>: no
  loot open"`, list + row + menu untouched; re-looting resumes the cached
  window. This is what stops the walk-away wipe: the old code read an
  empty (closed) corpse as `"gone"` and rescanned every row away. Rescans
  with no open session likewise keep all rows (an unreadable corpse
  proves nothing left). Sim/non-row awards bypass the gate (no corpse).
  Range gate: "moved away" is read off `CheckInteractDistance("target",
  1)` against the corpse pinned at scan — by GUID when the client offers
  one, else by target name. Same corpse + out of range = moved: the click
  is blocked BEFORE the corpse call (`"not looting"` + chat log telling
  the player to loot the corpse again), the list is untouched — nothing
  dims, nothing clears. A different GUID is never a range block (identity
  belongs to the corpse key).
  Corpse identity: `UnitExists("target")` returns `(exists, guid)` on this
  client (Nampower/SuperWoW extension — DoiteAuras/Luna/Aegis_SBR rely on
  the same second return; GUIDs double as unit tokens). The corpse key is
  `guid:<guid>` when available, else `fp:<name>|<sorted ids>[|+coin]`.
  Walk-away-and-back reuses the window: `LOOT_CLOSED` with leftovers
  keeps rows/rolls/parked details, and re-looting the SAME corpse
  (key match) reconciles instead of wiping — live rolls and award state
  survive the round trip, with no twin-merge (same name + same loot on a
  different GUID rebuilds). A different corpse rebuilds as before.
  Session corpse cache (`MasterLootUI.corpseCache`, never persisted —
  empty at load, no SavedVariables): each not-fully-looted corpse owns
  rows, open/parked details, live + parked roll sessions, award menus,
  and click arms under its key. Looting corpse B mid-roll on A parks A
  intact (A's roll keeps collecting); returning to A restores it whole
  and B's award never touches A's state — rolls continue and loot
  distributes per corpse. Restore takes (no stale copies); fully-looted
  corpses are forgotten; abandoned ones evict oldest-first past a cap of
  5. Sim flows never touch the cache. Rolls land on the ACTIVE corpse's
  session; parked corpses collect no chat while parked. Roll state is
  keyed by (corpse, item) — never bare itemID — so the SAME item on two
  corpses owns two sessions, two parked details, two award menus and two
  sim chains; one twin's finish/award can never overwrite the other's.
  Each roll-row item is
  announced + logged (`loot`/`seen`), awarding loots the corpse slot
  through Blizzard's APIs (master loot hands to another winner by
  CANDIDATE INDEX via `GetMasterLootCandidate` — RollFor parity, never by
  name; a non-candidate award is refused with the row kept — plain
  `LootSlot` otherwise), and the overview Close button reconciles with
  the corpse (empty list closes out). `LOOT_SLOT_CLEARED` while open
  re-scans by identity multiset (slot numbers shift after each loot, so
  duplicate itemIDs track correctly); the last award closes the corpse
  out via `CloseLoot`.
  The **loot window
  lists every drop as a numbered row: row number, item icon, quality-colored
  item name, and the SR/HR badge on the right** (resolution chain per row —
  same source the sheet list uses: `GetItemInfo(row link)`, then
  `GetItemInfo(itemID)`, then the slot texture/name captured at scan time,
  then `[Name]` parsed out of the link; rows never show bare `item:<id>` while
  the client cache knows the item; tooltip on hover, shift-click links /
  ctrl-click dress-up). The raider roll window resolves its icon + name
  through the same link-first chain (`RaiderLootUI.SetItemInfo` →
  `LootWindow.ResolveItemInfo`), so it matches the loot list instead of
  degrading to a `?` icon and raw-link text when the bare-ID cache key
  misses.
- **Row detail = the roll window** (RollFor preview → rolling → winners in
  one window, cf. `gui-sr-tie.gif`): clicking a row opens the detail with
  SR (direct award on a single holder) / Roll / Close. Choosing **Roll keeps
  the window open** — it flips to the rolling view listing every valid roll
  with its kind (`SR: Aaa 90 (=100)`), SR > MS > OS > TMOG best-first, with
  Finish / Cancel / Close. **Finish ends the roll and parks it for award**
  (the session leaves the live table with rolls + menu intact); the award
  rows show in the loot list, where the parked view is the same award
  window: **Award <winner> rows (kind winners), Award TMOG, ... for
  anyone else** — plus **Continue to reopen the same roll for more
  rolls** (same session, rolls append). **When the roll finishes the
  same window
  becomes the award window**: TWO award buttons -- `Award <winner>` (kind
  winner by priority) and `Award TMOG (<name>)` whenever the TMOG kind was
  contested (floating bottom bar: each row justified, wraps when narrow,
  rolls text always clears it) — `...` for anyone else (menu candidates: any raider, for when
  something is wrong with the rolls), Close. The
  confirm popup names the item (`Award <name> to <who>?`, full link kept on
  the dialog) — never a bare `item:<id>`. Awarding closes it and the row
  leaves the list (done = gone; the last award closes the window, like a
  finished live session). **Close parks the item's state**: a rolling or
  finished-but-unawarded window saves its rolls + winner menu on close and
  reopens exactly as left — roll A, close, roll and award B, then reopen
  and award A off its saved rolls. Parked state dies only on award.
  Cancel drops the window back to pick (re-roll / choose / close). (`HR` red for hard reserves, `SR` / `SR:n` orange for soft
  reserves). Nothing auto-starts — clicking a row opens the **row detail**
  (320 wide, so `Award <name>` fits long names on one line): direct **Award**
  when exactly one SR/HR holder exists (no rolling needed), **...** for a
  real dropdown (RollFor parity: blue-hover rows — Roll, plus Award per
  reserver), **Close** to dismiss and keep working the overview. `/zl cr`
  returns the item to open. Non-ML clients ignore corpse loot.
- **Award menu** (RollFor finish-popup style): on roll completion nothing is
  auto-awarded — the ML gets winners (ranked, roll-typed) + SR/MS/OS/TMOG
  loser groups + a **class-sorted candidate roster** (sheet + rollers + raid
  roster, winners starred like RollFor's candidate grid), and picks who gets
  the item: the SR winner, a main-spec / offspec / TMOG roller, or any raider
  from the roster. Every name renders in its **class color** (see §4.8).
  In-client this is the menu frame; headless it prints and
  the ML answers `/zl award <name>`. The pick fires the confirmation popup
  (`Award <link> to <name>?`) → `GiveMasterLoot` + `AWARD` broadcast + `won`
  marking + DropLog entry.
- **TMOG kind award**: whenever the TMOG kind was contested, the menu offers
  `Award TMOG (<name>)` next to the outright winner — the ML awards the SR,
  MS, OS or TMOG winner directly. No trade handling: the award is final.

### 4.3 Raider loot window (`RaiderLootUI.lua`) — LootBlare-like

- Appears when: (a) a roll starts on this client (the local loot window
  shows it, whoever runs the loot), or (b) `ROLL_REQ` received, or (c)
  **group-loot mode**: loot method is group and a roll-worthy item
  (quality ≥ threshold) is announced — same frame, so group loot looks
  identical to master loot from the raider's side (per requirement).
- Contents (LootBlare layout, 220×250): green countdown **status bar floating
  above the frame** with seconds text (green→orange→red, pulsing under 5s),
  big 40px item icon (hover = item tooltip, click = chat-link/dress-up) +
  quality-colored truncated name, quality-colored frame border, big countdown
  digits, **two-column roll list** — class-colored names left, `roll (min-max)`
  in roll-type color right, grouped **SR > MS > OS > TMOG**, best-first, max 8
  rows — four **dice buttons** (SR/MS/OS/TM) with colored borders, hover glow
  and tooltips, plus a top-screen huge-text **winner banner** (5s fade, winner
  in class color). Roll-list class resolution is roster-first with the SR
  sheet as fallback (see §4.8).
- First-roll-only; extra rolls ignored with notice. Auto-close timer configurable
  (`/zl time N`, `/zl autoclose on|off`).
- Draggable; `/zl show|hide`.

### 4.8 Class-colored names (`ClassColors.lua`)

- Every character name the addon renders — Sheet tab rollers/history,
  loot-window roll lists/award rows/`...` choices, award
  menu + confirm, winner banner, version grid + `/zl verlist`, drop-log
  lines — shows in its Blizzard **class color** (Paladin pink etc.).
- Source order: the **live party/raid member list first** (raid roster,
  then party units + self), **fallback to the class stored on the SR sheet**
  at import (`sheet.players`, from raidres `character.class` / legacy `role`).
  Unknown names stay plain white; solo/offline clients still get sheet colors.
- Roles carry class+spec (`PaladinHoly`): the **class prefix colors the name**,
  the spec is ignored. Case/abbreviation/file-name tolerant
  (`paladin`, `PALADIN`, `War` all resolve).
- Display-only: stored data (sheet, history, `PLAYERS` broadcast line,
  archive snapshots) keeps raw class strings, and **addon chat carries no
  color codes** — result/kind lines print plain names. Pure + headless-safe
  (nil-guarded roster APIs) with `tests/test_classcolors.lua` coverage.

### 4.4 Members grid (`VersionGrid.lua`, Members tab)

- `/zl ver` requests versions (`VER_REQ` → all clients answer `VER_ANS`).
- Sheet fetch (Members tab “Request SR sheet” button, `/zl sheetreq`):
  `SHEET_REQ` → the **master looter answers at once** with their sheet;
  the **raid leader/assistant answers after a 5s delay, only when no ML
  sheet exists** (no master loot, ML absent/unknown, or ML sheetless) —
  an arriving SHEET cancels the pending leader reply, so the group never
  gets two competing sheets. Raiders never answer. Receivers trust ONLY
  ML/leader sheets (`CanAcceptFrom` — a raider's sheet is refused even if
  one arrives). Solo: nobody to ask.
- Targeted sync (`/zl sync <name>`, bare name or color-coded `[Name]`
  player link): `SHEET_REQ:<name>` → ONLY the named player answers,
  directly (anyone holding a sheet may answer — imports are open to
  all). Trust stays on RECEIVE: a non-ML/leader answer still lands and
  is refused by `CanAcceptFrom` with the usual message.
- Wire encoding (`Comm.EncodeSheetPayload` / `SRImport.DecodeSheetPayload`):
  base64-wrapped when an encoder exists, else `%`-escaped raw (`%` →
  `%P`, `|` → `%B`). NEVER a bare `|`: ChatThrottleLib (bundled with other
  addons on this client) rejects bare pipes in chat/addon traffic with
  “Invalid escape code in chat message”. Decode order: `%B` → `|` first,
  `%P` → `%` last.
- Raid identity envelope: `SerializeSheet` leads with a
  `META;raidID=…,name=…,by=…,at=…,src=…` line (commas escaped `%C`), so a
  synced sheet shows the raid name in the header/archive instead of “—”.
  `ParseLineFormat` skips META; `ExtractMeta` strips + parses it on
  receive; legacy senders without META still get message-raidID + trusted
  sender stamped. `DeserializeSheet` applies META only where non-empty.
- Grid of **rectangles**: group first, then SR-sheet players not in the
  group. Full name in class color (outlined). Colors (muted):
  green = in group + on the sheet, red = in group + no SR,
  amber = outdated addon (beats sheet green), grey = sheet, not in group.
  Tooltip: name, version, what the color means. Self seeds on request
  (solo sends nothing, so the grid must not claim we lack the addon).
- Text list fallback via `/zl verlist`. Grid doubles as auto-resolve readiness:
  all-green ⇒ ML's `Auto-resolve` button enabled.

### 4.5 Auto-roll (`AutoRoll.lua`)

- Per-character opt-in: `/zl auto on|off` (default off). Stored in `ZugLootCharDB`.
- When a `ROLL_REQ`/warning arrives for an item the player SR'd (and hasn't won),
  auto `/roll`s with SR cap after 1s jitter (avoids thundering herd).
- **Auto-resolve**: if every eligible SR roller is version-grid green with auto-roll
  on, ML resolves immediately from `ROLL_ANS` messages (no chat-roll wait), with a
  5s fallback to normal rolling if answers are missing.

### 4.6 Simulation (`Sim.lua` + `BossData.lua` + `pfLoot.lua`)

In-game, no raid needed. **Requires the loaded sheet** — without one both
commands refuse with a pointer to `/zl import`. Every roller is a player from
the sheet; there are no fake Filler/Missroller names unless you pass N > 0.

Sim **replays the real live pipeline** (`MasterLootUI` session +
routed chat + both windows), one item at a time — it is a rehearsal of the
actual roll flow, not a separate code path. Fake echoes spread across
the SHARED roll window (same clock as live rolls — the ML rolls
alongside), the clock auto-finishes, ties auto-schedule fresh fakes:

- `/zl sim <itemLink> [N]` — one-shot: the ML chose it by typing, so it
  auto-plays immediately (still through the real pipeline: silent session,
  both windows, group-routed chat, fake echoes across the shared window,
  clock auto-finish, ties re-roll up to 3 rounds). On-sheet item: mode `SIM`, all its SR
  rollers roll (plus N optional MS fillers, flagged as miss-rolls). Off-sheet
  item: mode `SIM-OPEN`, every player on the sheet rolls (plus N fillers).
- `/zl simboss <boss>` — rolls the boss's OWN drops: with pfQuest loaded,
  the name resolves to its pfDB unit entry and the queue is filled from its
  real loot TABLES (one refloot table per gear slot, plus the direct-drop
  remainder). Each table contributes ~1 drop per kill — the weapon table,
  the armor tables, the TIER table (Ragnaros T2 pants: 30484+30547 carry
  them together, capped per pair) — so whole tables can't starve no
  matter how the per-item chances read. The index keeps EVERY drop
  (chance-0 refloot members included, weighted at a floor); the final pool
  is epic+ (`GetItemInfo` quality ≥ 4, unknown/uncached quality kept, so
  Turtle customs survive); the junk shared table (ref 30171, 76 world
  greens) contributes at most one hit per kill. Nothing is guaranteed per
  run, so consecutive runs vary. Re-rolled fresh every run. Without
  pfQuest it falls
  back to the static `BossData[boss]` table — but ALSO re-rolled fresh per
  run (shuffled random-count subset of the table, sometimes a double), so
  no two manual-test runs show the same list.
  Either way the drops land
  **same loot window** (title `Simulated loot: <boss>`, source `sim`) and
  stops: the ML — you — initiates every roll from the list (Roll button or
  `/zl simroll <item>`), in any order. After each finish the award menu
  decides the winner (headless: `/zl award <name>`); the awarded item leaves
  the list and stays gone, won marks apply immediately, so the one-win rule
  chains across drops exactly like a real
  raid night. `/zl simstop` is a full stop: kills the live session,
  drops the queue, clears the award menu, and closes the
  loot window (+ detail) and raider window — a fresh `/zl sim` can start
  immediately. `/zl cr` mid-sim returns the item to the queue head for
  a re-roll.
- Nothing auto-awards, ever: the sim replays the live menu too. After the ML
  picks, the confirm popup fires and the queue continues (in-client: as you
  accept; headless: the harness's `AwardChosen`).
- `/zl simtmog <itemLink>` — transmog demo: one roller rolls TMOG instead
  of SR; the award window offers the TMOG kind winner next to the outright
  winner and the ML awards either directly.
- Chat routing matches live rolls: raid → `RAID` + `RAID_WARNING`, party →
  `PARTY` (warnings have no party channel, so plain party text), solo → local
  chat frame. Sim sessions are silent on the addon channel (no
  `ROLL_REQ` broadcast), so other clients' windows and auto-rolls never fire.
- Every sim session is **written back into the sheet**: roll history
  (`sheet.rolls`, mode `SIM`/`SIM-OPEN`, same shape as live via
  `Resolver.ToHistoryEntry`), won marks (skipped on ties), and drop-log
  entries (source `sim`). Visible in the Sheet tab right away. `/zl reset`
  clears sim history + won marks.
- `/zl rehearse [on|off]` (Setup tab `Rehearse` button flips it) — solo
  master-loot practice, no sheet needed. While on, every solo corpse's
  non-coin rows queue with 3–5 invented rollers (Aldric, Bryn, Cora, ...) 
  and wait for the ML: each item's Roll button starts its roll through the
  same pipeline (roll window, chat-echoed fake rolls, award menu; the
  ML's own dice work too). `/zl rollauto [on|off]` (Setup `Auto-start`
  checkbox, default OFF) auto-starts rolls instead. Awarding is a REAL
  live award — the item leaves the solo corpse via the normal
  `LootSlot(slot, 1)` take — which is the point: the full distribute flow
  rehearsed end to end. Runs against a scratch sheet (real sheet parked
  and restored after; invented marks never touch it). `/zl simstop` and
  flag-off both end the run, keeping already-looted items.
- `Timer.lua` stays for the
  click-to-loot watchdog (`LootWindow.WatchClick`) and the delayed
  sheet-reply (`SRSecurity`) — sim chains no longer use it.
- Uses the **same** `Resolver` pure module as real sessions and as `tests/`, so
  sim output matches tested logic. Randomness via `math.random`, seeded by time.

### 4.7 Drop log (`DropLog.lua`)

- Every observed drop (ML loot window / announced item) appended:
  `{ time, itemID, itemLink, source(boss/manual), strategy, winner, price:nil }`.
- `/zl log` prints the log to chat (newest first), `/zl logclear` (ML/RL only).
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
  MasterLootUI.lua   ML console + session control + award menu + confirm
  LootWindow.lua     ML loot list (numbered icon/name/SR-HR rows + row detail)
  RaiderLootUI.lua   LootBlare-like frame incl. group-loot display
  AutoRoll.lua       auto-roll + auto-resolve eligibility
  VersionGrid.lua    members grid + version request handling
  BossData.lua       static fallback boss→items tables for simboss
  pfLoot.lua         pfQuest loot lookup (name->entry->weighted drops)
  RaidArchive.lua    raid history snapshots: view / continue past raids
  Sim.lua            /zl sim, /zl simboss, /zl simtmog, /zl simroll (uses Resolver)
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
/zl raids            open raid history
/zl raid <raidID>   activate an archived raid (continue it)
/zl import           open import frame (anyone; broadcast stays ML/RL)
/zl loadfile         import from CustomData/ZugLoot_SR.txt (anyone)
/zl rf <link>        start SR roll (ML)        /zl arf <link>  open roll
/zl rr <link>        raid-roll: numbered raid, ML rolls 1-N (RollFor parity)
/zl roll <item>      roll one loot-window item (ML, live corpse loot)
/zl award <name>     award the finished roll to <name> (ML, from the menu)
/zl fr [item]      finish a roll early (parks it for award; Continue reopens)
/zl cr [item]      cancel a roll (returns loot item to open)
/zl show|hide        raider frame toggle
/zl time N           roll window seconds       /zl autoclose on|off
/zl auto on|off      auto-roll SR items (per char)
/zl ver | /zl verlist version grid | text list
/zl sim <link> [N]   simulate one item (auto-plays: the ML chose it)
/zl simboss <boss>   queue boss drops in the loot window (ML rolls each)
/zl simtmog <link>   transmog demo (TMOG kind winner awardable)
/zl simroll <item>   roll one queued sim item (ML)
/zl simstop          full stop: session, timers, queue, menus, windows reset
/zl log | /zl logclear drop log
/zl lootdebug       verbose click-to-loot logging (slot, corpse size, link)
/zl lootframe       toggle corpse-loot window: ZugLoot vs Blizzard's (persisted;
                    auto-stands-down if ZugLoot clicks stop reaching the server)
/zl rehearse [on|off] solo master-loot practice: corpse items roll with invented
                    raiders (3-5 rolls), awards loot the corpse for real.
                    No sheet needed; real sheet stays loaded, invented names
                    fenced off it.
/zl rollauto [on|off] auto-start rolls as corpses are looted (default OFF:
                    the ML picks each item's Roll button). General master-loot
                    behaviour; rehearsal inherits it.
/zl reset            clear roll log: sessions + won marks (ML/RL in group, anyone solo)
                    (Setup tab "Reset all settings" = full factory reset with confirm)
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
