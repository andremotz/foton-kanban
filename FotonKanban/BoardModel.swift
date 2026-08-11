import Foundation
import FotonKanbanCore
import Observation

enum SidebarItem: Hashable {
    case allTracks
    case backlog
    case release(String)
    case year
}

@MainActor
@Observable
final class BoardModel {
    private(set) var repository = Repository()
    private(set) var folderURL: URL?
    private(set) var errorMessage: String?

    var sidebarSelection: SidebarItem? = .allTracks
    var selectedTrackID: String?
    var searchText = ""

    /// Zu jedem Track die gefundenen Fassungen, einmal beim Laden aufgelöst.
    /// Die Suche gehört nicht in eine `body`-Auswertung — sie liefe sonst bei
    /// jedem Neuzeichnen.
    private(set) var bouncesByTrack: [String: [Bounce]] = [:]

    private var store: FileTrackStore?
    private var watcher: FolderWatcher?
    private var previewsWatcher: FolderWatcher?
    /// Nach eigenen Schreibvorgängen kurz taub stellen — sonst löst jedes
    /// Speichern über FSEvents ein Neuladen aus.
    private var ignoreChangesUntil = Date.distantPast
    private var pendingSaves: [String: Task<Void, Never>] = [:]

    var selectedTrack: Track? {
        selectedTrackID.flatMap { id in repository.tracks.first { $0.id == id } }
    }

    // MARK: - Ordner

    func openLastFolder() {
        guard let url = BoardFolder.remembered() else { return }
        open(url)
    }

