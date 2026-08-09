import Foundation

/// Einstellungen, die im Repo liegen und damit mitsynchronisiert werden.
public struct Config: Hashable, Codable, Sendable {
    /// Abhörsituationen für die Checkliste, in dieser Reihenfolge. Diese Liste
    /// ist maßgeblich — Tracks halten nur den Zustand dazu.
    /// `Studio 45°` meint das Abhören des Masters 45° neben dem Lautsprecher.
    public var listeningSituations: [String]
    /// Richtwert für den Abstand zweier Releases in der Jahresansicht.
    public var releaseCadenceWeeks: Int

    public static let `default` = Config(
        listeningSituations: [
            "Auto", "AirPods", "Bose Kopfhörer", "Bose Lautsprecher", "Studio", "Studio 45°",
        ],
        releaseCadenceWeeks: 6
    )

    public init(listeningSituations: [String], releaseCadenceWeeks: Int) {
        self.listeningSituations = listeningSituations
        self.releaseCadenceWeeks = releaseCadenceWeeks
    }
}
