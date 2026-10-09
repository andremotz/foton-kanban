import Foundation

/// Welche Auszeichnungen eine Textstelle trägt.
public struct InlineStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = InlineStyle(rawValue: 1 << 0)
    public static let italic = InlineStyle(rawValue: 1 << 1)
    public static let strikethrough = InlineStyle(rawValue: 1 << 2)

    /// Die Reihenfolge für neu gesetzte Auszeichnungen. Vorhandene behalten
    /// ihre eigene Schachtelung, siehe `StyledRun.styles`.
    public static let canonicalOrder: [InlineStyle] = [.bold, .italic, .strikethrough]

    var marker: String {
        switch self {
        case .bold: "**"
        case .italic: "*"
        case .strikethrough: "~~"
        default: ""
        }
    }
}

/// Ein Stück Text mit einheitlicher Auszeichnung.
public struct StyledRun: Equatable, Sendable {
    public var text: String
    /// Die Auszeichnungen in ihrer Schachtelung, von außen nach innen.
    ///
    /// Die Reihenfolge wird mitgeführt, weil sie in der Datei sichtbar ist:
    /// `~~**Bass**~~` und `**~~Bass~~**` bedeuten dasselbe, sehen aber
    /// verschieden aus. Ein Writer mit fester Reihenfolge würde beim ersten
    /// Öffnen die eine Schreibweise in die andere umschreiben — eine
    /// Änderung, die der Nutzer nie veranlasst hat und die über den Sync auf
    /// allen Rechnern landet.
    public var styles: [InlineStyle]

    public var style: InlineStyle { styles.reduce(into: []) { $0.formUnion($1) } }

    public init(text: String, styles: [InlineStyle]) {
        self.text = text
        self.styles = styles
    }

    /// Bequemer Weg für neuen Text: die Auszeichnungen in der üblichen
    /// Schachtelung.
    public init(text: String, style: InlineStyle = []) {
        self.text = text
        self.styles = InlineStyle.canonicalOrder.filter { style.contains($0) }
    }
}

/// Übersetzt zwischen Markdown und ausgezeichnetem Text — und zwar nur
/// *innerhalb* einer Zeile.
///
/// Der Verzicht auf Blockstruktur ist Absicht. Foundations Markdown-Parser
/// versteht Listen, verschiebt die Zeilenumbrüche dabei aber in
/// `presentationIntent`, das SwiftUI im Editor ignoriert: Aus zwei
/// Listenpunkten wird eine zusammengeklebte Zeile. Hier bleibt jede Zeile
/// unangetastet; `- ` am Anfang ist schlicht Text. Damit kann das Umschreiben
/// die Gliederung einer Notiz gar nicht erst zerstören.
///
/// Erkannt werden `**fett**`, `*kursiv*` und `~~durchgestrichen~~`. Nicht
/// erkannt werden Links, Code und `_kursiv_` — Unterstriche stecken in
/// Dateinamen wie `Techno_Files_demucs3_instrumental`, und ein Parser, der
/// darin Kursivschrift sieht, schreibt den Namen beim Speichern kaputt.
public enum InlineMarkdown {
    // MARK: - Lesen

