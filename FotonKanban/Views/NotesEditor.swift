import FotonKanbanCore
import SwiftUI

/// Das Notizfeld. Zeigt Auszeichnungen formatiert an, speichert aber
/// weiterhin Markdown — die Datei im Nextcloud-Ordner bleibt das, was sie
/// war.
///
/// Formatiert wird nur, was den Weg Markdown → Text → Markdown unverändert
/// übersteht. Alles andere bekommt den Klartext-Editor, damit eine Notiz
/// nicht beim bloßen Anschauen umgeschrieben wird.
struct NotesEditor: View {
    @Binding var text: String

    var body: some View {
        if #available(macOS 26.0, *) {
            RichNotesEditor(markdown: $text)
        } else {
            TextEditor(text: $text)
        }
    }
}

@available(macOS 26.0, *)
private struct RichNotesEditor: View {
    @Binding var markdown: String

    @State private var attributed = AttributedString()
    @State private var selection = AttributedTextSelection()
    /// Ob diese Notiz formatiert bearbeitet werden darf. Wird beim Laden
    /// einmal entschieden und bleibt dann stehen — ein Wechsel mitten im
    /// Tippen wäre für den Nutzer unerklärlich.
    @State private var isRich = false
    /// Unterdrückt das Zurückschreiben, während wir selbst die Darstellung
    /// aufbauen.
    @State private var isLoading = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isRich {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $attributed, selection: $selection)
                        .onKeyPress(.return, action: continueList)
                        .onChange(of: attributed) { store() }
                        .focused($isFocused)
                        .onKeyPress(.init("b"), phases: .down) { shortcut($0, .bold) }
                        .onKeyPress(.init("i"), phases: .down) { shortcut($0, .italic) }
                        .onKeyPress(.init("x"), phases: .down) { shortcut($0, .strikethrough) }
                        .onKeyPress(.init("d"), phases: .down, action: insertDate)
                        .onKeyPress(.tab, phases: .down) { changeIndent($0, outwards: false) }
                        .onKeyPress(keys: [.tab], phases: .down) { press in
                            press.modifiers.contains(.shift)
                                ? changeIndent(press, outwards: true) : .ignored
                        }
                    formattingBar
                }
            } else {
                TextEditor(text: $markdown)
            }
        }
        .onAppear { load() }
        .onChange(of: markdown) { if !isRich { return }; reloadIfChangedElsewhere() }
    }

    /// Die Knöpfe stehen am Feld, nicht in der Fenster-Werkzeugleiste: Dort
    /// sähen sie aus wie Befehle fürs Board, und sie wirken ja nur hier.
    private var formattingBar: some View {
        HStack(spacing: 2) {
            formatButton("bold", "Fett", "⌘B", .bold)
            formatButton("italic", "Kursiv", "⌘I", .italic)
            formatButton("strikethrough", "Durchgestrichen", "⇧⌘X", .strikethrough)
            Spacer()
        }
        .font(.caption)
    }

    private func formatButton(
        _ symbol: String, _ label: String, _ shortcut: String, _ style: InlineStyle
    ) -> some View {
        Button { toggle(style) } label: {
            Image(systemName: symbol).frame(width: 22, height: 18)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(hasSelection ? .primary : .tertiary)
        .disabled(!hasSelection)
        .help("\(label) (\(shortcut))")
    }

    /// ⌘B, ⌘I und ⇧⌘X wirken nur im Notizfeld — im Titelfeld daneben wäre
    /// eine Auszeichnung sinnlos.
    private func shortcut(_ press: KeyPress, _ style: InlineStyle) -> KeyPress.Result {
        let needsShift = style == .strikethrough
        guard press.modifiers.contains(.command),
              press.modifiers.contains(.shift) == needsShift
        else { return .ignored }
        toggle(style)
        return .handled
    }

    /// ⇧⌘D setzt das heutige Datum als eigene Zeile — diese Notizen sind
    /// nach Datum gegliedert, und das tippt man sonst jedes Mal von Hand.
    private func insertDate(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command), press.modifiers.contains(.shift),
              let cursor = cursorOffset
        else { return .ignored }
        let result = InlineMarkdown.insertingDate(
            in: NotesEditorBridge.runs(from: attributed), at: cursor)
        apply(result.runs, cursorAt: result.cursor)
        return .handled
    }

    /// Tabulator rückt eine Listenzeile ein. Außerhalb einer Liste bleibt er
    /// der Sprung ins nächste Feld.
    private func changeIndent(_ press: KeyPress, outwards: Bool) -> KeyPress.Result {
        guard press.modifiers.contains(.shift) == outwards, let cursor = cursorOffset,
              let result = InlineMarkdown.changingIndent(
                in: NotesEditorBridge.runs(from: attributed), at: cursor, outwards: outwards)
        else { return .ignored }
        apply(result.runs, cursorAt: result.cursor)
        return .handled
    }

    private var cursorOffset: Int? {
        guard case .insertionPoint(let index) = selection.indices(in: attributed) else {
            return nil
        }
        let characters = attributed.characters
        return characters.distance(from: characters.startIndex, to: index)
    }

    /// Ohne Auswahl gäbe es nichts auszuzeichnen.
    private var hasSelection: Bool {
        if case .ranges(let set) = selection.indices(in: attributed) { return !set.isEmpty }
        return false
    }

    // MARK: - Laden und Speichern

    private func load() {
        isRich = InlineMarkdown.roundTrips(markdown)
        guard isRich else { return }
        isLoading = true
        attributed = NotesEditorBridge.attributed(from: InlineMarkdown.parse(markdown))
        isLoading = false
    }

    /// Eine Änderung von außen — etwa über den Sync — übernehmen, ohne das
    /// zu überschreiben, was gerade getippt wurde.
    private func reloadIfChangedElsewhere() {
        guard !isLoading, markdown != InlineMarkdown.writeSafely(NotesEditorBridge.runs(from: attributed))
        else { return }
        load()
    }

    private func store() {
        guard !isLoading else { return }
        markdown = InlineMarkdown.writeSafely(NotesEditorBridge.runs(from: attributed))
    }

    // MARK: - Formatieren

    private func toggle(_ style: InlineStyle) {
        guard case .ranges(let set) = selection.indices(in: attributed) else { return }
        var runs = NotesEditorBridge.runs(from: attributed)
        // Von hinten nach vorn, damit frühere Bereiche ihre Positionen behalten.
        for range in set.ranges.map(characterRange).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            runs = InlineMarkdown.toggle(style, in: runs, over: range)
        }
        replace(with: runs, keepingSelection: set)
    }

    private func characterRange(_ range: Range<AttributedString.Index>) -> Range<Int> {
        let characters = attributed.characters
        let lower = characters.distance(from: characters.startIndex, to: range.lowerBound)
        let upper = characters.distance(from: characters.startIndex, to: range.upperBound)
        return lower..<upper
    }

    private func replace(
        with runs: [StyledRun], keepingSelection ranges: RangeSet<AttributedString.Index>
    ) {
        let offsets = ranges.ranges.map(characterRange)
        isLoading = true
        attributed = NotesEditorBridge.attributed(from: runs)
        isLoading = false
        restoreSelection(offsets)
        markdown = InlineMarkdown.writeSafely(runs)
    }

    private func restoreSelection(_ offsets: [Range<Int>]) {
        let characters = attributed.characters
        let count = characters.count
        var set = RangeSet<AttributedString.Index>()
        for offset in offsets {
            let lower = characters.index(
                characters.startIndex, offsetBy: min(offset.lowerBound, count))
            let upper = characters.index(
                characters.startIndex, offsetBy: min(offset.upperBound, count))
            if lower < upper { set.insert(contentsOf: lower..<upper) }
        }
        selection = set.isEmpty ? AttributedTextSelection() : AttributedTextSelection(ranges: set)
    }

    // MARK: - Listen

    /// Return auf einer Listenzeile setzt den Strich fort; auf einem leeren
    /// Punkt beendet es die Liste. Was dabei passiert, entscheidet der Kern —
    /// hier wird nur die Cursorposition übersetzt.
    private func continueList() -> KeyPress.Result {
        guard case .insertionPoint(let index) = selection.indices(in: attributed) else {
            return .ignored
        }
        let characters = attributed.characters
        let offset = characters.distance(from: characters.startIndex, to: index)
        guard let result = InlineMarkdown.insertingNewline(
            in: NotesEditorBridge.runs(from: attributed), at: offset)
        else { return .ignored }

        apply(result.runs, cursorAt: result.cursor)
        return .handled
    }

    private func apply(_ runs: [StyledRun], cursorAt offset: Int) {
        isLoading = true
        attributed = NotesEditorBridge.attributed(from: runs)
        isLoading = false
        let characters = attributed.characters
        let index = characters.index(
            characters.startIndex, offsetBy: min(offset, characters.count))
        selection = AttributedTextSelection(insertionPoint: index)
        markdown = InlineMarkdown.writeSafely(runs)
    }

    // MARK: - Übersetzung in beide Richtungen

}

