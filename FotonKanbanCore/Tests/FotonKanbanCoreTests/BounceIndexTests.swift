import Foundation
import Testing

@testable import FotonKanbanCore

@Suite("Dateinamen von Bounces")
struct BounceNamingTests {
    /// Die Muster stammen aus einem echten Previews-Ordner — das Datum steht
    /// mal vorn, mal hinten, mit und ohne Uhrzeit, mit Titelnummer davor.
    @Test(
        "Songname wird aus jedem gebräuchlichen Muster gewonnen",
        arguments: [
            ("Ferrite preview 2022-12-28", "Ferrite"),
            ("Slow Static preview 2024-12-15 2307", "Slow Static"),
            ("Nightdrive 2026-04-14 MASTER", "Nightdrive"),
            ("2025-03-22 2030 Halcyon", "Halcyon"),
            ("2024-12-13 Aurora 2024 DnB Remix preview", "Aurora 2024 DnB Remix"),
            ("7_Cascade 2026-05-03 Master", "Cascade"),
            ("a Meridian 2025-11-13 Master", "Meridian"),
            ("Pulse 005 2025-02-24 0007", "Pulse 005"),
            ("Ferrite 2025-03-15 2306 ", "Ferrite"),
        ]
    )
    func extractsSongName(input: String, expected: String) {
        #expect(BounceNaming.songName(from: input) == expected)
    }

    @Test("Das Datum kommt aus dem Namen, nicht aus der Datei")
    func readsDateFromName() throws {
        let date = try #require(BounceNaming.date(from: "Nightdrive 2026-04-14 MASTER"))
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 4)
        #expect(parts.day == 14)
    }

    @Test("Eine folgende Uhrzeit trennt zwei Bounces desselben Tages")
    func readsTimeAfterDate() throws {
        let date = try #require(BounceNaming.date(from: "Slow Static preview 2024-12-15 2307"))
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        #expect(parts.hour == 23)
        #expect(parts.minute == 7)
    }

    @Test("Ohne Datum im Namen gibt es keines")
    func noDateWithoutOne() {
        #expect(BounceNaming.date(from: "Nightdrive") == nil)
    }

    @Test("Ähnlichkeit trennt Tippfehler von anderen Songs")
    func similarityDiscriminates() {
        let typo = BounceNaming.similarity(
            BounceNaming.matchKey("Slow Static"), BounceNaming.matchKey("Slwo Static")
        )
        #expect(typo >= BounceIndex.similarityThreshold)

        let different = BounceNaming.similarity(
            BounceNaming.matchKey("Halcyon"), BounceNaming.matchKey("Nightdrive")
        )
        #expect(different < BounceIndex.similarityThreshold)
    }
}

@Suite("Zuordnung von Bounces")
struct BounceIndexTests {
    private func bounce(_ stem: String, folder: String = "Previews") -> Bounce {
        let url = URL(fileURLWithPath: "/tmp/\(folder)/\(stem).aif")
        return Bounce(
            url: url,
            songName: BounceNaming.songName(from: stem),
            date: BounceNaming.date(from: stem) ?? .distantPast,
            isMaster: stem.lowercased().contains("master")
        )
    }

    @Test("Die neueste Fassung steht vorn, auch über Ordner hinweg")
    func newestFirstAcrossFolders() throws {
        let index = BounceIndex(bounces: [
            bounce("Ferrite preview 2022-05-01", folder: "2022"),
            bounce("Ferrite 2026-03-14 MASTER", folder: "2026 Album"),
            bounce("Ferrite 2025-01-09", folder: "2025"),
        ])
        let found = index.bounces(matching: "Ferrite")

        #expect(found.count == 3)
        #expect(found.first?.fileName == "Ferrite 2026-03-14 MASTER.aif")
        #expect(found.first?.isMaster == true)
        #expect(found.last?.fileName == "Ferrite preview 2022-05-01.aif")
    }

