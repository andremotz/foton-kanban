import Foundation
import Testing

@testable import FotonKanbanCore

@Suite("Spaltenwechsel und Phasen")
struct TrackFlowTests {
    private func track(_ phase: Phase, _ status: Status) -> Track {
        Track(id: "k3f9", title: "Ferrite", phase: phase, status: status)
    }

    @Test("Bestandene Review rückt die Phase vor und schickt den Track zurück in Arbeit")
    func passingReviewAdvancesPhase() {
        var subject = track(.mixdown, .review)
        subject.move(to: .done)

        #expect(subject.phase == .fxFinalizing)
        #expect(subject.status == .inProgress)
        #expect(!subject.isFinished)
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

    @Test("Die neue 45°-Position gehört zur Vorgabe")
    func defaultIncludesAngledStudioPosition() {
        #expect(Config.default.listeningSituations.contains("Studio 45°"))
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
        #expect(subject.checklistBadge == "2/5")

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
