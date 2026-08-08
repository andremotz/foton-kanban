import Foundation
import Testing

@testable import FotonKanbanCore

@Suite("Markdown-Codec")
struct MarkdownCodecTests {
    /// Enthält bewusst einen Frontmatter-Schlüssel und einen Abschnitt, die die
    /// App nicht kennt.
    static let sample = """
        ---
        id: k3f9
        title: Ferrite
        phase: mixdown
        status: review
        release: r-2026-04
        order: 2000
        created: 2026-06-14T09:12:00+02:00
        updated: 2026-08-02T18:40:00+02:00
        review-rounds: 2
        tags: [synth, dark]
        bpm: 128
        ---

        ## Notizen

        Bassline ab 1:40 zu dominant.

        - [ ] Sidechain prüfen

        ## Checkliste

        - [x] Auto — ok
        - [ ] Bose

        ## Referenzen

        Vergleichsmix von 2024.
        """

    @Test("Felder werden vollständig gelesen")
    func decodesFields() throws {
        let track = try MarkdownCodec.decodeTrack(Self.sample, fallbackID: "xxxx")

        #expect(track.id == "k3f9")
        #expect(track.title == "Ferrite")
        #expect(track.phase == .mixdown)
        #expect(track.status == .review)
        #expect(track.release == "r-2026-04")
        #expect(track.order == 2000)
        #expect(track.tags == ["synth", "dark"])
        #expect(track.notes.contains("Bassline ab 1:40"))
        #expect(track.reviewRounds == 2)
        #expect(track.checks == [
            ListeningCheck(situation: "Auto", isChecked: true, note: "ok"),
            ListeningCheck(situation: "Bose"),
        ])
    }

    @Test("Unbekannte Schlüssel und Abschnitte überleben den Roundtrip")
    func preservesUnknownContent() throws {
        let track = try MarkdownCodec.decodeTrack(Self.sample, fallbackID: "xxxx")

        #expect(track.unknownFrontmatter["bpm"] == .scalar("128"))
        #expect(track.extraSections.map(\.heading) == ["Referenzen"])

        let encoded = MarkdownCodec.encode(track)
        #expect(encoded.contains("bpm: 128"))
        #expect(encoded.contains("## Referenzen"))
        #expect(encoded.contains("Vergleichsmix von 2024."))
    }

    @Test("Zweimal schreiben ergibt dasselbe Ergebnis")
    func encodingIsIdempotent() throws {
        let once = MarkdownCodec.encode(try MarkdownCodec.decodeTrack(Self.sample, fallbackID: "x"))
        let twice = MarkdownCodec.encode(try MarkdownCodec.decodeTrack(once, fallbackID: "x"))

        #expect(once == twice)
    }

    @Test("Abhör-Checkliste wird mit Häkchen und Notiz gelesen")
    func decodesListeningChecks() throws {
        let markdown = """
            ---
            id: aa11
            title: Kalt
            phase: mastering
            status: review
            ---

            ## Checkliste

            - [x] Auto — ok
            - [x] AirPods — Bass zu laut, 80–120 Hz
            - [ ] Bose
            - [ ] Studio
            - [ ] Studio 45°
            """

        let track = try MarkdownCodec.decodeTrack(markdown, fallbackID: "aa11")

        #expect(track.checks.count == 5)
        #expect(track.checks[0] == ListeningCheck(situation: "Auto", isChecked: true, note: "ok"))
        #expect(track.checks[1].note == "Bass zu laut, 80–120 Hz")
        #expect(track.checks[4] == ListeningCheck(situation: "Studio 45°"))
        #expect(track.checklistBadge == "2/5")
    }

    @Test("Ein alter Reviews-Abschnitt geht beim Umstieg nicht verloren")
    func keepsLegacyReviewSection() throws {
        let markdown = """
            ---
            id: aa11
            title: Kalt
            ---

            ## Reviews

            ### R1 — mixdown — 2026-07-22 — überarbeitet
            Zu wenig Luft in den Höhen.
            """

        let track = try MarkdownCodec.decodeTrack(markdown, fallbackID: "aa11")
        #expect(track.extraSections.map(\.heading) == ["Reviews"])

        let encoded = MarkdownCodec.encode(track)
        #expect(encoded.contains("## Reviews"))
        #expect(encoded.contains("Zu wenig Luft in den Höhen."))
    }

    @Test("Titel mit Doppelpunkt wird zitiert und wieder korrekt gelesen")
    func quotesAmbiguousScalars() throws {
        let track = Track(id: "bb22", title: "Ferrite: Reprise", notes: "")
        let encoded = MarkdownCodec.encode(track)

        #expect(encoded.contains(#"title: "Ferrite: Reprise""#))
        #expect(try MarkdownCodec.decodeTrack(encoded, fallbackID: "x").title == "Ferrite: Reprise")
    }

    @Test("Datei ohne Frontmatter gehört nicht zum Board")
    func rejectsPlainMarkdown() {
        #expect(throws: MarkdownCodecError.notAKanbanFile) {
            try MarkdownCodec.decodeTrack("# Nur eine Notiz\n", fallbackID: "x")
        }
    }

    @Test("Fehlende Felder fallen auf Vorgaben zurück")
    func toleratesMissingFields() throws {
        let track = try MarkdownCodec.decodeTrack("---\ntitle: Skizze\n---\n", fallbackID: "m8x2")

        #expect(track.id == "m8x2")
        #expect(track.phase == .jamSession)
        #expect(track.status == .open)
        #expect(track.release == nil)
        #expect(track.order == Ordering.step)
    }

    @Test("Release-Roundtrip")
    func releaseRoundtrip() throws {
        let markdown = """
            ---
            id: r-2026-04
            title: EP 04
            target: 2026-09-18
            state: in-progress
            ---

            ## Notizen

            Vier Tracks, Vinyl-Master separat.
            """

        let release = try MarkdownCodec.decodeRelease(markdown, fallbackID: "x")
        #expect(release.title == "EP 04")
        #expect(release.state == .inProgress)
        #expect(DateFormatting.day(try #require(release.target)) == "2026-09-18")
        #expect(release.notes == "Vier Tracks, Vinyl-Master separat.")

        // Zeitstempel werden auf Sekunden gerundet geschrieben, deshalb wird
        // die Stabilität der Datei geprüft und nicht die Gleichheit der Dates.
        let encoded = MarkdownCodec.encode(release)
        #expect(MarkdownCodec.encode(try MarkdownCodec.decodeRelease(encoded, fallbackID: "x")) == encoded)
    }

    @Test("Konfiguration fällt bei leeren Werten auf die Vorgabe zurück")
    func configFallsBack() {
        #expect(MarkdownCodec.decodeConfig("kein frontmatter") == .default)
        #expect(
            MarkdownCodec.decodeConfig("---\nlistening-situations: []\n---\n").listeningSituations
                == Config.default.listeningSituations
        )

        let custom = Config(listeningSituations: ["Auto", "Laptop"], releaseCadenceWeeks: 8)
        #expect(MarkdownCodec.decodeConfig(MarkdownCodec.encode(custom)) == custom)
    }
}