    /// Zerlegt Markdown in Textstücke. Zeilenumbrüche bleiben als Teil des
    /// Textes erhalten, Auszeichnungen enden an jedem Zeilenende.
    public static func parse(_ markdown: String) -> [StyledRun] {
        var runs: [StyledRun] = []
        // `omittingEmptySubsequences: false` erhält Leerzeilen — sie
        // gliedern die Notizen des Nutzers.
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            append(parseSpan(line, inherited: []), to: &runs)
            if index < lines.count - 1 {
                append([StyledRun(text: "\n")], to: &runs)
            }
        }
        return runs.filter { !$0.text.isEmpty }
    }

    private static func append(_ new: [StyledRun], to runs: inout [StyledRun]) {
        for run in new {
            if var last = runs.last, last.styles == run.styles {
                last.text += run.text
                runs[runs.count - 1] = last
            } else {
                runs.append(run)
            }
        }
    }

    /// Sucht innerhalb einer Zeile die erste vollständige Auszeichnung und
    /// nimmt deren Inhalt rekursiv auseinander.
    private static func parseSpan(_ line: Substring, inherited: [InlineStyle]) -> [StyledRun] {
        var runs: [StyledRun] = []
        var plain = ""
        var i = line.startIndex

        while i < line.endIndex {
            if let escaped = escapedCharacter(in: line, at: i) {
                plain.append(escaped)
                i = line.index(i, offsetBy: 2)
                continue
            }
            guard let token = delimiter(in: line, at: i),
                  !inherited.contains(token.style),
                  canOpen(line, at: i, token: token),
                  let close = findClosing(token, in: line, from: line.index(i, offsetBy: token.length))
            else {
                plain.append(line[i])
                i = line.index(after: i)
                continue
            }

            if !plain.isEmpty {
                runs.append(StyledRun(text: plain, styles: inherited))
                plain = ""
            }
            let inner = line[line.index(i, offsetBy: token.length)..<close]
            runs += parseSpan(inner, inherited: inherited + [token.style])
            i = line.index(close, offsetBy: token.length)
        }

        if !plain.isEmpty { runs.append(StyledRun(text: plain, styles: inherited)) }
        return runs
    }

    /// `\\*` meint ein Sternchen und keinen Marker. Nur die drei Zeichen,
    /// die hier überhaupt Bedeutung haben, lassen sich maskieren — sonst
    /// würde ein Backslash in einem Dateipfad verschwinden.
    private static func escapedCharacter(in line: Substring, at index: Substring.Index) -> Character? {
        guard line[index] == "\\" else { return nil }
        let next = line.index(after: index)
        guard next < line.endIndex, "*~\\".contains(line[next]) else { return nil }
        return line[next]
    }

    private struct Token {
        var style: InlineStyle
        var length: Int
    }

    /// Welcher Marker an dieser Stelle beginnt. `**` hat Vorrang vor `*`.
    private static func delimiter(in line: Substring, at index: Substring.Index) -> Token? {
        let char = line[index]
        guard char == "*" || char == "~" else { return nil }
        let next = line.index(after: index)
        let doubled = next < line.endIndex && line[next] == char
        switch (char, doubled) {
        case ("*", true): return Token(style: .bold, length: 2)
        case ("*", false): return Token(style: .italic, length: 1)
        case ("~", true): return Token(style: .strikethrough, length: 2)
        default: return nil  // einzelne Tilde ist kein Marker
        }
    }

    /// Ein öffnender Marker braucht direkt dahinter etwas, das kein
    /// Leerzeichen ist — sonst ist `2 * 3` eine Multiplikation und keine
    /// Kursivschrift.
    private static func canOpen(_ line: Substring, at index: Substring.Index, token: Token) -> Bool {
        let after = line.index(index, offsetBy: token.length, limitedBy: line.endIndex) ?? line.endIndex
        guard after < line.endIndex else { return false }
        return !line[after].isWhitespace
    }

    /// Der schließende Marker darf kein Leerzeichen vor sich haben. Genau
    /// daran scheitert `~~Arrangement ~~` in den echten Notizen — korrekt,
    /// denn Markdown wertet das auch nicht als Durchstreichung.
    private static func findClosing(
        _ token: Token, in line: Substring, from start: Substring.Index
    ) -> Substring.Index? {
        var i = start
        while i < line.endIndex {
            if escapedCharacter(in: line, at: i) != nil {
                i = line.index(i, offsetBy: 2)
                continue
            }
            if let candidate = delimiter(in: line, at: i), candidate.style == token.style,
               candidate.length == token.length, i > start,
               !line[line.index(before: i)].isWhitespace {
                return i
            }
            i = line.index(after: i)
        }
        return nil
    }

    // MARK: - Schreiben

    /// Setzt die Marker wieder ein. Öffnende und schließende Marker folgen
    /// der Schachtelung, damit `**fett und ~~weg~~**` wieder genauso dasteht.
    public static func write(_ runs: [StyledRun]) -> String {
        var out = ""
        var open: [InlineStyle] = []

        for run in trimmingStyledEdges(runs) where !run.text.isEmpty {
            // Auszeichnungen, die diese Stelle nicht mehr trägt, von innen
            // nach außen schließen.
            // So weit die Schachtelung mit der offenen übereinstimmt, bleibt
            // sie stehen; der Rest wird von innen nach außen geschlossen.
            var keep = 0
            while keep < open.count, keep < run.styles.count, open[keep] == run.styles[keep] {
                keep += 1
            }
            for style in open[keep...].reversed() { out += style.marker }
            open.removeSubrange(keep...)

            for style in run.styles[keep...] {
                out += style.marker
                open.append(style)
            }

            // Eine Auszeichnung endet am Zeilenende. Steht ein Umbruch im
            // Text, muss davor geschlossen und danach neu geöffnet werden.
            if run.text.contains("\n"), !open.isEmpty {
                let parts = run.text.split(separator: "\n", omittingEmptySubsequences: false)
                for (index, part) in parts.enumerated() {
                    if index > 0 {
                        // Leere Teile bekommen kein Markerpaar — `~~~~`
                        // wäre kein Text, sondern ein neuer Marker.
                        if index > 0, !parts[index - 1].isEmpty {
                            for style in open.reversed() { out += style.marker }
                        }
                        out += "\n"
                        if !part.isEmpty {
                            for style in open { out += style.marker }
                        }
                    }
                    out += part
                }
            } else {
                out += run.text
            }
        }

        for style in open.reversed() { out += style.marker }
        return out
    }

    /// Schiebt Leerzeichen an den Rändern einer Auszeichnung nach außen.
    ///
    /// `~~ weg~~` ist in Markdown keine Durchstreichung — ein schließender
    /// Marker braucht ein Nicht-Leerzeichen vor sich. Beim Tippen entstehen
    /// solche Auswahlen dauernd, etwa durch einen Doppelklick aufs Wort samt
    /// Leerzeichen. Geschrieben wird deshalb `~~weg~~` mit dem Leerzeichen
    /// davor: sieht gleich aus, ist gültig und kommt zurück.
    ///
    /// Nur die Ränder einer Spanne werden angefasst. Das Leerzeichen in
    /// `**fett und ~~weg~~**` steht mitten im Fettgedruckten und bleibt
    /// drin — sonst zerfiele die Auszeichnung in zwei.
    private static func trimmingStyledEdges(_ runs: [StyledRun]) -> [StyledRun] {
        var out: [StyledRun] = []
        for (index, run) in runs.enumerated() {
            guard !run.style.isEmpty else { out.append(run); continue }

            // Trägt der Nachbar dieselben Auszeichnungen weiter, läuft die
            // Spanne dort hindurch und der Rand ist keiner.
            let continuesBefore = index > 0
                && runs[index - 1].style.isSuperset(of: run.style)
            let continuesAfter = index + 1 < runs.count
                && runs[index + 1].style.isSuperset(of: run.style)

            let leading = continuesBefore ? "" : String(run.text.prefix { $0.isWhitespace })
            let core = run.text.dropFirst(leading.count)
            let trailing = continuesAfter
                ? "" : String(core.reversed().prefix { $0.isWhitespace }.reversed())
            let middle = String(core.dropLast(trailing.count))

            if !leading.isEmpty { out.append(StyledRun(text: leading)) }
            if !middle.isEmpty { out.append(StyledRun(text: middle, styles: run.styles)) }
            if !trailing.isEmpty { out.append(StyledRun(text: trailing)) }
        }
        return out
    }

    // MARK: - Die Absicherung

    /// Ob eine Notiz den Weg hin und zurück unverändert übersteht.
    ///
    /// Nur dafür wird der formatierte Editor überhaupt angeboten. Alles
    /// andere — ein Link, eine ungewöhnliche Schachtelung, ein Marker an
    /// einer Stelle, die dieser Parser anders liest — bleibt im Klartext
    /// stehen, statt beim ersten Öffnen stillschweigend umgeschrieben zu
    /// werden.
    public static func roundTrips(_ markdown: String) -> Bool {
        write(parse(markdown)) == markdown
    }

    /// Die Gegenrichtung, vor dem Speichern.
    ///
    /// Die Regel folgt der Art, wie diese Notizen entstehen: Von Hand
    /// getipptes Markdown *soll* beim nächsten Öffnen als Auszeichnung
    /// erscheinen — wer `~~weg~~` schreibt, meint durchgestrichen und nicht
    /// vier Tilden. Deshalb bleibt unausgezeichneter Text unangetastet und
    /// wird beim Laden gedeutet.
    ///
    /// Maskiert wird nur das Gegenteil: Markerzeichen *innerhalb* einer
    /// Auszeichnung. `*a*` fett gesetzt ergäbe sonst `***a***`, was beim
    /// Lesen auseinanderfällt — da hat der Wortlaut Vorrang, auch um den
    /// Preis eines Backslashs in der Datei.
    public static func writeSafely(_ runs: [StyledRun]) -> String {
        let normalized = merged(runs)
        let candidate = write(normalized.map {
            $0.style.isEmpty ? $0 : StyledRun(text: escaping($0.text), styles: $0.styles)
        })
        // Jede gesetzte Auszeichnung muss unverändert zurückkommen. Dass
        // beim Lesen *zusätzliche* dazukommen, ist genau der gewollte Fall.
        let reloaded = parse(candidate)
        let intended = normalized.filter { !$0.style.isEmpty }
        if intended.allSatisfy({ reloaded.contains($0) }) { return candidate }

        // Bleibt etwas mehrdeutig, wird alles maskiert.
        return write(normalized.map {
            StyledRun(text: escaping($0.text), styles: $0.styles)
        })
    }

    private static func escaping(_ text: String) -> String {
        var out = ""
        for character in text {
            if character == "*" || character == "~" || character == "\\" { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Benachbarte Stücke mit gleicher Auszeichnung zusammenfassen, damit der
    /// Vergleich mit dem frisch Gelesenen überhaupt aufgehen kann.
    private static func merged(_ runs: [StyledRun]) -> [StyledRun] {
        var out: [StyledRun] = []
        append(runs.filter { !$0.text.isEmpty }, to: &out)
        return out
    }
}

// MARK: - Bearbeiten

extension InlineMarkdown {
    /// Schaltet eine Auszeichnung über einem Zeichenbereich um — das, was
    /// hinter ⌘B steckt. Trägt der ganze Bereich sie schon, wird sie
    /// entfernt, sonst überall gesetzt.
    ///
    /// Die Arbeit passiert auf Zeichenpositionen statt auf dem
    /// ausgezeichneten Text der Oberfläche: So ist sie ohne laufendes
    /// Fenster prüfbar.
    public static func toggle(
        _ style: InlineStyle, in runs: [StyledRun], over range: Range<Int>
    ) -> [StyledRun] {
        guard !range.isEmpty else { return runs }
        let pieces = split(runs, at: [range.lowerBound, range.upperBound])

        var offset = 0
        var covered: [Int] = []
        for (index, piece) in pieces.enumerated() {
            let end = offset + piece.text.count
            if offset >= range.lowerBound, end <= range.upperBound { covered.append(index) }
            offset = end
        }
        // Eine Auszeichnung, die schon überall liegt, nimmt der Tastendruck
        // wieder weg — so wie in jedem Texteditor.
        let alreadySet = covered.allSatisfy { pieces[$0].style.contains(style) }

        var result = pieces
        for index in covered {
            if alreadySet {
                result[index].styles.removeAll { $0 == style }
            } else if !result[index].style.contains(style) {
                result[index].styles.append(style)
            }
        }
        return merged(result)
    }

    /// Zerteilt die Stücke an den angegebenen Zeichenpositionen, damit eine
    /// Auswahl mitten in einem Stück enden kann.
    private static func split(_ runs: [StyledRun], at positions: [Int]) -> [StyledRun] {
        let cuts = Set(positions).sorted()
        var out: [StyledRun] = []
        var offset = 0
        for run in runs {
            var local: [Int] = []
            for cut in cuts where cut > offset && cut < offset + run.text.count {
                local.append(cut - offset)
            }
            if local.isEmpty {
                out.append(run)
            } else {
                var start = 0
                for cut in local + [run.text.count] {
                    let from = run.text.index(run.text.startIndex, offsetBy: start)
                    let to = run.text.index(run.text.startIndex, offsetBy: cut)
                    out.append(StyledRun(text: String(run.text[from..<to]), styles: run.styles))
                    start = cut
                }
            }
            offset += run.text.count
        }
        return out
    }

    /// Was nach einem Zeilenumbruch automatisch wieder dastehen soll.
    ///
    /// `nil` heißt: nichts fortsetzen. Eine leere Listenzeile beendet die
    /// Liste, statt einen weiteren leeren Punkt anzulegen — sonst müsste man
    /// den von Hand wieder löschen.
    public static func listContinuation(after line: String) -> Continuation? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)

        guard let marker = rest.first, marker == "-" || marker == "*" || marker == "+",
              rest.dropFirst().first == " "
        else { return nil }

        let afterMarker = rest.dropFirst(2)
        // Eine Checkbox wird als leere Checkbox fortgesetzt, nicht als
        // abgehakte.
        let isCheckbox = afterMarker.hasPrefix("[ ] ") || afterMarker.hasPrefix("[x] ")
            || afterMarker.hasPrefix("[X] ")
        let content = isCheckbox ? afterMarker.dropFirst(4) : afterMarker

        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            // Leerer Punkt: Liste beenden und die Zeile räumen.
            return Continuation(prefix: "", clearingCharacters: line.count)
        }
        return Continuation(
            prefix: "\(indent)\(marker) \(isCheckbox ? "[ ] " : "")",
            clearingCharacters: 0
        )
    }

    /// Das Ergebnis einer Listenfortsetzung: was eingefügt wird und wie viele
    /// Zeichen der aktuellen Zeile dafür verschwinden.
    public struct Continuation: Equatable, Sendable {
        public var prefix: String
        public var clearingCharacters: Int
    }
}

