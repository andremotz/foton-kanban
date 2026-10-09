import Foundation
import Testing

@testable import FotonKanbanCore

@Suite("Auszeichnen über eine Auswahl")
struct InlineToggleTests {
    private func runs(_ markdown: String) -> [StyledRun] { InlineMarkdown.parse(markdown) }
    private func text(_ runs: [StyledRun]) -> String { InlineMarkdown.write(runs) }

    @Test("Eine Auswahl wird fett")
    func setsBold() {
        let result = InlineMarkdown.toggle(.bold, in: runs("Kick und Bass"), over: 0..<4)
        #expect(text(result) == "**Kick** und Bass")
    }

    @Test("Nochmal gedrückt nimmt es wieder weg")
    func togglesOff() {
        let once = InlineMarkdown.toggle(.bold, in: runs("Kick und Bass"), over: 0..<4)
        let twice = InlineMarkdown.toggle(.bold, in: once, over: 0..<4)
        #expect(text(twice) == "Kick und Bass")
    }

    @Test("Teilweise ausgezeichnete Auswahl wird vollständig ausgezeichnet")
    func extendsPartialStyle() {
        // Die halbe Auswahl ist schon fett — der Tastendruck zeichnet den
        // Rest mit aus, statt alles zu löschen.
        let result = InlineMarkdown.toggle(.bold, in: runs("**Kick** und Bass"), over: 0..<8)
        #expect(text(result) == "**Kick und** Bass")
    }

    @Test("Durchstreichen legt sich über vorhandenes Fett")
    func stacksOnExistingStyle() {
        let result = InlineMarkdown.toggle(.strikethrough, in: runs("**Kick**"), over: 0..<4)
        #expect(result == [StyledRun(text: "Kick", styles: [.bold, .strikethrough])])
    }

    @Test("Der Wortlaut ändert sich beim Auszeichnen nie", arguments: [
        "Kick und Bass", "**schon fett** und Rest", "~~weg~~ und da", "- Listenpunkt",
    ])
    func togglingNeverChangesWording(source: String) {
        let original = runs(source)
        let total = original.map(\.text.count).reduce(0, +)
        for style in [InlineStyle.bold, .italic, .strikethrough] {
            let result = InlineMarkdown.toggle(style, in: original, over: 0..<total)
            #expect(result.map(\.text).joined() == original.map(\.text).joined())
        }
    }

    @Test("Eine leere Auswahl verändert nichts")
    func emptySelectionDoesNothing() {
        let original = runs("Kick")
        #expect(InlineMarkdown.toggle(.bold, in: original, over: 2..<2) == original)
    }
}

@Suite("Listen setzen sich fort")
struct ListContinuationTests {
    @Test("Ein Listenpunkt setzt sich fort")
    func continuesBullet() {
        #expect(InlineMarkdown.listContinuation(after: "- Arrangement ausbauen")
                == .init(prefix: "- ", clearingCharacters: 0))
    }

    @Test("Die Einrückung wird übernommen")
    func keepsIndent() {
        #expect(InlineMarkdown.listContinuation(after: "  - eingerückt")
                == .init(prefix: "  - ", clearingCharacters: 0))
    }

    @Test("Eine Checkbox wird leer fortgesetzt")
    func continuesCheckboxUnchecked() {
        #expect(InlineMarkdown.listContinuation(after: "- [x] erledigt")
                == .init(prefix: "- [ ] ", clearingCharacters: 0))
    }

    @Test("Ein leerer Punkt beendet die Liste")
    func emptyItemEndsList() {
        #expect(InlineMarkdown.listContinuation(after: "- ")
                == .init(prefix: "", clearingCharacters: 2))
        #expect(InlineMarkdown.listContinuation(after: "- [ ] ")
                == .init(prefix: "", clearingCharacters: 6))
    }

    @Test("Normaler Text setzt nichts fort")
    func plainTextDoesNotContinue() {
        #expect(InlineMarkdown.listContinuation(after: "2026-02-03:") == nil)
        #expect(InlineMarkdown.listContinuation(after: "") == nil)
        // Ein Bindestrich ohne Leerzeichen ist ein Gedankenstrich.
        #expect(InlineMarkdown.listContinuation(after: "-kein Punkt") == nil)
        // Ein Zeitbereich mitten im Satz auch nicht.
        #expect(InlineMarkdown.listContinuation(after: "00:45 - 1:31 Drums") == nil)
    }
}

@Suite("Return im Notizfeld")
struct NewlineTests {
    private func runs(_ s: String) -> [StyledRun] { InlineMarkdown.parse(s) }
    private func text(_ r: [StyledRun]) -> String { InlineMarkdown.write(r) }

