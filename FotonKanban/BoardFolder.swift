import Foundation

/// Merkt sich den zuletzt geöffneten Board-Ordner als Bookmark statt als Pfad,
/// damit ein Verschieben oder Umbenennen des Ordners die Verknüpfung nicht
/// zerreißt.
enum BoardFolder {
    private static let defaultsKey = "boardFolderBookmark"

    static func remembered() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        if isStale { remember(url) }
        return url
    }

    static func remember(_ url: URL) {
        guard let data = try? url.bookmarkData() else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