@available(macOS 26.0, *)
enum NotesEditorBridge {
    /// Ausgezeichneter Text für die Anzeige. `inlinePresentationIntent` wird
    /// benutzt, weil SwiftUIs `Font` undurchsichtig ist: Man kann ein
    /// gesetztes Font-Attribut nicht fragen, ob es fett war, und könnte die
    /// Auszeichnung deshalb nicht zurück nach Markdown übersetzen.
    static func attributed(from runs: [StyledRun]) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if run.style.contains(.italic) { intent.insert(.emphasized) }
            if run.style.contains(.strikethrough) { intent.insert(.strikethrough) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            // Die Schachtelung wird mitgeführt, damit `~~**x**~~` beim
            // Speichern nicht zu `**~~x~~**` wird.
            if run.styles.count > 1 { piece.fotonNesting = run.styles.map(\.rawValue) }
            out += piece
        }
        return out
    }

    static func runs(from attributed: AttributedString) -> [StyledRun] {
        var out: [StyledRun] = []
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else { continue }
            let intent = run.inlinePresentationIntent ?? []
            var style: InlineStyle = []
            if intent.contains(.stronglyEmphasized) { style.insert(.bold) }
            if intent.contains(.emphasized) { style.insert(.italic) }
            if intent.contains(.strikethrough) { style.insert(.strikethrough) }

            if let nesting = run.fotonNesting {
                let styles = nesting.map(InlineStyle.init(rawValue:)).filter { style.contains($0) }
                let missing = InlineStyle.canonicalOrder.filter {
                    style.contains($0) && !styles.contains($0)
                }
                out.append(StyledRun(text: text, styles: styles + missing))
            } else {
                out.append(StyledRun(text: text, style: style))
            }
        }
        return out
    }

}

// MARK: - Eigenes Attribut für die Schachtelung

enum FotonNestingAttribute: AttributedStringKey {
    typealias Value = [Int]
    static let name = "fotonNesting"
}

extension AttributeScopes {
    struct FotonAttributes: AttributeScope {
        let fotonNesting: FotonNestingAttribute
    }
    var foton: FotonAttributes.Type { FotonAttributes.self }
}

extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.FotonAttributes, T>
    ) -> T { self[T.self] }
}
