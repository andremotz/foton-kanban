import Foundation
import Testing

@testable import FotonKanbanCore

@Suite("Dateispeicher")
struct FileTrackStoreTests {
    /// Jeder Test bekommt einen eigenen Ordner, der danach wieder verschwindet.
    private func withTemporaryStore(_ body: (FileTrackStore, URL) throws -> Void) throws {
        let root = URL.temporaryDirectory.appending(path: "foton-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try body(FileTrackStore(root: root), root)
    }

    @Test("Leerer Ordner wird angelegt und liefert die Vorgabe-Konfiguration")
    func preparesEmptyFolder() throws {
        try withTemporaryStore { store, root in
            let repository = try store.load()

            #expect(repository.tracks.isEmpty)
            #expect(repository.releases.isEmpty)
            #expect(repository.config == .default)
            #expect(FileManager.default.fileExists(atPath: root.appending(path: "tracks").path()))
            #expect(FileManager.default.fileExists(atPath: root.appending(path: ".foton/config.md").path()))
        }
    }

    @Test("Track überlebt Speichern und Neuladen")
    func savesAndReloads() throws {
        try withTemporaryStore { store, _ in
            _ = try store.load()

            var track = Track(id: "k3f9", title: "Ferrite", phase: .mastering, release: "r-2026-04")
            track.move(to: .review)
            track.reconcileChecks(with: .default)
            track.checks[0].isChecked = true
            track.checks[0].note = "ok"
            try store.save(track)

            let reloaded = try #require(try store.load().tracks.first)
            #expect(reloaded.id == "k3f9")
            #expect(reloaded.title == "Ferrite")
            #expect(reloaded.phase == .mastering)
            #expect(reloaded.status == .review)
            #expect(reloaded.release == "r-2026-04")
            #expect(reloaded.reviewRounds == 1)
            #expect(reloaded.checks.count == Config.default.listeningSituations.count)
            #expect(reloaded.checks[0] == ListeningCheck(situation: "Auto", isChecked: true, note: "ok"))
        }
    }

    @Test("Dateiname wird aus dem Titel abgeleitet und bleibt danach stabil")
    func fileNameStaysStable() throws {
        try withTemporaryStore { store, root in
            _ = try store.load()
            var track = Track(id: "k3f9", title: "Für Elise (Späte Fassung)")
            try store.save(track)

            let tracksDirectory = root.appending(path: "tracks")
            let before = try FileManager.default.contentsOfDirectory(atPath: tracksDirectory.path())
            #expect(before == ["k3f9-fuer-elise-spaete-fassung.md"])

            track.title = "Ganz anderer Titel"
            try store.save(track)

            let after = try FileManager.default.contentsOfDirectory(atPath: tracksDirectory.path())
            #expect(after == before)
            #expect(try store.load().tracks.first?.title == "Ganz anderer Titel")
        }
    }

    @Test("Ein Release-Wechsel verschiebt keine Datei")
    func changingReleaseKeepsFile() throws {
        try withTemporaryStore { store, root in
            _ = try store.load()
            var track = Track(id: "k3f9", title: "Ferrite", release: "r-2026-04")
            try store.save(track)

            let path = try #require(
                try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "tracks").path()).first
            )

            track.release = "r-2026-05"
            try store.save(track)

            let after = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "tracks").path())
            #expect(after == [path])
            #expect(try store.load().tracks.first?.release == "r-2026-05")
        }
    }

    @Test("Unlesbare Dateien werden gemeldet, nicht verschluckt")
    func reportsSkippedFiles() throws {
        try withTemporaryStore { store, root in
            _ = try store.load()
            try "Nur eine Notiz ohne Frontmatter.\n".write(
                to: root.appending(path: "tracks/notiz.md"), atomically: true, encoding: .utf8
            )

            let repository = try store.load()
            #expect(repository.tracks.isEmpty)
            #expect(repository.skippedFiles == ["notiz.md"])
        }
    }

    @Test("Löschen entfernt die Datei")
    func deletesFile() throws {
        try withTemporaryStore { store, root in
            _ = try store.load()
            try store.save(Track(id: "k3f9", title: "Ferrite"))
            try store.delete(trackID: "k3f9")

            let remaining = try FileManager.default.contentsOfDirectory(
                atPath: root.appending(path: "tracks").path()
            )
            #expect(remaining.isEmpty)
        }
    }

    @Test("Eine neue Abhörsituation erscheint beim Laden auf bestehenden Tracks")
    func newSituationAppearsOnReload() throws {
        try withTemporaryStore { store, root in
            _ = try store.load()
            try store.save(Track(id: "k3f9", title: "Ferrite", checks: [
                ListeningCheck(situation: "Auto", isChecked: true)
            ]))

            let reloaded = try #require(try store.load().tracks.first)
            #expect(reloaded.checks.map(\.situation) == Config.default.listeningSituations)
            #expect(reloaded.checks[0].isChecked)
        }
    }

    @Test("Repository-Abfragen für Board, Backlog und Termine")
    func repositoryQueries() throws {
        let repository = Repository(
            tracks: [
                Track(id: "a", title: "A", phase: .mixdown, status: .open, release: "r1", order: 2000),
                Track(id: "b", title: "B", phase: .arrangement, status: .open, release: "r1", order: 1000),
                Track(id: "c", title: "C", phase: .mastering, status: .done, order: 1000),
            ],
            releases: [
                Release(id: "r2", title: "EP 05", target: DateFormatting.day(from: "2026-11-01")),
                Release(id: "r1", title: "EP 04", target: DateFormatting.day(from: "2026-09-18")),
                Release(id: "r3", title: "Ohne Termin"),
            ]
        )

        #expect(repository.tracks(in: .open).map(\.id) == ["b", "a"])
        #expect(repository.backlog.map(\.id) == ["c"])
        #expect(repository.tracks(inRelease: "r1").map(\.id) == ["b", "a"])
        #expect(repository.scheduledReleases.map(\.id) == ["r1", "r2", "r3"])
        #expect(repository.release("r1")?.title == "EP 04")
    }
}
