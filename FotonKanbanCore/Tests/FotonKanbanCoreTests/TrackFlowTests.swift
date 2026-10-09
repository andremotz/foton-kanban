import Foundation
import Testing

@testable import FotonKanbanCore

@Suite("Spaltenwechsel und Phasen")
struct TrackFlowTests {
    private func track(_ phase: Phase, _ status: Status) -> Track {
        Track(id: "k3f9", title: "Ferrite", phase: phase, status: status)
    }

    /// Die Phase bleibt, wo sie ist. Früher rückte sie hier vor und der Track
    /// sprang zurück nach `in progress` — was beim Ziehen nach done wie ein
    /// Fehler wirkte.
    @Test("Von in review nach done heißt schlicht fertig")
    func reviewToDoneJustFinishes() {
        var subject = track(.mixdown, .review)
        subject.move(to: .done)

        #expect(subject.phase == .mixdown)
        #expect(subject.status == .done)
        #expect(subject.isFinished)
    }

    @Test("Nach bestandenem Mastering ist der Track fertig")
    func masteringFinishesTrack() {
        var subject = track(.mastering, .review)
        subject.move(to: .done)

        #expect(subject.phase == .mastering)
        #expect(subject.status == .done)
        #expect(subject.isFinished)
    }

    @Test("Nicht bestandene Review lässt die Phase stehen")
    func failingReviewKeepsPhase() {
        var subject = track(.mixdown, .review)
        subject.move(to: .inProgress)

        #expect(subject.phase == .mixdown)
        #expect(subject.status == .inProgress)
    }

    @Test("Ohne Umweg über Review ist done einfach done")
    func manualDoneDoesNotAdvance() {
        var subject = track(.mixdown, .inProgress)
        subject.move(to: .done)

        #expect(subject.phase == .mixdown)
        #expect(subject.status == .done)
        #expect(subject.isFinished)
    }

    @Test("Jeder Eintritt in Review zählt eine Runde")
    func reviewRoundsAreCounted() {
        var subject = track(.mixdown, .inProgress)
        #expect(subject.reviewRounds == 0)

        subject.move(to: .review)
        #expect(subject.reviewRounds == 1)

        // Innerhalb der Review hin und her zu schieben zählt nicht neu.
        subject.move(to: .review)
        #expect(subject.reviewRounds == 1)

        subject.move(to: .inProgress)
        subject.move(to: .review)
        #expect(subject.reviewRounds == 2)
    }

    @Test("Die Phase lässt sich von Hand setzen, ohne die Spalte zu ändern")
    func phaseCanBeSetManually() {
        var subject = track(.jamSession, .inProgress)
        subject.setPhase(.mastering)

        #expect(subject.phase == .mastering)
        #expect(subject.status == .inProgress)
    }
}

@Suite("Abhör-Checkliste")
struct ChecklistTests {
    @Test("Fehlende Situationen kommen aus der Konfiguration dazu")
    func reconcileAddsMissingSituations() {
        var subject = Track(id: "a", title: "A", checks: [
            ListeningCheck(situation: "Auto", isChecked: true, note: "ok")
        ])
        subject.reconcileChecks(with: .default)

        #expect(subject.checks.map(\.situation) == Config.default.listeningSituations)
        #expect(subject.checks[0] == ListeningCheck(situation: "Auto", isChecked: true, note: "ok"))
        #expect(subject.checks[1].isChecked == false)
    }

    @Test("Die Vorgabe unterscheidet die Bose-Geräte und die 45°-Position")
    func defaultCoversTheStudioSetup() {
        let situations = Config.default.listeningSituations
        #expect(situations.contains("Studio 45°"))
        #expect(situations.contains("Bose Kopfhörer"))
        #expect(situations.contains("Bose Lautsprecher"))
        // "Bose" allein wäre mehrdeutig — Kopfhörer und Lautsprecher klingen
        // verschieden genug, dass sie getrennt abgehört werden.
        #expect(!situations.contains("Bose"))
    }

    @Test("Nicht mehr konfigurierte Situationen bleiben erhalten")
    func reconcileKeepsUnknownSituations() {
        var subject = Track(id: "a", title: "A", checks: [
            ListeningCheck(situation: "Küchenradio", isChecked: true, note: "dumpf")
        ])
        subject.reconcileChecks(with: .default)

        #expect(subject.checks.count == Config.default.listeningSituations.count + 1)
        #expect(subject.checks.last?.situation == "Küchenradio")
        #expect(subject.checks.last?.note == "dumpf")
    }