extension InlineMarkdown {
    /// Was ein Druck auf Return an dieser Stelle bewirkt — der Umbruch
    /// selbst plus die fortgesetzte Listenzeile.
    ///
    /// `nil` heißt: nichts Besonderes, der Editor soll den Umbruch selbst
    /// einfügen. Die Rechnung läuft über Zeichenpositionen im reinen Text,
    /// nicht über das Markdown — in dem stehen die Marker mit drin und jede
    /// Position wäre verschoben.
    public static func insertingNewline(
        in runs: [StyledRun], at cursor: Int
    ) -> (runs: [StyledRun], cursor: Int)? {
        let full = runs.map(\.text).joined()
        guard cursor <= full.count else { return nil }
        let upToCursor = String(full.prefix(cursor))
        let lineStart = upToCursor.lastIndex(of: "\n").map { upToCursor.index(after: $0) }
            ?? upToCursor.startIndex
        let line = String(upToCursor[lineStart...])

        guard let continuation = listContinuation(after: line) else { return nil }

        if continuation.clearingCharacters > 0 {
            let from = cursor - continuation.clearingCharacters
            return (replacingCharacters(in: runs, range: from..<cursor, with: "\n"), from + 1)
        }
        let inserted = "\n" + continuation.prefix
        return (
            replacingCharacters(in: runs, range: cursor..<cursor, with: inserted),
            cursor + inserted.count
        )
    }

