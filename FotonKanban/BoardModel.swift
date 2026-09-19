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
    /// Ob die Board-Ansicht auch Tracks veröffentlichter Releases zeigt.
    /// Eine Ansichtssache des Arbeitsplatzes, deshalb nicht im Board.
    var showsReleasedTracks: Bool = UserDefaults.standard.bool(forKey: "showsReleasedTracks") {
        didSet { UserDefaults.standard.set(showsReleasedTracks, forKey: "showsReleasedTracks") }
    }
    /// Mehrfachauswahl. Ein einzelner Track ist der Normalfall, deshalb gibt
    /// es `selectedTrack` weiterhin — es liefert nur bei genau einem etwas.
    var selectedTrackIDs: Set<String> = []
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
        guard selectedTrackIDs.count == 1, let id = selectedTrackIDs.first else { return nil }
        return repository.tracks.first { $0.id == id }
    }

    /// Die ausgewählten Tracks in Boardreihenfolge — Spalte, dann Priorität.
    var selectedTracks: [Track] {
        repository.tracks
            .filter { selectedTrackIDs.contains($0.id) }
            .sorted { ($0.status, $0.order) < ($1.status, $1.order) }
    }

    // MARK: - Auswahl

    func select(_ id: String) { selectedTrackIDs = [id] }

    func toggleSelection(_ id: String) {
        if selectedTrackIDs.contains(id) {
            selectedTrackIDs.remove(id)
        } else {
            selectedTrackIDs.insert(id)
        }
    }

    /// Auswahl bis zur angeklickten Karte erweitern. `column` ist die
    /// Reihenfolge, wie sie gerade zu sehen ist — über Spaltengrenzen hinweg
    /// zu greifen wäre schwer vorhersagbar.
    func extendSelection(to id: String, within column: [String]) {
        guard let end = column.firstIndex(of: id) else { return }
        guard let anchor = column.firstIndex(where: { selectedTrackIDs.contains($0) }) else {
            selectedTrackIDs = [id]
            return
        }
        let range = anchor <= end ? anchor...end : end...anchor
        selectedTrackIDs.formUnion(column[range])
    }

    /// Nimmt allen ausgewählten Tracks das Release. Sie landen damit im
    /// Backlog, ohne dass das Release selbst verschwindet.
    func moveSelectionToBacklog() {
        for track in selectedTracks where track.release != nil {
            setRelease(nil, for: track.id)
        }
    }

    func assignSelection(to releaseID: String?) {
        for track in selectedTracks where track.release != releaseID {
            setRelease(releaseID, for: track.id)
        }
    }

    func deleteSelection() {
        for id in selectedTracks.map(\.id) { delete(trackID: id) }
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
            // Nur zuweisen, wenn sich tatsächlich etwas geändert hat. Der
            // Board-Ordner liegt in der Regel in einer Cloud, und jede
            // Sync-Regung meldet der Watcher. Eine bedingungslose Zuweisung
            // ersetzt das gesamte Repository und zeichnet Board samt Inspector
            // neu — bei ruhendem Inhalt völlig umsonst.
            let loaded = try store.load()
            if loaded != repository { repository = loaded }
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
            // Unter beiden Namen suchen: Bounces vor der Umbenennung tragen
            // den Arbeitsnamen, spätere womöglich schon den Release-Titel.
            var list: [Bounce] = []
            for name in track.names {
                for bounce in index.bounces(matching: name)
                where !list.contains(where: { $0.url == bounce.url }) {
                    list.append(bounce)
                }
            }
            list.sort { $0.date > $1.date }
            // Eine von Hand zugewiesene Datei steht vorn und ersetzt den
            // automatischen Fund an dieser Stelle.
            if let pinned = pinnedBounce(for: track) {
                list.removeAll { $0.url == pinned.url }
                list.insert(pinned, at: 0)
            }
            if !list.isEmpty { resolved[track.id] = list }
        }
        if resolved != bouncesByTrack { bouncesByTrack = resolved }

        if previewsWatcher == nil {
            previewsWatcher = FolderWatcher(url: root) { [weak self] in
                // Nur den Index auffrischen, nicht das Board neu laden: Ein
                // Bounce im Previews-Ordner sagt nichts über die Track-Dateien
                // aus. `reload()` ersetzte hier das gesamte Repository und
                // zeichnete das Board komplett neu — bei einem Ordner, den
                // Nextcloud laufend synchronisiert, immer wieder.
                Task { @MainActor in self?.indexBounces() }
            }
            previewsWatcher?.start()
        }
    }

    private func pinnedBounce(for track: Track) -> Bounce? {
        guard let audio = track.audio, !audio.isEmpty else { return nil }
        guard let url = repository.config.resolvedURL(for: audio) else { return nil }
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

    func bounces(for track: Track) -> [Bounce] { bouncesByTrack[track.id] ?? [] }

    /// Weist einem Track eine Datei fest zu.
    func setAudio(_ url: URL, for trackID: String) {
        guard var track = repository.tracks.first(where: { $0.id == trackID }) else { return }
        guard repository.config.previewsRootURL != nil else {
            errorMessage = "Kein Previews-Ordner eingetragen. Trage previews-root in .foton/config.md ein."
            return
        }
        track.audio = repository.config.storedPath(for: url)
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
            selectedTrackIDs = [track.id]
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
            selectedTrackIDs.remove(trackID)
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

    /// Verschiebt mehrere Tracks gemeinsam in eine Spalte.
    ///
    /// Die Zielspalte wird danach durchnummeriert, statt Lücken zu suchen: Für
    /// eine Gruppe reicht der Platz zwischen zwei Nachbarn selten, und eine
    /// Spalte hat höchstens ein paar Dutzend Karten. Geschrieben werden nur die
    /// Dateien, deren Wert sich wirklich ändert.
    func move(trackIDs: [String], to status: Status, before: String? = nil) {
        guard trackIDs.count > 1 else {
            if let single = trackIDs.first { move(trackID: single, to: status, before: before) }
            return
        }

        let moving = repository.tracks
            .filter { trackIDs.contains($0.id) }
            .sorted { ($0.status, $0.order) < ($1.status, $1.order) }
        guard !moving.isEmpty else { return }

        var updated: [Track] = []
        for var track in moving {
            track.move(to: status)
            updated.append(track)
        }
        // `move` kann die Phase weiterrücken und dabei die Spalte wechseln;
        // maßgeblich ist, wo die Tracks tatsächlich landen.
        let destination = updated[0].status
        let inDestination = updated.filter { $0.status == destination }
        let elsewhere = updated.filter { $0.status != destination }

        var column = repository.tracks(in: destination).filter { !trackIDs.contains($0.id) }
        let index = before.flatMap { id in column.firstIndex { $0.id == id } } ?? column.count
        column.insert(contentsOf: inDestination, at: index)

        var byID = Dictionary(uniqueKeysWithValues: column.map { ($0.id, $0) })
        for renumbered in Ordering.renumber(column) { byID[renumbered.id] = renumbered }

        for track in inDestination { update(byID[track.id] ?? track) }
        for track in elsewhere { update(track) }
        for track in column where !trackIDs.contains(track.id) {
            if let renumbered = byID[track.id], renumbered.order != track.order {
                update(renumbered)
            }
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

    /// Setzt ein Release auf veröffentlicht oder nimmt das zurück.
    ///
    /// Nimmt den Zielzustand entgegen, statt blind zu kippen: Ein Umschalter,
    /// der den eingehenden Wert ignoriert, dreht sich bei jedem unbeabsichtigten
    /// Schreibzugriff um.
    func setReleased(_ isReleased: Bool, for releaseID: String) {
        guard var release = repository.releases.first(where: { $0.id == releaseID }),
            (release.state == .released) != isReleased
        else { return }
        release.state = isReleased ? .released : .inProgress
        release.updated = Date()
        update(release)
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
        case .allTracks:
            // In der Gesamtansicht zählt, woran gerade gearbeitet wird. Wer ein
            // veröffentlichtes Release ausdrücklich anwählt, sieht es weiterhin
            // vollständig — der Filter greift nur hier.
            if !showsReleasedTracks, let release = track.release,
                repository.releasedReleaseIDs.contains(release) {
                return false
            }
        default: break
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return track.names.contains { $0.localizedCaseInsensitiveContains(query) }
            || track.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            || track.notes.localizedCaseInsensitiveContains(query)
    }

    func dismissError() { errorMessage = nil }

    private func write(_ body: () throws -> Void) rethrows {
        ignoreChangesUntil = Date().addingTimeInterval(1.5)
        try body()
    }
}
