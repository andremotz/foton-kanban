import Foundation

/// Zerlegt Dateinamen von Preview-Bounces in Songname und Datum.
///
/// Die Namen folgen keinem einheitlichen Schema — das Datum steht mal vorn,
/// mal hinten, manchmal folgt eine Uhrzeit, manchmal ein `MASTER`:
///
///     Ferrite preview 2022-12-28
///     Slow Static preview 2024-12-15 2307
///     2025-03-22 2030 Halcyon
///     7_Nightdrive 2026-05-03 Master
///
/// Statt eines Musters pro Variante wird der Name in Bestandteile zerlegt und
/// jeder davon eingeordnet. Was übrig bleibt, ist der Songname.
public enum BounceNaming {
    /// Wörter, die nichts über den Song aussagen. Die Dateiendungen stehen
    /// mit dabei, weil manche Track-Titel aus dem Jira-Import selbst
    /// Dateinamen sind und die Endung mitschleppen.
    private static let noise: Set<String> = [
        "preview", "previews", "master", "mastered", "mixdown", "mix",
        "bounce", "export", "final", "version",
        "mp3", "aif", "aiff", "wav", "m4a", "flac",
    ]

    /// Zerlegt an Leerzeichen, Unterstrich und Punkt — **nicht** am
    /// Bindestrich, sonst zerfiele `2026-04-14` in drei Teile. Nur Bestandteile
    /// ohne Datum werden anschließend noch am Bindestrich getrennt, damit auch
    /// `preview-Master` auseinandergeht.
    static func tokens(_ text: String) -> [String] {
        let rough = text.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "." })
            .map(String.init)
        var result: [String] = []
        for token in rough {
            if dateParts(token) != nil {
                result.append(token)
            } else {
                result.append(contentsOf: token.split(separator: "-").map(String.init))
            }
        }
        return result.filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    /// `2026-04-14` — genau in dieser Schreibweise, sonst nichts.
    static func dateParts(_ token: String) -> (year: Int, month: Int, day: Int)? {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return (year, month, day)
    }

    /// Vierstellige Zahl wie `2307` oder `0007`. Ob sie eine Uhrzeit meint,
    /// entscheidet erst die Stellung: nur direkt hinter dem Datum. Sonst
    /// verlöre `Aurora 2024 DnB Remix` seine Jahreszahl.
    static func isFourDigits(_ token: String) -> Bool {
        token.count == 4 && token.allSatisfy(\.isNumber)
    }

    /// Der reine Songname: ohne Datum, Uhrzeit, Füllwörter und ohne die
    /// Titelnummer am Anfang (`7_Nightdrive`, `a Meridian`).
    ///
    /// Dass dabei auch ein echtes einbuchstabiges Wort am Anfang wegfällt, ist
    /// hinnehmbar: Dieselbe Bereinigung greift auf beiden Seiten des
    /// Vergleichs, Datei wie Track-Titel, und angezeigt wird ohnehin der
    /// tatsächliche Dateiname.
    public static func songName(from stem: String) -> String {
        let parts = tokens(stem)
        let dateIndex = parts.firstIndex { dateParts($0) != nil }

        var kept: [String] = []
        for (index, token) in parts.enumerated() {
            if dateParts(token) != nil { continue }
            if let dateIndex, index == dateIndex + 1, isFourDigits(token) { continue }
            if noise.contains(token.lowercased()) { continue }
            kept.append(token)
        }
        if let first = kept.first, kept.count > 1, isLeadingIndex(first) {
            kept.removeFirst()
        }
        return kept.joined(separator: " ")
    }

    /// Titelnummer oder Einzelbuchstabe am Anfang.
    private static func isLeadingIndex(_ token: String) -> Bool {
        if token.count <= 2, token.allSatisfy(\.isNumber) { return true }
        if token.count == 1, token.allSatisfy(\.isLetter) { return true }
        return false
    }

    /// Vergleichsform: Kleinschreibung, Umlaute gefaltet, alles außer
    /// Buchstaben und Ziffern entfernt.
    public static func matchKey(_ text: String) -> String {
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")
        )
        return String(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII
        })
    }

    /// Das Datum aus dem Dateinamen, bei Bedarf auf die Minute genau.
    ///
    /// Bewusst nicht das Änderungsdatum der Datei: Nextcloud schreibt
    /// Zeitstempel beim Synchronisieren neu, der Name bleibt.
    public static func date(from stem: String, calendar: Calendar = .current) -> Date? {
        let parts = tokens(stem)
        guard let index = parts.firstIndex(where: { dateParts($0) != nil }),
            let date = dateParts(parts[index])
        else { return nil }

        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day

        // Eine unmittelbar folgende Uhrzeit trennt zwei Bounces desselben Tages.
        if parts.indices.contains(index + 1), isFourDigits(parts[index + 1]) {
            let time = parts[index + 1]
            components.hour = Int(time.prefix(2))
            components.minute = Int(time.suffix(2))
        }
        return calendar.date(from: components)
    }

    /// Ähnlichkeit zweier Vergleichsformen zwischen 0 und 1.
    ///
    /// Damerau-Levenshtein statt reinem Levenshtein: Der häufigste Tippfehler
    /// ist der Dreher, und `Slwo` gegen `Slow` kostet dort eine statt zwei
    /// Änderungen. Sonst müsste man die Schwelle so weit senken, dass auch
    /// verschiedene Songs durchgingen.
    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        if lhs.isEmpty || rhs.isEmpty { return 0 }

        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)

        var beforePrevious = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                // Vertauschung zweier benachbarter Zeichen.
                if i > 1, j > 1, left[i - 1] == right[j - 2], left[i - 2] == right[j - 1] {
                    value = min(value, beforePrevious[j - 2] + 1)
                }
                current[j] = value
            }
            beforePrevious = previous
            previous = current
        }

        let distance = Double(previous[right.count])
        return 1 - distance / Double(max(left.count, right.count))
    }
}