    @Test("Zurücksetzen nimmt die Haken zurück, behält aber die Notizen")
    func resetKeepsNotes() {
        var subject = Track(id: "a", title: "A", checks: [
            ListeningCheck(situation: "Auto", isChecked: true, note: "Bass zu laut")
        ])
        subject.resetChecks()

        #expect(subject.checks[0].isChecked == false)
        #expect(subject.checks[0].note == "Bass zu laut")
    }

    @Test("Der Fortschritt steht nur beim Mastering auf der Karte")
    func badgeOnlyDuringMastering() {
        var subject = Track(id: "a", title: "A", phase: .mixdown)
        subject.reconcileChecks(with: .default)
        #expect(subject.checklistBadge == nil)

        subject.setPhase(.mastering)
        subject.checks[0].isChecked = true
        subject.checks[1].isChecked = true
        #expect(subject.checklistBadge == "2/6")

        // Am fertigen Track wäre der Fortschritt eine falsche Aufforderung.
        subject.move(to: .done)
        #expect(subject.checklistBadge == nil)
    }
}

@Suite("Priorität")
struct OrderingTests {
    @Test("Einfügen zwischen zwei Karten nimmt die Mitte")
    func insertsBetween() {
        #expect(Ordering.value(between: 1000, and: 2000) == 1500)
        #expect(Ordering.value(between: nil, and: 1000) == 0)
        #expect(Ordering.value(between: 3000, and: nil) == 4000)
        #expect(Ordering.value(between: nil, and: nil) == Ordering.step)
    }

    @Test("Ohne Platz meldet die Vergabe Fehlanzeige")
    func reportsExhaustedGap() {
        #expect(Ordering.value(between: 1000, and: 1001) == nil)
        #expect(Ordering.value(between: 1000, and: 1000) == nil)
    }

    @Test("Neunummerierung liefert nur die tatsächlich geänderten Tracks")
    func renumberTouchesOnlyChanged() {
        let tracks = [
            Track(id: "a", title: "A", order: 1000),
            Track(id: "b", title: "B", order: 1001),
            Track(id: "c", title: "C", order: 3500),
        ]
        let changed = Ordering.renumber(tracks)

        #expect(changed.map(\.id) == ["b", "c"])
        #expect(changed.map(\.order) == [2000, 3000])
    }
}

@Suite("Bearbeitete Felder überschreiben nichts anderes")
struct TrackEditsTests {
    /// Der gemeldete Fehler: Karte ausgewählt, nach `in progress` gezogen,
    /// danach etwas in die Notizen geschrieben — und sie sprang zurück nach
    /// `open`. Der Entwurf des Panels trug den ganzen Track und damit eine
    /// eingefrorene Spalte.
    @Test("Eine Notiz dreht einen Spaltenwechsel nicht zurück")
    func notesDoNotRevertTheColumn() {
        var track = Track(id: "vh5t", title: "Need to feel Loved", status: .open)
        // Beim Auswählen entsteht der Entwurf.
        let draft = track.edits

        // Danach wandert die Karte auf dem Board.
        track.move(to: .inProgress)

        // Und jetzt wird getippt — mit dem Entwurf von vorhin.
        var edited = draft
        edited.notes = "Bassline implementieren"
        track.apply(edited)

        #expect(track.status == .inProgress)
        #expect(track.notes == "Bassline implementieren")
    }

    @Test("Phase, Release, Priorität und Rundenzahl bleiben ebenfalls unberührt")
    func keepsEverythingThePanelDoesNotEdit() {
        var track = Track(
            id: "a", title: "A", phase: .mastering, status: .review,
            release: "r-1", order: 7000, reviewRounds: 3
        )
        var edited = track.edits
        edited.title = "Neuer Titel"
        edited.tags = ["dark"]
        track.apply(edited)

        #expect(track.title == "Neuer Titel")
        #expect(track.tags == ["dark"])
        #expect(track.phase == .mastering)
        #expect(track.status == .review)
        #expect(track.release == "r-1")
        #expect(track.order == 7000)
        #expect(track.reviewRounds == 3)
    }

    @Test("Ohne Änderung bleibt der Zeitstempel stehen")
    func unchangedEditsDoNotTouchUpdated() {
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        var track = Track(id: "a", title: "A", updated: stamp)
        track.apply(track.edits, now: Date())
        #expect(track.updated == stamp)
    }

    @Test("Eine echte Änderung frischt den Zeitstempel auf")
    func realEditsRefreshUpdated() {
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        var track = Track(id: "a", title: "A", updated: stamp)
        var edited = track.edits
        edited.notes = "etwas"
        track.apply(edited, now: Date(timeIntervalSince1970: 2_000_000))
        #expect(track.updated == Date(timeIntervalSince1970: 2_000_000))
    }
}
