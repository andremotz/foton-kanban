import Foundation

/// Einstellungen, die im Repo liegen und damit mitsynchronisiert werden.
public struct Config: Hashable, Codable, Sendable {
    /// Abhörsituationen für die Checkliste, in dieser Reihenfolge. Diese Liste
    /// ist maßgeblich — Tracks halten nur den Zustand dazu.
    /// `Studio 45°` meint das Abhören des Masters 45° neben dem Lautsprecher.
    public var listeningSituations: [String]
    /// Richtwert für den Abstand zweier Releases in der Jahresansicht.
    public var releaseCadenceWeeks: Int
    /// Ordner mit den Preview-Bounces. Eine Tilde am Anfang bleibt stehen,
    /// damit derselbe Eintrag auf mehreren Rechnern gilt.
    /// Ohne diesen Wert bleibt die Bounce-Anzeige aus.
    public var previewsRoot: String?

    public static let `default` = Config(
        listeningSituations: [
            "Auto", "AirPods", "Bose Kopfhörer", "Bose Lautsprecher", "Studio", "Studio 45°",
        ],
        releaseCadenceWeeks: 6
    )

    public init(
        listeningSituations: [String],
        releaseCadenceWeeks: Int,
        previewsRoot: String? = nil
    ) {
        self.listeningSituations = listeningSituations
        self.releaseCadenceWeeks = releaseCadenceWeeks
        self.previewsRoot = previewsRoot
    }

    /// Der aufgelöste Ordner, sofern einer eingetragen ist.
    public var previewsRootURL: URL? {
        guard let previewsRoot, !previewsRoot.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let expanded = (previewsRoot as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// Wie eine Datei in der Track-Datei notiert wird.
    ///
    /// Innerhalb des Previews-Ordners relativ, sonst mit `~` — ein absoluter
    /// Pfad enthielte den Benutzernamen und wäre auf einem zweiten Rechner
    /// wertlos.
    public func storedPath(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> String
    {
        let path = Self.plainPath(url)
        if let root = previewsRootURL {
            // Verzeichnis-URLs enden auf einem Schrägstrich; ohne diese
            // Bereinigung schlägt der Präfixvergleich fehl.
            let rootPath = Self.plainPath(root)
            if path.hasPrefix(rootPath + "/") {
                return String(path.dropFirst(rootPath.count + 1))
            }
        }
        let homePath = Self.plainPath(home)
        if path.hasPrefix(homePath + "/") {
            return "~/" + path.dropFirst(homePath.count + 1)
        }
        return path
    }

    /// Der umgekehrte Weg: aus dem Eintrag wieder eine Datei.
    public func resolvedURL(for stored: String) -> URL? {
        guard !stored.isEmpty else { return nil }
        if stored.hasPrefix("/") { return URL(fileURLWithPath: stored) }
        if stored.hasPrefix("~") {
            return URL(fileURLWithPath: (stored as NSString).expandingTildeInPath)
        }
        guard let root = previewsRootURL else { return nil }
        return root.appending(path: stored, directoryHint: .notDirectory)
    }

    /// Pfad ohne abschließenden Schrägstrich, damit Vergleiche verlässlich sind.
    private static func plainPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