    @Test("Am Ende einer Listenzeile kommt der nächste Punkt")
    func continuesTheList() {
        let result = InlineMarkdown.insertingNewline(in: runs("- Kick tauschen"), at: 15)
        #expect(text(result!.runs) == "- Kick tauschen\n- ")
        #expect(result!.cursor == 18)
    }

    @Test("Mitten in der Zeile wird trotzdem fortgesetzt")
    func continuesFromTheMiddle() {
        // Der Cursor steht hinter „Kick"; der Rest rutscht in die neue Zeile.
        let result = InlineMarkdown.insertingNewline(in: runs("- Kick tauschen"), at: 6)
        #expect(text(result!.runs) == "- Kick\n-  tauschen")
    }

    @Test("Ein leerer Punkt beendet die Liste")
    func endsTheList() {
        let result = InlineMarkdown.insertingNewline(in: runs("- Kick\n- "), at: 9)
        #expect(text(result!.runs) == "- Kick\n\n")
        #expect(result!.cursor == 8)
    }

    @Test("Außerhalb einer Liste macht der Editor seinen Umbruch selbst")
    func defersToTheEditor() {
        #expect(InlineMarkdown.insertingNewline(in: runs("2026-02-03:"), at: 11) == nil)
        #expect(InlineMarkdown.insertingNewline(in: runs(""), at: 0) == nil)
    }

    @Test("Die neue Zeile erbt die Auszeichnung nicht")
    func newLineStartsPlain() {
        // Sonst begänne der nächste Punkt durchgestrichen. Der Cursor zählt
        // in sichtbaren Zeichen — „- erledigt" sind zehn, die Tilden sieht
        // der Nutzer nicht.
        let result = InlineMarkdown.insertingNewline(in: runs("- ~~erledigt~~"), at: 10)
        #expect(text(result!.runs) == "- ~~erledigt~~\n- ")
        #expect(result!.runs.last?.style == [])
    }

    @Test("Der Wortlaut davor bleibt vollständig erhalten", arguments: [
        "- Kick", "  - eingerückt", "- [x] erledigt", "- ~~weg~~ und da",
    ])
    func keepsEverythingBefore(source: String) {
        let parsed = runs(source)
        let visible = parsed.map(\.text).joined().count
        let result = InlineMarkdown.insertingNewline(in: parsed, at: visible)
        let plain = result!.runs.map(\.text).joined()
        #expect(plain.hasPrefix(parsed.map(\.text).joined()))
    }

    /// Der Cursor zählt sichtbare Zeichen, das Markdown enthält zusätzlich
    /// die Marker. Wer die verwechselt, landet hinter dem Text — das darf
    /// nichts kaputt machen.
    @Test("Eine Position jenseits des Textes tut nichts")
    func outOfBoundsIsIgnored() {
        #expect(InlineMarkdown.insertingNewline(in: runs("- ~~weg~~"), at: 99) == nil)
    }
}

@Suite("Einrücken und Datum")
struct IndentAndDateTests {
    private func runs(_ s: String) -> [StyledRun] { InlineMarkdown.parse(s) }
    private func text(_ r: [StyledRun]) -> String { InlineMarkdown.write(r) }

    @Test("Tabulator rückt eine Listenzeile ein")
    func indents() {
        let result = InlineMarkdown.changingIndent(in: runs("- Kick"), at: 6, outwards: false)
        #expect(text(result!.runs) == "  - Kick")
        #expect(result!.cursor == 8)
    }

    @Test("Umschalt-Tabulator rückt wieder aus")
    func outdents() {
        let result = InlineMarkdown.changingIndent(in: runs("  - Kick"), at: 8, outwards: true)
        #expect(text(result!.runs) == "- Kick")
    }

    @Test("Ganz links lässt sich nicht weiter ausrücken")
    func stopsAtTheMargin() {
        #expect(InlineMarkdown.changingIndent(in: runs("- Kick"), at: 6, outwards: true) == nil)
    }

    @Test("Außerhalb einer Liste bleibt Tabulator der Feldwechsel")
    func leavesPlainTextAlone() {
        #expect(InlineMarkdown.changingIndent(in: runs("2026-02-03:"), at: 5, outwards: false) == nil)
    }

    @Test("Das Datum kommt als eigene Zeile")
    func insertsDateOnItsOwnLine() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 9
        let date = Calendar.current.date(from: parts)!

        let result = InlineMarkdown.insertingDate(in: runs("- Kick"), at: 6, date: date)
        #expect(text(result.runs) == "- Kick\n2026-10-09\n")
    }

    @Test("Am Zeilenanfang kommt kein überflüssiger Umbruch dazu")
    func noExtraBreakAtLineStart() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 9
        let date = Calendar.current.date(from: parts)!

        let result = InlineMarkdown.insertingDate(in: runs("- Kick\n"), at: 7, date: date)
        #expect(text(result.runs) == "- Kick\n2026-10-09\n")
    }
}