    func open(_ url: URL) {
        let store = FileTrackStore(root: url)
        self.store = store
        folderURL = url
        BoardFolder.remember(url)
        reload()

        watcher?.stop()
        watcher = FolderWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.reloadFromDisk() }
        }
        watcher?.start()
    }

    func closeFolder() {
        watcher?.stop()
        watcher = nil
        previewsWatcher?.stop()
        previewsWatcher = nil
        bouncesByTrack = [:]
        store = nil
        folderURL = nil
        repository = Repository()
        BoardFolder.forget()
    }

    func reload() {
        guard let store else { return }
        do {
            repository = try store.load()
            errorMessage = nil
            indexBounces()
        } catch {
            errorMessage = "Ordner konnte nicht gelesen werden: \(error.localizedDescription)"
        }
    }

    // MARK: - Bounces

    /// Baut den Index über den Previews-Ordner und löst ihn für alle Tracks
    /// auf. Ohne eingetragenen Ordner bleibt alles leer und die Anzeige aus.
    private func indexBounces() {
        guard let root = repository.config.previewsRootURL else {
            bouncesByTrack = [:]
            previewsWatcher?.stop()
            previewsWatcher = nil
            return
        }

        let index = BounceIndex(root: root)
        var resolved: [String: [Bounce]] = [:]
        for track in repository.tracks {
            var list = index.bounces(matching: track.title)
            // Eine von Hand zugewiesene Datei steht vorn und ersetzt den
            // automatischen Fund an dieser Stelle.
            if let pinned = pinnedBounce(for: track, root: root) {
                list.removeAll { $0.url == pinned.url }
                list.insert(pinned, at: 0)
            }
            if !list.isEmpty { resolved[track.id] = list }
        }
        bouncesByTrack = resolved

        if previewsWatcher == nil {
            previewsWatcher = FolderWatcher(url: root) { [weak self] in
                Task { @MainActor in self?.reload() }
            }
            previewsWatcher?.start()
        }
    }

    private func pinnedBounce(for track: Track, root: URL) -> Bounce? {
        guard let audio = track.audio, !audio.isEmpty else { return nil }
        let url = Self.resolve(path: audio, relativeTo: root)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return Bounce(
            url: url,
            songName: BounceNaming.songName(from: stem),
            date: BounceNaming.date(from: stem) ?? Date.distantPast,
            isMaster: stem.lowercased().contains("master")
        )
    }

    /// Absolute Pfade und `~` bleiben, alles andere gilt relativ zum
    /// Previews-Ordner.
    static func resolve(path: String, relativeTo root: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return root.appending(path: path, directoryHint: .notDirectory)
    }

    /// Umgekehrt: innerhalb des Previews-Ordners wird relativ gespeichert,
    /// außerhalb mit `~`, damit der Eintrag auf mehreren Rechnern gilt.
    static func store(url: URL, relativeTo root: URL) -> String {
        let path = url.path(percentEncoded: false)
        let rootPath = root.path(percentEncoded: false)
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return path
    }

    func bounces(for track: Track) -> [Bounce] { bouncesByTrack[track.id] ?? [] }

    /// Weist einem Track eine Datei fest zu.
    func setAudio(_ url: URL, for trackID: String) {
        guard var track = repository.tracks.first(where: { $0.id == trackID }) else { return }
        guard let root = repository.config.previewsRootURL else {
            errorMessage = "Kein Previews-Ordner eingetragen. Trage previews-root in .foton/config.md ein."
            return
        }
        track.audio = Self.store(url: url, relativeTo: root)
        track.updated = Date()
        update(track)
        indexBounces()
    }

    /// Nimmt die feste Zuweisung zurück; danach greift wieder die Suche.
    func clearAudio(for trackID: String) {
        guard var track = repository.tracks.first(where: { $0.id == trackID }) else { return }
        track.audio = nil
        track.updated = Date()
        update(track)
        indexBounces()
    }

    /// Neuladen auf Zuruf des Watchers — unterdrückt, solange die eigenen
    /// Schreibvorgänge nachhallen.
    private func reloadFromDisk() {
        guard Date() >= ignoreChangesUntil else { return }
        reload()
    }

    // MARK: - Tracks

    @discardableResult
    func createTrack(title: String = "Neuer Track", release: String? = nil) -> Track? {
        guard let store else { return nil }
        let last = repository.tracks(in: .open).last?.order
        var track = Track(
            id: Track.makeID(existing: repository.trackIDs),
            title: title,
            release: release,
            order: Ordering.value(between: last, and: nil) ?? Ordering.step
        )
        track.reconcileChecks(with: repository.config)
        do {
            try write { try store.save(track) }
            repository.tracks.append(track)
            selectedTrackID = track.id
            return track
        } catch {
            errorMessage = "Track konnte nicht angelegt werden: \(error.localizedDescription)"
            return nil
        }
    }

    /// Sofort speichern — für strukturelle Änderungen wie Verschieben.
    func update(_ track: Track) {
        guard let store else { return }
        apply(track)
        do {
            try write { try store.save(track) }
        } catch {
            errorMessage = "Track konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    /// Verzögert speichern — für Tippen in Titel- und Notizfeldern, damit nicht
    /// jeder Tastendruck eine Datei schreibt.
    func scheduleSave(_ track: Track) {
        apply(track)
        pendingSaves[track.id]?.cancel()
        pendingSaves[track.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.update(track)
            self?.pendingSaves[track.id] = nil
        }
    }

    private func apply(_ track: Track) {
        if let index = repository.tracks.firstIndex(where: { $0.id == track.id }) {
            repository.tracks[index] = track
        } else {
            repository.tracks.append(track)
        }
    }

    func delete(trackID: String) {
        guard let store else { return }
        do {
            try write { try store.delete(trackID: trackID) }
            repository.tracks.removeAll { $0.id == trackID }
            if selectedTrackID == trackID { selectedTrackID = nil }
        } catch {
            errorMessage = "Track konnte nicht gelöscht werden: \(error.localizedDescription)"
        }
    }

    /// Verschiebt einen Track in eine Spalte. `before` gibt die Karte an, vor
    /// der er einsortiert wird — sonst landet er unten, also mit der
    /// niedrigsten Priorität.
    func move(trackID: String, to status: Status, before: String? = nil) {
        guard var track = repository.tracks.first(where: { $0.id == trackID }) else { return }

        track.move(to: status)
        // Eine bestandene Review schickt den Track in die nächste Phase und
        // zurück nach `in progress` — deshalb zählt die Spalte, in der er
        // tatsächlich landet, nicht die, auf die gezogen wurde.
        let destination = track.status
        var neighbours = repository.tracks(in: destination).filter { $0.id != trackID }

        let index = before.flatMap { id in neighbours.firstIndex { $0.id == id } } ?? neighbours.count
        let previousOrder = index > 0 ? neighbours[index - 1].order : nil
        let nextOrder = index < neighbours.count ? neighbours[index].order : nil

        if let order = Ordering.value(between: previousOrder, and: nextOrder) {
            track.order = order
            update(track)
        } else {
            // Kein Platz mehr zwischen den Nachbarn: Zelle einmal neu vergeben.
            neighbours.insert(track, at: index)
            for renumbered in Ordering.renumber(neighbours) {
                if renumbered.id == trackID { track = renumbered } else { update(renumbered) }
            }
            update(track)
        }
    }

    func setPhase(_ phase: Phase, for trackID: String) {
        guard var track = repository.tracks.first(where: { $0.id == trackID }) else { return }
        track.setPhase(phase)
        update(track)
    }

    /// Nimmt alle Haken der Checkliste zurück, etwa vor einem neuen Durchgang.
    func resetChecks(for trackID: String) {
        guard var track = repository.tracks.first(where: { $0.id == trackID }) else { return }
        track.resetChecks()
        update(track)
    }

    func setRelease(_ releaseID: String?, for trackID: String) {
        guard var track = repository.tracks.first(where: { $0.id == trackID }) else { return }
        track.release = releaseID
        track.updated = Date()
        update(track)
    }

    // MARK: - Releases

    @discardableResult
    func createRelease(target: Date) -> Release? {
        guard let store else { return nil }
        let release = Release(
            id: Release.makeID(target: target, existing: repository.releaseIDs),
            title: "Neues Release",
            target: target
        )
        do {
            try write { try store.save(release) }
            repository.releases.append(release)
            return release
        } catch {
            errorMessage = "Release konnte nicht angelegt werden: \(error.localizedDescription)"
            return nil
        }
    }

    func update(_ release: Release) {
        guard let store else { return }
        if let index = repository.releases.firstIndex(where: { $0.id == release.id }) {
            repository.releases[index] = release
        } else {
            repository.releases.append(release)
        }
        do {
            try write { try store.save(release) }
        } catch {
            errorMessage = "Release konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    /// Löscht ein Release. Die zugeordneten Tracks wandern in den Backlog,
    /// statt mit verschwundener Referenz zurückzubleiben.
    func delete(releaseID: String) {
        guard let store else { return }
        do {
            try write { try store.delete(releaseID: releaseID) }
            repository.releases.removeAll { $0.id == releaseID }
            for track in repository.tracks where track.release == releaseID {
                setRelease(nil, for: track.id)
            }
            if sidebarSelection == .release(releaseID) { sidebarSelection = .allTracks }
        } catch {
            errorMessage = "Release konnte nicht gelöscht werden: \(error.localizedDescription)"
        }
    }

    // MARK: - Sichten

    /// Die Tracks einer Spalte, gefiltert nach Seitenleiste und Suche.
    func visibleTracks(in status: Status) -> [Track] {
        repository.tracks(in: status).filter(matchesFilters)
    }

    private func matchesFilters(_ track: Track) -> Bool {
        switch sidebarSelection {
        case .backlog where track.release != nil: return false
        case .release(let id) where track.release != id: return false
        default: break
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return track.title.localizedCaseInsensitiveContains(query)
            || track.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            || track.notes.localizedCaseInsensitiveContains(query)
    }

    func dismissError() { errorMessage = nil }

    private func write(_ body: () throws -> Void) rethrows {
        ignoreChangesUntil = Date().addingTimeInterval(1.5)
        try body()
    }
}
