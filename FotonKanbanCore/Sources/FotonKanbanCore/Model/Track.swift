import Foundation

/// Ein Song — die Arbeitseinheit des Boards.
public struct Track: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Woran gerade gearbeitet wird. Wird über die Review weitergerückt oder
    /// im Inspector von Hand gesetzt.
    public var phase: Phase
    /// Die Board-Spalte.
    public var status: Status
    /// ID des Releases, oder `nil` für den Backlog. Ein Wechsel zwischen
    /// Releases ändert nur dieses Feld — keine Datei wechselt den Ordner.
    public var release: String?
    /// Priorität innerhalb der Spalte, in Tausenderschritten. Kleiner Wert
    /// heißt weiter oben und damit wichtiger.
    public var order: Int
    /// Wie oft der Track schon in Review war. Ersetzt die frühere
    /// Runden-Historie durch die eine Zahl, die im Alltag zählt.
    public var reviewRounds: Int
    public var created: Date
    public var updated: Date
    public var tags: [String]
    public var notes: String
    /// Abhör-Checkliste. Der Bestand kommt aus der Konfiguration, hier steht
    /// nur, was abgehakt und notiert wurde.
    public var checks: [ListeningCheck]

    public var unknownFrontmatter: [String: FrontmatterValue]
    public var extraSections: [BodySection]

    public init(
        id: String,
        title: String,
        phase: Phase = .jamSession,
        status: Status = .open,
        release: String? = nil,
        order: Int = Ordering.step,
        reviewRounds: Int = 0,
        created: Date = Date(),
        updated: Date = Date(),
        tags: [String] = [],
        notes: String = "",
        checks: [ListeningCheck] = [],
        unknownFrontmatter: [String: FrontmatterValue] = [:],
        extraSections: [BodySection] = []
    ) {
        self.id = id
        self.title = title
        self.phase = phase
        self.status = status
        self.release = release
        self.order = order
        self.reviewRounds = reviewRounds
        self.created = created
        self.updated = updated
        self.tags = tags
        self.notes = notes
        self.checks = checks
        self.unknownFrontmatter = unknownFrontmatter
        self.extraSections = extraSections
    }

    /// Fertig ist ein Track, wenn er in der done-Spalte liegt. Dorthin kommt er
    /// regulär nur über eine bestandene Mastering-Review.
    public var isFinished: Bool { status == .done }

    // MARK: - Checkliste

    public var checkedCount: Int { checks.count(where: \.isChecked) }

    /// Kurzform für die Karte, z. B. "3/5". Nur beim Mastering, weil die
    /// Checkliste vorher nichts aussagt — und nicht mehr, wenn der Track fertig
    /// ist: an einem abgeschlossenen Track wäre "0/5" eine falsche Aufforderung.
    public var checklistBadge: String? {
        guard phase.usesListeningChecklist, !isFinished, !checks.isEmpty else { return nil }
        return "\(checkedCount)/\(checks.count)"
    }

    /// Gleicht die Checkliste mit der Konfiguration ab: fehlende Situationen
    /// kommen in der dortigen Reihenfolge dazu, bereits Abgehaktes bleibt
    /// erhalten. Situationen, die nicht mehr konfiguriert sind, werden ans Ende
    /// gehängt statt gelöscht — sonst gingen Notizen still verloren.
    public mutating func reconcileChecks(with config: Config) {
        var existing: [String: ListeningCheck] = [:]
        for check in checks where existing[check.situation] == nil {
            existing[check.situation] = check
        }

        var result = config.listeningSituations.map { situation in
            existing.removeValue(forKey: situation) ?? ListeningCheck(situation: situation)
        }
        result.append(contentsOf: checks.filter { existing[$0.situation] != nil })
        checks = result
    }

    /// Nimmt alle Haken zurück, lässt die Notizen aber stehen — die sind der
    /// Befund vom letzten Durchgang und beim nächsten Hören oft noch relevant.
    public mutating func resetChecks(now: Date = Date()) {
        for index in checks.indices {
            checks[index].isChecked = false
        }
        updated = now
    }

    // MARK: - Zustandsübergänge

    /// Zieht den Track in eine andere Spalte.
    ///
    /// Die einzige Automatik: Wandert ein Track aus `in review` nach `done`,
    /// gilt die Review als bestanden. Vor dem Mastering rückt er dann in die
    /// nächste Phase und geht zurück auf `in progress`; nach dem Mastering ist
    /// er fertig und bleibt in `done`.
    public mutating func move(to newStatus: Status, now: Date = Date()) {
        if newStatus == .review, status != .review {
            reviewRounds += 1
        }

        if status == .review, newStatus == .done, let next = phase.next {
            phase = next
            status = .inProgress
        } else {
            status = newStatus
        }
        updated = now
    }

    /// Setzt die Phase von Hand, ohne die Spalte zu ändern.
    public mutating func setPhase(_ newPhase: Phase, now: Date = Date()) {
        guard newPhase != phase else { return }
        phase = newPhase
        updated = now
    }

    // MARK: - Identität

    /// Kurze, aussprechbare ID. Kollisionen werden vom Aufrufer über `existing`
    /// ausgeschlossen.
    public static func makeID(existing: Set<String> = []) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        while true {
            let candidate = String((0..<4).map { _ in alphabet.randomElement()! })
            if !existing.contains(candidate) { return candidate }
        }
    }

    /// Dateiname ohne Endung: `k3f9-ferrite`. Wird beim Anlegen einmal
    /// bestimmt und danach nicht mehr geändert.
    public var suggestedFileStem: String {
        let slug = Track.slugify(title)
        return slug.isEmpty ? id : "\(id)-\(slug)"
    }

    static func slugify(_ text: String) -> String {
        let replacements: [Character: String] = [
            "ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss",
            "Ä": "ae", "Ö": "oe", "Ü": "ue",
        ]
        var out = ""
        var lastWasDash = false
        for character in text.lowercased() {
            if let replacement = replacements[character] {
                out += replacement
                lastWasDash = false
            } else if character.isLetter || character.isNumber {
                // Akzente entfernen, damit der Dateiname ASCII bleibt.
                let folded = String(character).folding(
                    options: [.diacriticInsensitive], locale: Locale(identifier: "en_US")
                )
                out += folded
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out += "-"
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(48))
    }
}

/// Vergabe der `order`-Werte, also der Priorität innerhalb einer Spalte.
/// Lücken von 1000 sorgen dafür, dass ein Einfügen zwischen zwei Karten nur die
/// eingefügte Datei anfasst.
public enum Ordering {
    public static let step = 1000

    /// Der Wert für eine Karte, die zwischen `before` und `after` landen soll.
    /// Gibt `nil` zurück, wenn kein Platz mehr ist — dann muss die Spalte über
    /// `renumber(_:)` neu vergeben werden.
    public static func value(between before: Int?, and after: Int?) -> Int? {
        switch (before, after) {
        case (nil, nil):
            return step
        case (nil, let after?):
            return after > Int.min + step ? after - step : nil
        case (let before?, nil):
            return before < Int.max - step ? before + step : nil
        case (let before?, let after?):
            guard after - before > 1 else { return nil }
            return before + (after - before) / 2
        }
    }

    /// Vergibt die Reihenfolge einer Spalte neu. Liefert nur die Tracks zurück,
    /// deren Wert sich tatsächlich geändert hat.
    public static func renumber(_ tracks: [Track]) -> [Track] {
        tracks.enumerated().compactMap { index, track in
            let value = (index + 1) * step
            guard track.order != value else { return nil }
            var updated = track
            updated.order = value
            return updated
        }
    }
}
