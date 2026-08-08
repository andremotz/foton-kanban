import Foundation

public enum ReleaseState: String, CaseIterable, Codable, Sendable {
    case planned
    case inProgress = "in-progress"
    case released

    public var title: String {
        switch self {
        case .planned: "geplant"
        case .inProgress: "in Arbeit"
        case .released: "veröffentlicht"
        }
    }
}

/// Ein Veröffentlichungsziel. Tracks verweisen über `Track.release` hierher,
/// deshalb kostet ein Wechsel zwischen Releases nur ein geändertes Feld.
public struct Release: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Wunschtermin. Wird von Hand gesetzt und in der Jahresansicht verschoben.
    public var target: Date?
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
        self.state = state
        self.created = created
        self.updated = updated
        self.notes = notes
        self.unknownFrontmatter = unknownFrontmatter
        self.extraSections = extraSections
    }

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
