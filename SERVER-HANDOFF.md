# Server-Handoff (macOS übernimmt laufende Turns)

> Status: **v3 umgesetzt** (Version 2.6, Stand 2026-08-12).
> v1: CloudKit-Handoff über das SwiftData-Mirroring (Record-Type
> `CD_HandoffRequest`), inkl. Notification-Suppression beim Claim-Cancel.
> v2: Completion-Notification auf iOS via Silent Push (CKQuerySubscription).
> v3: **Direkter CloudKit-Kanal** (Record-Type `HandoffRequest`, ohne
> Mirroring) + Compare-and-Swap-Claim. Grund: Das SwiftData/CloudKit-
> Mirroring exportiert auf iOS nicht, solange die App im Hintergrund ist —
> ein gemirrorter Request erreichte den Server also nie rechtzeitig (v1/v2
> waren damit strukturell funktionslos, beobachtet 2026-08-12: Titel-Updates
> erschienen auf dem Mac erst nach dem nächsten Öffnen der iOS-App).
>
> **Vor dem nächsten TestFlight-Release:** Der Record-Type `HandoffRequest`
> (plain, kein `CD_`-Prefix) ist neu → einmal mit einem Debug-Build einen
> Request schreiben (damit landet der Type in Development), dann in der
> CloudKit Console unter Schema → Record Types → `HandoffRequest` → Indexes
> den Index **`recordName` → Queryable** hinzufügen (JIT-Schema setzt das
> Systemfeld nicht automatisch; ohne ihn schlägt jede Query mit «Field
> 'recordName' is not marked queryable» fehl), danach Schema → Deploy
> Schema Changes to Production (Prozedur in AGENTS.md). Die alte
> v1-Subscription `handoff-requests` wird beim ersten Lauf automatisch
> gelöscht und durch `handoff-requests-v2` ersetzt; alte
> `CD_HandoffRequest`-Records im Container sind Waisen und stören nicht.

## Grundidee

Die normale **macOS-Chatter-App** fungiert als Server — kein separates
Binary, kein Toggle, kein Pairing. Sie hat alles Nötige: `ChatEngine`,
`OllamaService`, MCP-Verbindungen und über dieselbe Apple-ID dieselbe
private CloudKit-DB. Jeder Mac mit laufender App ist ein potenzieller
Handoff-Server; die Geräte eines Accounts sind gleichwertig (keine Wahl,
kein Leader).

Der Steuerkanal ist **CloudKit** — kein Listener, kein offener Port, kein
Entitlement, keine Token-Kopplung (die Apple-ID ist die Authentisierung).
Funktioniert über LAN, Tailscale und Internet gleichermassen.

**Wichtig (v3):** Die `HandoffRequest`-Records werden **direkt** über die
CloudKit-API gelesen und geschrieben (`HandoffChannel`), nicht über das
SwiftData-Mirroring. Mirroring-Exporte pausieren auf iOS im Hintergrund;
direkte Writes laufen, solange der Prozess lebt — und genau das garantiert
der `TurnRuntimeKeeper` während eines Turns. Die eigentlichen Chat-Daten
(Messages etc.) syncen weiterhin über SwiftData — der Server schreibt sie
auf dem Mac, wo die App nicht suspendiert.

## Ablauf

```mermaid
sequenceDiagram
    participant iOS as iOS App
    participant CK as CloudKit (direkt)
    participant S as macOS (HandoffServer)
    iOS->>CK: HandoffRequest {sessionID} (bei scenePhase .background mit laufendem Turn)
    iOS->>iOS: lokaler Turn läuft weiter (TurnRuntimeKeeper)
    Note over S: poll alle 15 s (CKQuery)
    S->>CK: Claim (claimedBy/claimedAt) als Compare-and-Swap
    CK-->>iOS: Silent Push → iOS stoppt lokalen Turn (reason: .handoff)
    S->>S: Turn via ChatEngine; Messages via SwiftData-Sync
    S->>CK: Heartbeat alle 60 s (claimedAt erneuert)
    S->>CK: completedAt + preview
    CK-->>iOS: Silent Push → lokale Notification «Antwort fertig»
```

### Regeln (HandoffCoordinator)

- **Grace**: Ein Request darf frühestens nach 60 s geclaimt werden — die
  lokale Hintergrundlaufzeit des anfragenden Geräts hat Vortritt.
- **Max-Alter**: Requests älter als 2 h gelten als tot (Prune).
- **Claim als Compare-and-Swap**: Der Mac liest den Record frisch, prüft
  die Eligibility gegen den frischen Stand und speichert mit
  `.ifServerRecordUnchanged`. Verliert ein zweiter Mac das Rennen, schlägt
  nur sein Save fehl — kein Sleep-and-Verify wie in v1/v2.
- **Heartbeat**: Während der Server-Turn läuft, wird `claimedAt` alle 60 s
  erneuert; ein Claim ohne Heartbeat seit > 5 min gilt als abgestürzt und
  darf von einem anderen Mac übernommen werden.
- **Suppression**: Stoppt iOS den lokalen Turn wegen eines Claims
  (`stopTurn(reason: .handoff)`), wird **keine** Completion-Notification
  geschickt und der Request offen gelassen — der Server meldet den Abschluss.
