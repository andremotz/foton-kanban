import Foundation
import Testing

@testable import FotonKanbanCore

@Suite("Auszeichnungen in einer Zeile")
struct InlineMarkdownTests {
    @Test("Fett, kursiv und durchgestrichen werden erkannt")
    func parsesTheThreeStyles() {
        #expect(InlineMarkdown.parse("**fett**") == [StyledRun(text: "fett", style: .bold)])
        #expect(InlineMarkdown.parse("*kursiv*") == [StyledRun(text: "kursiv", style: .italic)])
        #expect(InlineMarkdown.parse("~~weg~~") == [StyledRun(text: "weg", style: .strikethrough)])
    }

    @Test("Text ohne Marker bleibt ein Stück")
    func plainTextStaysWhole() {
        #expect(InlineMarkdown.parse("Nur Text") == [StyledRun(text: "Nur Text")])
    }

    @Test("Auszeichnungen lassen sich schachteln")
    func nests() {
        let runs = InlineMarkdown.parse("**fett und ~~weg~~**")
        #expect(runs == [
            StyledRun(text: "fett und ", style: .bold),
            StyledRun(text: "weg", style: [.bold, .strikethrough]),
        ])
        #expect(InlineMarkdown.write(runs) == "**fett und ~~weg~~**")
    }

    /// Der tatsächliche Inhalt einer Notiz: ein Mastering-Datum, eine Liste,
    /// abgehakte Punkte als Durchstreichung.
    @Test("Eine echte Notizstruktur übersteht den Weg hin und zurück")
    func realisticNoteRoundTrips() {
        let note = """
        2025-11-25

        - ~~Arrangement ausbauen~~
        - ~~Gitarre +7~~
        - Piano +7

        2026-02-03:

        - 00:45 - 1:31 Tribal Drums runterfahren
        """
        #expect(InlineMarkdown.roundTrips(note))
        // Die Gliederung bleibt Zeichen für Zeichen stehen.
        #expect(InlineMarkdown.parse(note).map(\.text).joined().contains("\n\n- "))
    }

    @Test("Leerzeilen am Stück bleiben erhalten")
    func keepsBlankLines() {
        #expect(InlineMarkdown.roundTrips("a\n\n\n\nb"))
        #expect(InlineMarkdown.roundTrips("\n\n"))
        #expect(InlineMarkdown.roundTrips(""))
    }

    // MARK: - Was absichtlich kein Marker ist

    @Test("Unterstriche in Dateinamen sind keine Kursivschrift")
    func underscoresAreLiteral() {
        let name = "20221126213442-Techno_Files_demucs3mdxextra_instrumental.mp3"
        #expect(InlineMarkdown.parse(name) == [StyledRun(text: name)])
        #expect(InlineMarkdown.roundTrips(name))
    }

    @Test("Ein Stern mit Leerzeichen dahinter bleibt ein Stern")
    func loneAsteriskIsLiteral() {
        #expect(InlineMarkdown.roundTrips("2 * 3 * 4"))
        #expect(InlineMarkdown.parse("2 * 3 * 4") == [StyledRun(text: "2 * 3 * 4")])
    }

    /// Steht in einer echten Notiz. Markdown wertet das nicht als
    /// Durchstreichung, weil vor den schließenden Tilden ein Leerzeichen
    /// steht — und dieser Parser auch nicht.
    @Test("Tilden mit Leerzeichen davor schließen nicht")
    func trailingSpaceDoesNotClose() {
        #expect(InlineMarkdown.parse("~~Arrangement ~~") == [StyledRun(text: "~~Arrangement ~~")])
        #expect(InlineMarkdown.roundTrips("- ~~Arrangement ~~"))
    }

    @Test("Ein Marker ohne Gegenstück bleibt Text")
    func unmatchedMarkerIsLiteral() {
        #expect(InlineMarkdown.parse("**offen") == [StyledRun(text: "**offen")])
        #expect(InlineMarkdown.roundTrips("ein ~~ loser Marker"))
    }

    @Test("Auszeichnungen enden am Zeilenende")
    func stylesDoNotCrossLines() {
        // Sonst würde ein Sternchen oben eine Notiz unten einfärben.
        #expect(InlineMarkdown.parse("*auf\ndieser*") == [StyledRun(text: "*auf\ndieser*")])
    }

    @Test("Links werden nicht angefasst")
    func linksStayLiteral() {
        let line = "- datei.[[mvsep.com](http://mvsep.com)].mp3"
        #expect(InlineMarkdown.parse(line) == [StyledRun(text: line)])
        #expect(InlineMarkdown.roundTrips(line))
    }

    // MARK: - Die Absicherung

    /// Diese Notizen sind von Hand in Markdown getippt. Wer `~~weg~~`
    /// schreibt, meint durchgestrichen — die Tilden zu maskieren wäre das
    /// Gegenteil dessen, was er wollte, und würde Backslashes in die Datei
    /// schreiben.
    @Test("Von Hand getipptes Markdown bleibt Markdown", arguments: [
        "~~weg~~", "**fett**", "- ~~erledigt~~", "a ** b ** c",
    ])
    func typedMarkdownIsKept(source: String) {
        let written = InlineMarkdown.writeSafely([StyledRun(text: source)])
        #expect(written == source)
        #expect(!written.contains("\\"))
    }

    /// Die eigentliche Zusage des Editors: Was gespeichert und wieder
    /// geladen wird, hat denselben Wortlaut. Die Formatierung darf dabei
    /// verloren gehen, der Text nicht.
    @Test("Gespeichert und neu geladen steht derselbe Text da", arguments: [
        [StyledRun(text: "*a*", style: .bold)],
        [StyledRun(text: "2 * 3", style: .strikethrough)],
        [StyledRun(text: "~~", style: .bold)],
        [StyledRun(text: "Datei_mit_Unterstrich.mp3", style: .italic)],
        [StyledRun(text: "a"), StyledRun(text: "**", style: .bold)],
        [StyledRun(text: "C:\\Pfad\\*", style: .bold)],
        [StyledRun(text: "normal"), StyledRun(text: " weg", style: .strikethrough)],
    ])
    func savingKeepsTheWording(runs: [StyledRun]) {
        let written = InlineMarkdown.writeSafely(runs)
        let reloaded = InlineMarkdown.parse(written)
        #expect(reloaded.map(\.text).joined() == runs.map(\.text).joined())
    }

    /// Gefunden an einer echten Notiz. Beide Schreibweisen bedeuten
    /// dasselbe; ein Writer mit fester Reihenfolge hätte die eine beim
    /// ersten Öffnen in die andere umgeschrieben und die Änderung über den
    /// Sync verteilt.
    @Test("Die Schachtelung bleibt, wie sie in der Datei steht", arguments: [
        "~~**Bass**~~",
        "**~~Bass~~**",
        "*~~beides~~*",
        "~~*beides*~~",
        "- ~~**Drums** neu einspielen~~",
    ])
    func keepsTheNestingFromTheFile(source: String) {
        #expect(InlineMarkdown.write(InlineMarkdown.parse(source)) == source)
        #expect(InlineMarkdown.roundTrips(source))
    }

    @Test("Maskierte Marker sind Text, keine Auszeichnung")
    func escapedMarkersAreLiteral() {
        #expect(InlineMarkdown.parse("\\*kein Marker\\*") == [StyledRun(text: "*kein Marker*")])
        #expect(InlineMarkdown.parse("**fett \\* dazwischen**")
                == [StyledRun(text: "fett * dazwischen", style: .bold)])
    }

    @Test("Der Round-Trip-Prüfer meldet, was er nicht sauber abbilden kann")
    func gateRejectsWhatItCannotReproduce() {
        #expect(InlineMarkdown.roundTrips("**fett**"))
        #expect(InlineMarkdown.roundTrips("ganz normaler Text"))
        // Unterstrich-Kursiv kennt dieser Parser nicht — es bleibt Text und
        // kommt deshalb unverändert zurück.
        #expect(InlineMarkdown.roundTrips("_kursiv_"))
    }
}

