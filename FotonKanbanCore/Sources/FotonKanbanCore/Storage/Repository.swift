import Foundation

/// Der vollständige Inhalt eines Board-Ordners.
public struct Repository: Sendable {
    public var tracks: [Track]
    public var releases: [Release]
    public var config: Config
    /// Dateien, die nicht gelesen werden konnten — die App zeigt sie als
    /// Hinweis an, statt sie stillschweigend zu verschlucken.
    public var skippedFiles: [String]

    public init(
        tracks: [Track] = [],
        releases: [Release] = [],
        config: Config = .default,
        skippedFiles: [String] = []
    ) {
        self.tracks = tracks
        self.releases = releases
        self.config = config
        self.skippedFiles = skippedFiles
    }

    /// Die Tracks einer Spalte, nach Priorität — oben am wichtigsten.
    public func tracks(in status: Status) -> [Track] {
        tracks
            .filter { $0.status == status }
            .sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    }

    /// Tracks ohne Release.
    public var backlog: [Track] {
        tracks.filter { $0.release == nil }.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    }

    public func tracks(inRelease id: String) -> [Track] {
        tracks.filter { $0.release == id }.sorted { ($0.phase, $0.order) < ($1.phase, $1.order) }
    }

    public func release(_ id: String?) -> Release? {
        guard let id else { return nil }
        return releases.first { $0.id == id }
    }

    /// Releases nach Termin, undatierte ans Ende.
    public var scheduledReleases: [Release] {
        releases.sorted { lhs, rhs in
            switch (lhs.target, rhs.target) {
            case (let l?, let r?): l < r
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil): lhs.title < rhs.title
            }
        }
    }

    public var trackIDs: Set<String> { Set(tracks.map(\.id)) }
    public var releaseIDs: Set<String> { Set(releases.map(\.id)) }
}

/// Die Naht, an der später ein anderes Backend andocken könnte.
public protocol TrackStore {
    func load() throws -> Repository
    func save(_ track: Track) throws
    func save(_ release: Release) throws
    func save(_ config: Config) throws
    func delete(trackID: String) throws
    func delete(releaseID: String) throws
}