- **Cancel**: Kehrt die App in den Vordergrund zurück, zieht sie ihre
  **eigenen** offenen Requests zurück (`cancelledAt`; Scope über
  `requestedBy` = `AppSettings.deviceID` — Requests anderer Geräte des
  Accounts bleiben unberührt); ein laufender Server-Turn wird davon nicht
  abgebrochen und meldet trotzdem `completedAt`.
- **Create-first**: iOS schreibt den Request ohne vorherige Abfrage —
  eine Query auf einen noch nicht existierenden Record-Type schlägt fehl,
  also würde ein Pre-Create-Fetch den allerersten Request verhindern
  (Henne-Ei; genau daran ist das initiale Schema-Deployment gescheitert).
  Dedup läuft in-memory (`publishedHandoffs`); verirrte Duplikate
  (Prozess-Kill zwischen zwei Backgroundings) filtert der Server über
  `isStaleDuplicate` (gleiche Session, anderer Request jünger completed
  oder live geclaimt) und lässt sie altern.
- **Dangling Streams**: Der Server schliesst vor dem Turn alle
  `isStreaming`-Flags der Session (das anfragende Gerät kann mitten im
  Stream gestorben sein).

## Komponenten

- `Chatter/Services/HandoffChannel.swift` — direkter CloudKit-Zugriff:
  Query (`fetchAll`, predicate-less → keine Index-Anforderungen), Create,
  Claim (CAS), Heartbeat, Complete, Cancel, Prune, plus die iOS-Push-
  Subscription (`CKQuerySubscription` auf `HandoffRequest`, silent).
- `Chatter/Services/HandoffCoordinator.swift` — der Request als Value-Typ
  (`struct HandoffRequest`) + Claim-/Filter-Regeln, plattform- und
  persistenzfrei (unit-getestet, `HandoffCoordinatorTests`).
- `Chatter/Services/HandoffServer.swift` — macOS-Seite: 15-s-Polling, Claim,
  Turn-Ausführung via `AppEnvironment.runTurn` + `engine.regenerate`.
- iOS-Seite in `AppEnvironment` (`requestHandoffsForActiveTurns`,
  `reconcileHandoffsOnActive`, `handleHandoffPush`) und `ChatterApp`
  (scenePhase-Hook, `UIApplicationDelegateAdaptor` für Silent Pushes).
- `AppSettings.deviceID` — stabile, nicht gesyncte Geräte-ID für Claims.

## Bekannte Grenzen (bewusst akzeptiert)

- **Pickup-Latenz**: bis zu ~15 s Polling + 60 s Grace → der TurnRuntimeKeeper
  überbrückt das lokal; ohne Server exakt das Verhalten von 2.4.
- **Poll-Kosten**: Der Mac feuert alle 15 s eine CKQuery ab (predicate-less
  über einen winzigen Record-Type). Preis für die einfache, push-lose
  Server-Seite; im Gegenzug entfällt jede Server-Subscription.
- **Request-Write braucht Netz im Hintergrund**: Der Write beim
  Backgrounding läuft, solange der Prozess lebt (TurnRuntimeKeeper). Stirbt
  iOS den Prozess sofort (Speicherdruck), geht der Request verloren — der
  lokale Turn läuft dann ohnehin nicht weiter, also kein Verlust gegenüber
  2.4.
- **Silent Pushes sind best-effort**: Die Completion-Notification kann
  ausfallen; die Daten syncen unabhängig davon, beim nächsten Öffnen wird
  nachgeholt (`reconcileHandoffsOnActive`).
- **Duplikat-Fenster**: Sieht iOS den Claim nicht (Push gedrosselt), laufen
  lokaler und Server-Turn kurz parallel — es entstehen ggf. eine halbe
  lokale und eine volle Server-Antwort in derselben Session.
- **`orderIndex`-Kollisionen** bei echtem Gleichzeit-Schreiben zweier Geräte
  in dieselbe Session bleiben ein generelles Thema (nicht handoff-spezifisch).
- **Lokal-Modus ohne iCloud**: kein Handoff (`Persistence.storeMode ==
  .cloudKit` ist Voraussetzung). Ein Bonjour-Listener als
  sub-Sekunden-/Lokal-Variante bleibt denkbar, ist aber bewusst nicht
  gebaut.
- **API-Key auf dem Mac**: Fehlt er dort (iCloud-Keychain nicht gesynct),
  schlägt der Server-Turn fehl und meldet das als `preview`.

## Verworfene Alternativen

- **SwiftData-Mirroring als Steuerkanal (v1/v2)**: Mirroring-Exporte
  pausieren auf iOS im Hintergrund — der Request kam nie rechtzeitig an.
  Genau dafür war der Kanal gedacht; strukturell ungeeignet.
- **Bonjour-Listener (`NWListener` + `POST /handoff`)**: sub-Sekunden-Handoff
  ist ohne User in der App wertlos; die CloudKit-Variante spart Entitlement,
  Pairing, Bonjour-Plist und Angriffsfläche.
- **Server-Modus-Toggle**: unnötig — ohne Requests kostet der Server eine
  kleine Query alle 15 s; Zugriffskontrolle ist die Apple-ID.
- **BGTaskScheduler/BGProcessingTask** für den Handoff selbst: muss im
  Voraus geplant werden, nicht für usergestartete Arbeit.