@Suite("Leerzeichen an den Rändern einer Auszeichnung")
struct StyledEdgeTests {
    /// Beim Doppelklick auf ein Wort nimmt macOS gern das Leerzeichen mit.
    /// `~~ weg~~` wäre in Markdown gar keine Durchstreichung.
    @Test("Ein führendes Leerzeichen wandert vor den Marker")
    func movesLeadingSpaceOut() {
        let runs = [StyledRun(text: "normal"), StyledRun(text: " weg", style: .strikethrough)]
        #expect(InlineMarkdown.write(runs) == "normal ~~weg~~")
    }

    @Test("Ein nachgestelltes Leerzeichen ebenso")
    func movesTrailingSpaceOut() {
        let runs = [StyledRun(text: "weg ", style: .bold), StyledRun(text: "Rest")]
        #expect(InlineMarkdown.write(runs) == "**weg** Rest")
    }

    @Test("Eine Auszeichnung aus lauter Leerzeichen verschwindet")
    func dropsWhitespaceOnlyStyle() {
        #expect(InlineMarkdown.write([StyledRun(text: "  ", style: .bold)]) == "  ")
    }

    @Test("Der Wortlaut bleibt dabei vollständig", arguments: [
        " weg", "weg ", " weg ", "\nweg", "weg\n",
    ])
    func keepsEveryCharacter(text: String) {
        let written = InlineMarkdown.write([StyledRun(text: text, style: .strikethrough)])
        #expect(InlineMarkdown.parse(written).map(\.text).joined() == text)
    }
}