    /// Ersetzt einen Zeichenbereich. Neu eingefügter Text erbt keine
    /// Auszeichnung — eine frische Listenzeile soll nicht durchgestrichen
    /// anfangen, bloß weil die vorige es war.
    public static func replacingCharacters(
        in runs: [StyledRun], range: Range<Int>, with replacement: String
    ) -> [StyledRun] {
        var out: [StyledRun] = []
        var offset = 0
        var inserted = false
        for run in runs {
            var piece = ""
            for (local, character) in run.text.enumerated() {
                let position = offset + local
                if position == range.lowerBound, !inserted {
                    if !piece.isEmpty { out.append(StyledRun(text: piece, styles: run.styles)) }
                    piece = ""
                    out.append(StyledRun(text: replacement))
                    inserted = true
                }
                if !range.contains(position) { piece.append(character) }
            }
            if !piece.isEmpty { out.append(StyledRun(text: piece, styles: run.styles)) }
            offset += run.text.count
        }
        if !inserted { out.append(StyledRun(text: replacement)) }
        return merged(out)
    }
}

extension InlineMarkdown {
    /// Rückt die Zeile um den Cursor ein oder wieder aus.
    ///
    /// Eingerückt wird mit zwei Leerzeichen, weil die vorhandenen Notizen es
    /// so halten. Ausgerückt wird, was da ist — auch ein Tabulator oder eine
    /// ungerade Zahl Leerzeichen.
    public static func changingIndent(
        in runs: [StyledRun], at cursor: Int, outwards: Bool
    ) -> (runs: [StyledRun], cursor: Int)? {
        let full = runs.map(\.text).joined()
        guard cursor <= full.count else { return nil }
        let upToCursor = String(full.prefix(cursor))
        let lineStartOffset = upToCursor.lastIndex(of: "\n")
            .map { upToCursor.distance(from: upToCursor.startIndex, to: $0) + 1 } ?? 0
        let line = String(full.dropFirst(lineStartOffset).prefix { $0 != "\n" })

        // Nur Listenzeilen — anderswo ist Tabulator der Sprung zum nächsten Feld.
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        guard let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " "
        else { return nil }

        if outwards {
            guard !indent.isEmpty else { return nil }
            let removed = indent.hasSuffix("  ") ? 2 : 1
            return (
                replacingCharacters(
                    in: runs,
                    range: (lineStartOffset + indent.count - removed)..<(lineStartOffset + indent.count),
                    with: ""),
                max(lineStartOffset, cursor - removed)
            )
        }
        return (
            replacingCharacters(
                in: runs, range: lineStartOffset..<lineStartOffset, with: "  "),
            cursor + 2
        )
    }

    /// Das heutige Datum als eigene Zeile — die Gliederung dieser Notizen
    /// besteht aus Datumszeilen, und die tippt man sonst jedes Mal von Hand.
    public static func insertingDate(
        in runs: [StyledRun], at cursor: Int, date: Date = Date(),
        calendar: Calendar = .current
    ) -> (runs: [StyledRun], cursor: Int) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)

        let full = runs.map(\.text).joined()
        let before = String(full.prefix(cursor))
        // Mitten in einer Zeile beginnt das Datum eine neue.
        let needsBreak = !before.isEmpty && !before.hasSuffix("\n")
        let text = (needsBreak ? "\n" : "") + stamp + "\n"
        return (
            replacingCharacters(in: runs, range: cursor..<cursor, with: text),
            cursor + text.count
        )
    }
}
