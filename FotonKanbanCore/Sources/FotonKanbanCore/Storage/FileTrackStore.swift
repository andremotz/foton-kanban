import Foundation

/// Legt jeden Track und jedes Release in eine eigene Markdown-Datei. Eine
/// Board-Aktion berührt damit genau eine Datei — Voraussetzung dafür, dass
/// Git die Synchronisation später ohne Handarbeit hinbekommt.
public final class FileTrackStore: TrackStore {
    public let root: URL

    /// Merkt sich, aus welcher Datei eine ID stammt. Der Dateiname wird beim
    /// Anlegen aus dem Titel abgeleitet und danach nicht mehr geändert, damit
    /// die Git-Historie einer Datei zusammenhängend bleibt.
    private var trackFiles: [String: URL] = [:]
    private var releaseFiles: [String: URL] = [:]

    private var tracksDirectory: URL { root.appending(path: "tracks", directoryHint: .isDirectory) }
    private var releasesDirectory: URL { root.appending(path: "releases", directoryHint: .isDirectory) }
    private var configFile: URL {
        root.appending(path: ".foton", directoryHint: .isDirectory)
            .appending(path: "config.md", directoryHint: .notDirectory)
    }

    public init(root: URL) {
        self.root = root
    }

    /// Legt die Ordnerstruktur an, falls sie fehlt. Idempotent.
    public func prepare() throws {
        for directory in [tracksDirectory, releasesDirectory, configFile.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Lesen

    public func load() throws -> Repository {
        try prepare()
        trackFiles.removeAll()
        releaseFiles.removeAll()

        var repository = Repository(config: try loadConfig())

        for url in try markdownFiles(in: tracksDirectory) {
            let stem = url.deletingPathExtension().lastPathComponent
            do {
                var track = try MarkdownCodec.decodeTrack(
                    try String(contentsOf: url, encoding: .utf8),
                    fallbackID: fallbackID(from: stem)
                )
                // Die Konfiguration bestimmt die Checkliste, nicht die Datei —
                // neue Abhörsituationen erscheinen so auf allen Tracks.
                track.reconcileChecks(with: repository.config)
                repository.tracks.append(track)
                trackFiles[track.id] = url
            } catch {
                repository.skippedFiles.append(url.lastPathComponent)
            }
        }

        for url in try markdownFiles(in: releasesDirectory) {
            let stem = url.deletingPathExtension().lastPathComponent
            do {
                let release = try MarkdownCodec.decodeRelease(
                    try String(contentsOf: url, encoding: .utf8), fallbackID: stem
                )
                repository.releases.append(release)
                releaseFiles[release.id] = url
            } catch {
                repository.skippedFiles.append(url.lastPathComponent)
            }
        }

        return repository
    }

    private func loadConfig() throws -> Config {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else {
            try save(Config.default)
            return .default
        }
        return MarkdownCodec.decodeConfig(text)
    }

    private func markdownFiles(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return contents
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Aus `k3f9-ferrite` wird `k3f9` — falls im Frontmatter die ID fehlt.
    private func fallbackID(from stem: String) -> String {
        stem.split(separator: "-").first.map(String.init) ?? stem
    }

    // MARK: - Schreiben

    public func save(_ track: Track) throws {
        let url = trackFiles[track.id] ?? uniqueURL(
            in: tracksDirectory, stem: track.suggestedFileStem
        )
        try write(MarkdownCodec.encode(track), to: url)
        trackFiles[track.id] = url
    }

    public func save(_ release: Release) throws {
        let url = releaseFiles[release.id] ?? uniqueURL(in: releasesDirectory, stem: release.id)
        try write(MarkdownCodec.encode(release), to: url)
        releaseFiles[release.id] = url
    }

    public func save(_ config: Config) throws {
        try prepare()
        try write(MarkdownCodec.encode(config), to: configFile)
    }

    public func delete(trackID: String) throws {
        guard let url = trackFiles[trackID] else { return }
        try FileManager.default.removeItem(at: url)
        trackFiles[trackID] = nil
    }

    public func delete(releaseID: String) throws {
        guard let url = releaseFiles[releaseID] else { return }
        try FileManager.default.removeItem(at: url)
        releaseFiles[releaseID] = nil
    }

    /// `.atomic` schreibt in eine temporäre Datei und benennt sie um. Damit
    /// sieht ein gleichzeitig laufender Sync nie eine halbe Datei.
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func uniqueURL(in directory: URL, stem: String) -> URL {
        var candidate = directory.appending(path: "\(stem).md", directoryHint: .notDirectory)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = directory.appending(path: "\(stem)-\(suffix).md", directoryHint: .notDirectory)
            suffix += 1
        }
        return candidate
    }
}
