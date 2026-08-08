import Foundation

/// Eine Abhörsituation auf der Checkliste eines Tracks.
///
/// Welche Situationen es gibt, steht in der Konfiguration — der Track hält nur
/// den Zustand dazu. Kommt später eine Situation dazu, erscheint sie dadurch
/// auf allen Tracks, statt dass ältere bei der alten Liste hängenbleiben.
public struct ListeningCheck: Hashable, Codable, Sendable, Identifiable {
    public var situation: String
    public var isChecked: Bool
    /// Was dort aufgefallen ist.
    public var note: String

    public var id: String { situation }

    public init(situation: String, isChecked: Bool = false, note: String = "") {
        self.situation = situation
        self.isChecked = isChecked
        self.note = note
    }
}
