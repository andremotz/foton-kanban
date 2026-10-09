import Foundation

public enum ReleaseState: String, CaseIterable, Codable, Sendable {
    case planned
    case inProgress = "in-progress"
    /// Die Arbeit ist fertig und abgeliefert; wann es erscheint, entscheidet
    /// jemand anderes. Ohne diesen Zustand musste man sich ein
    /// Erscheinungsdatum ausdenken, um das Release nicht zu verlieren.
    case submitted
    case released

    public var title: String {
        switch self {
        case .planned: "geplant"
        case .inProgress: "in Arbeit"
        case .submitted: "abgegeben"
        case .released: "veröffentlicht"
        }
    }
}

/// Ein Veröffentlichungsziel. Tracks verweisen über `Track.release` hierher,
/// deshalb kostet ein Wechsel zwischen Releases nur ein geändertes Feld.
public struct Release: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Erscheinungsdatum. Darf leer bleiben, solange es nicht feststeht — bei
    /// einem abgegebenen Release nennt es oft erst das Label.
    public var target: Date?
    /// Abgabetermin. Vor der Abgabe ein Plan, danach der Beleg, wann geliefert
    /// wurde.
    public var submit: Date?
    public var state: ReleaseState
    public var created: Date
    public var updated: Date
    public var notes: String

    /// Frontmatter-Schlüssel, die diese App nicht kennt. Werden beim Speichern
    /// unverändert zurückgeschrieben.
    public var unknownFrontmatter: [String: FrontmatterValue]
    /// Body-Abschnitte jenseits von "Notizen", ebenfalls unverändert erhalten.
    public var extraSections: [BodySection]

    public init(
        id: String,
        title: String,
        target: Date? = nil,
        submit: Date? = nil,
        state: ReleaseState = .planned,
        created: Date = Date(),
        updated: Date = Date(),
        notes: String = "",
        unknownFrontmatter: [String: FrontmatterValue] = [:],
        extraSections: [BodySection] = []
    ) {
        self.id = id
        self.title = title
        self.target = target
        self.submit = submit
        self.state = state
        self.created = created
        self.updated = updated
        self.notes = notes
        self.unknownFrontmatter = unknownFrontmatter
        self.extraSections = extraSections
    }

    /// Das Datum, nach dem in der Planung einsortiert wird: das
    /// Erscheinungsdatum, wenn es feststeht, sonst der Abgabetermin. Fehlt
    /// beides, gehört das Release in die Spalte der ungeplanten.
    public var planningDate: Date? { target ?? submit }

    /// Ob die Arbeit daran abgeschlossen ist — abgegeben zählt dafür ebenso
    /// wie veröffentlicht.
    public var isFinished: Bool { state == .submitted || state == .released }

    /// Erzeugt ein Release mit einer aus dem Termin abgeleiteten, sprechenden ID
    /// (`r-2026-04`), die bei Kollision hochgezählt wird.
    public static func makeID(target: Date, existing: Set<String>, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: target)
        let base = String(format: "r-%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }
}
