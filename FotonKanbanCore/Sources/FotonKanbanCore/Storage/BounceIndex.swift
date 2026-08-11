import Foundation

/// Eine abgelegte Fassung eines Songs.
public struct Bounce: Hashable, Sendable, Identifiable {
    public var url: URL
    /// Der aus dem Dateinamen gewonnene Songname.
    public var songName: String
    /// Datum aus dem Dateinamen, ersatzweise das Änderungsdatum.
    public var date: Date
    /// Ob der Dateiname sie als Master ausweist.
    public var isMaster: Bool

    public var id: URL { url }

    public init(url: URL, songName: String, date: Date, isMaster: Bool) {
        self.url = url
        self.songName = songName
        self.date = date
        self.isMaster = isMaster
    }

    public var fileName: String { url.lastPathComponent }
}

/// Findet zu einem Track-Titel die abgelegten Fassungen.
///
/// Der Index wird bei jedem Laden neu gebaut — ein Durchlauf über gut
/// tausend Dateien dauert Bruchteile einer Sekunde, dafür ist er nie veraltet
/// und es muss nichts zwischengespeichert werden.
public struct BounceIndex: Sendable {
    /// Ab dieser Ähnlichkeit gilt ein Name als derselbe Song. Empirisch so
    /// gewählt, dass Tippfehler durchgehen, verschiedene Songs aber nicht.
    public static let similarityThreshold = 0.86

    public static let audioExtensions: Set<String> = ["mp3", "aif", "aiff", "wav", "m4a", "flac"]

    private let byKey: [String: [Bounce]]

    public init(bounces: [Bounce]) {
        var grouped: [String: [Bounce]] = [:]
        for bounce in bounces {
            grouped[BounceNaming.matchKey(bounce.songName), default: []].append(bounce)
        }
        // Neueste zuerst; bei gleichem Datum gewinnt der Master.
        byKey = grouped.mapValues { list in
            list.sorted {
                ($0.date, $0.isMaster ? 1 : 0) > ($1.date, $1.isMaster ? 1 : 0)
            }
        }
    }

    /// Liest den Ordner rekursiv ein. Nicht lesbare Ordner werden übergangen,
    /// nicht gemeldet — ein fehlender Previews-Ordner darf das Board nicht
    /// aufhalten.
    public init(root: URL, fileManager: FileManager = .default) {
        var found: [Bounce] = []
        // Ohne vorgeladene Eigenschaften: der Ordner enthält weit mehr
        // Dateien als Audiodateien, und jede vorgeladene Eigenschaft kostet
        // über den ganzen Baum spürbar Zeit.
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let name = BounceNaming.songName(from: stem)
            guard !name.isEmpty else { continue }

            // Das Änderungsdatum wird nur abgefragt, wenn der Name keines
            // hergibt — ein Systemaufruf je Datei kostet über tausend Dateien
            // spürbar Zeit, und fast alle tragen ihr Datum im Namen.
            let date =
                BounceNaming.date(from: stem)
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                ?? .distantPast

            found.append(
                Bounce(
                    url: url,
                    songName: name,
                    date: date,
                    isMaster: stem.lowercased().contains("master")
                )
            )
        }
        self.init(bounces: found)
    }

    public var isEmpty: Bool { byKey.isEmpty }
    public var count: Int { byKey.values.reduce(0) { $0 + $1.count } }

    /// Alle Fassungen zu einem Track-Titel, neueste zuerst.
    ///
    /// Der Titel wird genauso bereinigt wie ein Dateiname — manche Titel sind
    /// selbst aus Dateinamen entstanden und tragen Datum und `preview` mit
    /// sich herum. Erst wird exakt verglichen, dann unscharf.
    public func bounces(matching title: String) -> [Bounce] {
        let key = BounceNaming.matchKey(BounceNaming.songName(from: title))
        guard !key.isEmpty else { return [] }
        if let exact = byKey[key] { return exact }

        // Vor dem teuren Vergleich ein billiger Ausschluss: Die Distanz ist
        // mindestens so groß wie der Längenunterschied, also kann die
        // Ähnlichkeit die Schwelle bei sehr verschiedenen Längen gar nicht
        // erreichen. Das spart den Löwenanteil der Rechnerei.
        let tolerance = 1 - Self.similarityThreshold
        var best: (key: String, score: Double)?
        for candidate in byKey.keys {
            let longest = max(key.count, candidate.count)
            guard Double(abs(key.count - candidate.count)) <= tolerance * Double(longest)
            else { continue }

            let score = BounceNaming.similarity(key, candidate)
            if score >= Self.similarityThreshold, score > (best?.score ?? 0) {
                best = (candidate, score)
            }
        }
        return best.flatMap { byKey[$0.key] } ?? []
    }

    /// Die aktuelle Fassung, oder `nil` wenn es keine gibt.
    public func newestBounce(matching title: String) -> Bounce? {
        bounces(matching: title).first
    }
}
