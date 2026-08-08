import Foundation

/// Woran gerade gearbeitet wird. Die Phase ist eine Eigenschaft des Tracks,
/// keine Board-Achse — im Kern eine Unterteilung von `in progress`.
public enum Phase: String, CaseIterable, Codable, Sendable, Comparable {
    case jamSession = "jam-session"
    case arrangement
    case mixdown
    case fxFinalizing = "fx-finalizing"
    case mastering

    public var title: String {
        switch self {
        case .jamSession: "Jam Session"
        case .arrangement: "Arrangement"
        case .mixdown: "Mixdown"
        case .fxFinalizing: "FX finalizing"
        case .mastering: "Mastering"
        }
    }

    /// Die nächste Phase, oder `nil` wenn dies die letzte ist.
    public var next: Phase? {
        let all = Phase.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    /// Nur beim Mastering zählt die Abhör-Checkliste wirklich — dort wird sie
    /// auch auf der Karte angezeigt.
    public var usesListeningChecklist: Bool { self == .mastering }

    public static func < (lhs: Phase, rhs: Phase) -> Bool {
        let all = Phase.allCases
        return all.firstIndex(of: lhs)! < all.firstIndex(of: rhs)!
    }
}

/// Die Board-Spalte. Die Reihenfolge der Cases ist die Reihenfolge auf dem
/// Board; innerhalb einer Spalte entscheidet die Priorität.
public enum Status: String, CaseIterable, Codable, Sendable, Comparable {
    case open
    case inProgress = "in-progress"
    case review
    case done

    public var title: String {
        switch self {
        case .open: "open"
        case .inProgress: "in progress"
        case .review: "in review"
        case .done: "done"
        }
    }

    public static func < (lhs: Status, rhs: Status) -> Bool {
        let all = Status.allCases
        return all.firstIndex(of: lhs)! < all.firstIndex(of: rhs)!
    }
}
