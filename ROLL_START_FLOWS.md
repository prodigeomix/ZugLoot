# Roll-start flows: live vs rehearse vs simboss

All three modes start from the master-loot window's Roll button
(`LootWindow.doAction(itemID, "roll")`) and end at
`MasterLootUI.AwardChosen -> DoAward`. What differs is the pipeline
between those points.

## Legend

| Color | Meaning |
|---|---|
| Green `#2e7d32` | Runs in **all 3 modes** (literally the same function) |
| Blue `#1565c0` | **Sim + rehearse only** (silent pipeline: `playOne`, scheduled echoes, `OnTie`, `PresentAwardMenu` silent) |
| Orange `#ef6c00` | **Live only** |
| Purple `#6a1b9a` | **Rehearse only** |
| Teal `#00838f` | **Simboss only** |

```mermaid
flowchart LR
    S["shared: all 3 modes"] --> B["shared: sim + rehearse"]
    B --> L["live only"]
    L --> R["rehearse only"]
    R --> T["simboss only"]
    classDef sharedAll,fill:#2e7d32,color:#fff,stroke:#1b5e20
    classDef sharedSim,fill:#1565c0,color:#fff,stroke:#0d47a1
    classDef liveOnly,fill:#ef6c00,color:#fff,stroke:#bf360c
    classDef rehearseOnly,fill:#6a1b9a,color:#fff,stroke:#4a148c
    classDef simOnly,fill:#00838f,color:#fff,stroke:#004d40
    class S sharedAll
    class B sharedSim
    class L liveOnly
    class R rehearseOnly
    class T simOnly
```

## 1. Normal master looting (live corpse, real raid)

```mermaid
flowchart TD
    A["doAction roll - router"] --> B{"guards: SessionFor live? ML.session busy?"}
    B -- refuse --> B1["return roll failed"]
    B -- pass --> C["DropParked - fresh roll state"]
    C --> D{"rehearse queued for itemID?"}
    D -- yes --> R["to rehearsal flow 2"]
    D -- no --> E["StartItemRoll"]
    E --> F["RequireML + sequential guards"]
    F --> G["Find live row + MarkRolling"]
    G --> H["BeginSession mode SR silent=false"]
    H --> H1["WarnGroup roll call + SendRollReq + RaiderLootUI.ShowItem"]
    H1 --> I["detail to rolling view"]
    I --> J["intake: ROLL_ANS OnRollAns, /roll IntakeChatRoll ParseSystemRoll OnSystemRoll ApplySystemRoll"]
    J --> K["Finish"]
    K --> K1["ResolveItem + AnnounceResult"]
    K1 -->|"tie"| K2["return tie - session stays open"]
    K1 -->|"winner"| L1["ParkSession + DetailOnFinish"]
    L1 --> L2["ShowAwardMenu live menu"]
    L2 --> M["AwardChosen"]
    M --> N["DoAward source=raid - LootCorpseSlot real take"]
    classDef sharedAll,fill:#2e7d32,color:#fff,stroke:#1b5e20
    classDef liveOnly,fill:#ef6c00,color:#fff,stroke:#bf360c
    classDef rehearseOnly,fill:#6a1b9a,color:#fff,stroke:#4a148c
    class A,B,H,I,J,K,K1,K2,L1,M,D sharedAll
    class B1,C,E,F,G,H1,L2,N liveOnly
    class R rehearseOnly
```

Live-only parts: `StartItemRoll`, the real broadcast (`WarnGroup` /
`SendRollReq`), the visible `ShowAwardMenu`, and the real corpse take.
Everything green runs identically in the other two modes.

## 2. Rehearsing (solo, invented rollers, real corpse take)