    @Test("Tippfehler im Dateinamen verhindern die Zuordnung nicht")
    func toleratesTypos() {
        let index = BounceIndex(bounces: [bounce("Slwo Static 2026-04-11 MASTER")])
        #expect(index.newestBounce(matching: "Slow Static")?.songName == "Slwo Static")
    }

    @Test("Ein Titel, der selbst ein Dateiname ist, findet trotzdem")
    func matchesTitlesThatAreFileNames() {
        let index = BounceIndex(bounces: [bounce("Halcyon 2019-02-02")])
        // So steht es nach dem Jira-Import wörtlich im Board.
        #expect(index.newestBounce(matching: "2018-03-18 Halcyon preview.mp3") != nil)
    }

    @Test("Fremde Songs werden nicht verwechselt")
    func doesNotInventMatches() {
        let index = BounceIndex(bounces: [
            bounce("Nightdrive 2026-04-14 MASTER"),
            bounce("Halcyon 2025-01-01"),
        ])
        #expect(index.bounces(matching: "Cover-Artwork bestellen").isEmpty)
        #expect(index.bounces(matching: "Zenith").isEmpty)
    }

    @Test("Ein leerer Titel liefert nichts")
    func emptyTitleFindsNothing() {
        let index = BounceIndex(bounces: [bounce("Nightdrive 2026-04-14")])
        #expect(index.bounces(matching: "   ").isEmpty)
    }

    @Test("Ein Ordner wird rekursiv eingelesen")
    func readsFolderRecursively() throws {
        let root = URL.temporaryDirectory.appending(path: "bounces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appending(path: "2026 Album")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data().write(to: sub.appending(path: "Nightdrive 2026-04-14 MASTER.aif"))
        try Data().write(to: sub.appending(path: "Notiz.txt"))

        let index = BounceIndex(root: root)
        #expect(index.count == 1)
        #expect(index.newestBounce(matching: "Nightdrive")?.isMaster == true)
    }
}

/// Prüfung gegen einen echten Previews-Ordner. Läuft nur, wenn
/// `FOTON_PREVIEWS` und `FOTON_BOARD` gesetzt sind — in der CI übersprungen.
@Suite(
    "Echter Bestand",
    .enabled(if: ProcessInfo.processInfo.environment["FOTON_PREVIEWS"] != nil)
)
struct RealCatalogTests {
    @Test("Der Grossteil der Tracks findet seine Bounce")
    func matchesMostTracks() throws {
        let environment = ProcessInfo.processInfo.environment
        let previews = URL(fileURLWithPath: try #require(environment["FOTON_PREVIEWS"]))
        let board = URL(fileURLWithPath: try #require(environment["FOTON_BOARD"]))

        var clock = Date()
        let index = BounceIndex(root: previews)
        let indexing = Date().timeIntervalSince(clock)

        clock = Date()
        let repository = try FileTrackStore(root: board).load()
        let loading = Date().timeIntervalSince(clock)

        clock = Date()
        let matched = repository.tracks.count { index.newestBounce(matching: $0.title) != nil }
        let lookup = Date().timeIntervalSince(clock)

        // Alle Zuordnungen auflisten, bei denen die Namen nicht exakt
        // übereinstimmen — dort lauern Falschtreffer.
        print("--- unscharfe Zuordnungen ---")
        for track in repository.tracks {
            guard let bounce = index.newestBounce(matching: track.title) else { continue }
            let left = BounceNaming.matchKey(BounceNaming.songName(from: track.title))
            let right = BounceNaming.matchKey(bounce.songName)
            if left != right {
                let score = BounceNaming.similarity(left, right)
                print(String(format: "%.2f  %@  →  %@", score, track.title, bounce.fileName))
            }
        }

        let share = Double(matched) / Double(repository.tracks.count)
        print("Bounce gefunden für \(matched) von \(repository.tracks.count) Tracks")
        print(
            String(
                format: "Index %.3f s · Board laden %.3f s · %d Abfragen %.3f s",
                indexing, loading, repository.tracks.count, lookup
            )
        )

        #expect(index.count > 1000)
        #expect(share > 0.75)
    }
}
