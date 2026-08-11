# Foton Kanban — Spezifikation

Native macOS-App zur Steuerung der Musikproduktion im eigenen Tonstudio.
Ein Track ist die Arbeitseinheit, ein Release das Planungsziel.

## 1. Kernmodell

### Board

Ein klassisches Kanban mit vier Spalten. Die **vertikale Position innerhalb
einer Spalte ist die Priorität** — oben steht, was als Nächstes drankommt.

| Spalte |
|---|
| open |
| in progress |
| in review |
| done |

### Phase

Woran gerade gearbeitet wird, ist eine **Eigenschaft des Tracks**, keine
Board-Achse — im Kern eine Unterteilung von `in progress`. Sie steht als Badge
auf der Karte und lässt sich im Inspector setzen.

| Phase | Reihenfolge |
|---|---|
| Jam Session | 1 |
| Arrangement | 2 |
| Mixdown | 3 |
| FX finalizing | 4 |
| Mastering | 5 |

**Die einzige Automatik** hängt an der Review: Wandert ein Track von
`in review` nach `done`, gilt die Review als bestanden. Vor dem Mastering rückt
er dann in die nächste Phase und geht zurück auf `in progress`; nach bestandenem
Mastering ist er fertig und bleibt in `done`. Alles andere ist ein schlichter
Spaltenwechsel — wer einen Track direkt auf `done` zieht, markiert ihn von Hand
als fertig.

Ein Track, der eine Review nicht besteht, wandert zurück nach `in progress` und
behält seine Phase.

### Release

Ein Release ist eine eigenständige Entität mit eigenem Zustand, nicht bloß ein
Tag. Tracks referenzieren es über ein Feld — deshalb ist ein Track zwischen
Releases verschiebbar, ohne dass eine Datei den Ordner wechselt.

Zustände: `planned` → `in progress` → `released`.

Ein Track **kann** ohne Release existieren (Backlog-Pool: Ideen, angefangene
Sachen, Tracks die es nicht ins letzte Release geschafft haben).

### Abhör-Checkliste

Jeder Track hat eine Checkliste der Abhörsituationen mit Häkchen und Notiz pro
Eintrag. **Welche Situationen es gibt, steht in der Konfiguration** — der Track
speichert nur den Zustand dazu. Eine neu hinzugefügte Situation erscheint
dadurch auf allen Tracks, statt dass ältere bei der alten Liste hängenbleiben.

Vorgabe: Auto, AirPods, Bose Kopfhörer, Bose Lautsprecher, Studio, Studio 45°
(der Master, abgehört 45° neben dem Lautsprecher). Kopfhörer und Lautsprecher
desselben Herstellers klingen verschieden genug für je eine eigene Zeile.

Der Fortschritt steht als `2/6` auf der Karte, aber nur in der Mastering-Phase —
vorher sagt die Liste nichts aus. „Zurücksetzen" nimmt alle Haken zurück und
lässt die Notizen stehen; die sind der Befund vom letzten Durchgang.

Zusätzlich zählt `review-rounds`, wie oft ein Track schon in Review war. Das ist
bewusst nur eine Zahl und keine Historie: die Revisionsschleife bleibt sichtbar,
ohne dass für jede Runde ein Protokoll mitgeführt wird.

### Bounces

Die abgelegten Fassungen eines Songs werden **nicht am Track gespeichert**,
sondern bei jedem Laden im Previews-Ordner gesucht. Damit ist die Verknüpfung
nie veraltet: Ein neuer Bounce im Ordner ist sofort die aktuelle Fassung.

Der Songname wird aus dem Dateinamen gewonnen, indem Datum, Uhrzeit,
Füllwörter (`preview`, `MASTER`) und eine führende Titelnummer entfernt werden.
Dieselbe Bereinigung greift auf den Track-Titel, weil manche Titel aus dem
Jira-Import selbst Dateinamen sind. Verglichen wird erst exakt, dann unscharf
über Damerau-Levenshtein ab einer Ähnlichkeit von 0,86 — das fängt Dreher wie
`Slwo` gegen `Slow` ab, ohne verschiedene Songs zu verwechseln.

Das **Datum stammt aus dem Dateinamen**, nicht aus dem Änderungsdatum: Ein
Sync schreibt Zeitstempel neu, der Name bleibt.

Passt kein Name, zieht man die Datei auf die Karte. Das schreibt `audio:` in
die Track-Datei, und dieser Pfad gewinnt gegen die Suche — der einzige Fall,
in dem etwas gespeichert wird.

## 2. Speicherformat

Ein Markdown-File pro Track, eines pro Release. Ein Git-Repository als
Verzeichnis — Git ist zugleich Historie und (ab v2) Sync-Mechanismus.

```
FotonKanban/                     ← Git-Repo, Ort frei wählbar
├── tracks/
│   ├── k3f9-ferrite.md
│   └── m8x2-nightdrive.md
├── releases/
│   └── r-2026-09.md
├── archive/                     ← abgeschlossene Releases samt Tracks
└── .foton/config.md             ← Abhörsituationen, Kadenz, Previews-Ordner
```

### Track