```mermaid
flowchart TD
    A["OnLootOpened solo + rehearse=on"] --> B["StartRehearsal"]
    B --> C["per corpse row: BuildRehearsalEntry - invented roster 3-5 + FakeRolls"]
    C --> D["pending queue"]
    D --> E{"rollAuto + idle?"}
    E -- yes --> F["StartQueuedRoll first entry"]
    E -- no --> G["wait: ML clicks Roll"]
    G --> H["doAction roll"]
    H --> II{"queued rehearse entry?"}
    II -- yes --> F
    F --> J{"ML.session busy? row still on corpse?"}
    J -- row gone --> J1["drop entry to afterRehearsal"]
    J -- ok --> K["dequeue to lives/live, running=true"]
    K --> L["playOne entry"]
    L --> M["BeginSession silent=true"]
    M --> N["stamp sess: rehearse=true invented=roster"]
    N --> O["MarkRolling + OpenDetail rolling view"]
    O --> P["scheduleFeeds: echo x N across the shared window"]
    P --> Q["shared clock auto-finish to MasterLootUI.Finish"]
    Q --> R2["PresentAwardMenu silent - menu pending"]
    R2 --> S["AwardChosen"]
    S --> T["DoAward source=raid - LootCorpseSlot REAL take"]
    T --> U["afterRehearsal to next StartQueuedRoll or EndRehearsalRun"]
    classDef sharedAll,fill:#2e7d32,color:#fff,stroke:#1b5e20
    classDef sharedSim,fill:#1565c0,color:#fff,stroke:#0d47a1
    classDef rehearseOnly,fill:#6a1b9a,color:#fff,stroke:#4a148c
    class H,M,O,S sharedAll
    class L,P,Q,R2 sharedSim
    class A,B,C,D,E,F,G,II,J,J1,K,N,T,U rehearseOnly
```

Rehearse runs the **same silent pipeline as simboss** (blue), but the
entry carries an invented roster, the session is stamped
`rehearse + invented` (fences invented names off sheet writes), and the
award is a **real** corpse take (`source='raid'`).

## 3. Simboss (fake boss drops, ML-driven, no corpse)

```mermaid
flowchart TD
    A2["simboss name to SimBoss"] --> B2["RequireSheet + Busy guard"]
    B2 --> C2{"drop source: pfLoot.BossDrops vs BossData?"}
    C2 --> D2["RollStaticDrops re-rolled subset"]
    D2 --> E2["ResetFresh"]
    E2 --> F2["per drop: BuildEntry FakeRolls SIM / SIM-OPEN"]
    F2 --> G2["pending, auto=false SyncLootWindow + Show sim loot"]
    G2 --> H2["ML clicks Roll"]
    H2 --> I2["doAction source=sim"]
    I2 --> J2["StartQueuedRoll itemID"]
    J2 --> K3{"guards: live? parked menu? ML.session busy? in queue?"}
    K3 -- refuse --> K4["Print + return"]
    K3 -- pass --> L3["dequeue to lives/live SyncLootWindow"]
    L3 --> M2["playOne entry"]
    M2 --> N2["BeginSession silent=true, no rehearse stamp"]
    N2 --> O2["MarkRolling + OpenDetail rolling view"]
    O2 --> P2["scheduleFeeds: echo x N across the shared window"]
    P2 --> Q2["shared clock auto-finish to MasterLootUI.Finish; tie = OnTie schedules fresh fakes"]
    Q2 --> R3["PresentAwardMenu silent to awaiting"]
    R3 --> S2["AwardChosen"]
    S2 --> T2["DoAward source=sim - no corpse take"]
    T2 --> U2["afterAwards to RequestNextRoll - next head or MaybeFinish"]
    classDef sharedAll,fill:#2e7d32,color:#fff,stroke:#1b5e20
    classDef sharedSim,fill:#1565c0,color:#fff,stroke:#0d47a1
    classDef simOnly,fill:#00838f,color:#fff,stroke:#004d40
    class I2,M2,O2,S2 sharedAll
    class M2,P2,Q2,R3 sharedSim
    class A2,B2,C2,D2,E2,F2,G2,H2,J2,K3,K4,L3,N2,T2,U2 simOnly
```

Simboss-only parts: fake drop sourcing (`pfLoot` / `BossData`), `BuildEntry`
with `FakeRolls`, `StartQueuedRoll` (sim queue guards), and the `source='sim'`
award with no corpse take. The middle of the pipe — `playOne`,
`BeginSession`, chat-intake `feedRoll`, `Finish`, `AwardChosen` — is shared
with rehearsal (blue) and, for the green nodes, with live loot too.