```markdown
---
id: k3f9
title: Ferrite
phase: mastering
status: review
release: r-2026-09
order: 1000
review-rounds: 2
created: 2026-06-14T09:12:00+02:00
updated: 2026-08-02T18:40:00+02:00
tags: [synth, dark]
---

## Notizen

Bassline ab 1:40 zu dominant.

## Checkliste

- [x] Auto — ok
- [x] AirPods — Bass zu laut, 80–120 Hz
- [ ] Bose Kopfhörer
- [ ] Bose Lautsprecher
- [ ] Studio
- [ ] Studio 45°
```

### Release

```markdown
---
id: r-2026-09
title: EP 04
target: 2026-09-18
state: in-progress
created: 2026-05-02T11:00:00+02:00
updated: 2026-08-02T18:40:00+02:00
---

## Notizen

Vier Tracks, Vinyl-Master separat.
```

### Regeln

- `id` ist die Identität, nicht der Dateiname. Der Dateiname wird beim Anlegen
  aus dem Titel abgeleitet und bleibt danach stabil.
- `order` in Tausenderschritten, kleiner Wert heißt weiter oben und damit
  wichtiger. Einfügen zwischen zwei Karten nimmt die Mitte; nur bei erschöpftem
  Abstand wird die Spalte neu nummeriert.
- Eine Board-Aktion berührt genau eine Datei. Es gibt keine zentrale Index- oder
  Reihenfolge-Datei — das ist die Voraussetzung für konfliktarmen Sync.
- Schreiben ist atomar (temporäre Datei, dann `rename`).
- `updated` wird bei jeder Änderung durch die App gesetzt.
- Der Parser ist tolerant: unbekannte Frontmatter-Keys und unbekannte
  Body-Abschnitte bleiben beim Speichern unverändert erhalten. Ein
  `## Reviews`-Abschnitt aus einer früheren Fassung überlebt so den Umstieg.

## 3. Ansichten

### Board
Vier Spalten, Karten nach Priorität. Drag & Drop zwischen Spalten und innerhalb
einer Spalte; auf eine Karte gezogen, landet die gezogene davor und bekommt
damit die höhere Priorität. Filterleiste: Release, Tag, Freitextsuche. Karte
zeigt Titel, Phase, Checklisten-Fortschritt, Rundenzahl und Release.

### Track-Inspector
Seitenpanel: Titel, Phase, Spalte, Release-Zuordnung, Tags, Notizen,
Abhör-Checkliste mit Zurücksetzen.

### Jahresansicht
12-Monats-Zeitstrahl mit den Releases als Blöcke auf ihrem Zieldatum. Releases
werden von Hand gesetzt und per Datumsfeld verschoben. Zwischen
aufeinanderfolgenden Releases wird der Abstand in Wochen angezeigt, damit eine
gleichmäßige Kadenz (Richtwert 6 Wochen) sichtbar wird. Pro Release: Anzahl
Tracks und wie viele davon fertig sind.

### Backlog
Tracks ohne Release. Auswahl über die Seitenleiste.

## 4. Architektur

Reines macOS-Ziel, SwiftUI, Swift 6.3.

**`FotonKanbanCore`** (Swift Package, plattformneutral)
- Modelle: `Track`, `Release`, `ListeningCheck`, `Phase`, `Status`, `Config`
- `MarkdownCodec` — formatschonendes Parsen und Serialisieren
- `TrackStore` (Protokoll) + `FileTrackStore` (Implementierung)
- `FolderWatcher` — FSEvents, erkennt externe Änderungen und lädt nach
- `GitSync` (ab v2)

**`FotonKanban`** (App-Target)
- Board, Inspector, Jahresansicht, Backlog
- Ordnerauswahl beim ersten Start, gemerkt als Bookmark statt als Pfad, damit
  ein Verschieben des Ordners die Verknüpfung nicht zerreißt
- Ohne App-Sandbox, weil ein beliebiger Ordner im Dateisystem gelesen und
  geschrieben wird und die App nicht über den App Store läuft

Das `TrackStore`-Protokoll ist die Naht, an der später ein HTTP-Backend
eingesetzt werden könnte, falls die Git-Synchronisation je nicht mehr reicht.

## 5. Ausbaustufen

**v1 — lokal, ein Rechner**
Board mit Drag & Drop, Track- und Release-Verwaltung, Abhör-Checkliste, Backlog,
Jahresansicht, Markdown-Persistenz, Ordnerüberwachung. Kein Netzwerk, kein Git.

**v2 — Sync**
Git-Anbindung: automatischer Commit bei Änderung, Pull/Push beim
Fenster-Fokuswechsel und in Intervallen, Konfliktanzeige in der App.
Remote: privates Repo oder selbstgehostetes Forgejo.

**v3 — Kür**
Archivierung veröffentlichter Releases, Statistik über Phasendauern,
Volltextsuche, Quick-Entry per Menüleiste.

## 6. Bewusst nicht enthalten

- Zeiterfassung und Abrechnung
- Anhänge und Dateiverwaltung; Bounces werden nur gelesen, nie geschrieben
- Wiedergabe in der App — Bounces öffnen im Standardprogramm
- Historie einzelner Review-Runden (nur der Zähler)
- Mehrbenutzerbetrieb, Rechte, Server-Backend
- iOS
