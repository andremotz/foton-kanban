import Foundation

/// Schreibt die Fehlerausgabe der App in eine Datei.
///
/// Stürzt die App an einer Objective-C-Ausnahme ab, nennt AppKit den Grund auf
/// der Fehlerausgabe — aber nur dort. Wer die App aus dem Finder startet,
/// verliert sie ans System-Log, aus dem sie nach Stunden herausrollt. Der
/// Absturzbericht selbst enthält nur den Aufrufstapel, nicht den Grund.
///
/// Diese Umleitung kostet nichts und macht den nächsten Absturz auswertbar.
enum CrashLog {
    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Logs", directoryHint: .isDirectory)
            .appending(path: "FotonKanban.log", directoryHint: .notDirectory)
    }

    /// Hängt an die bestehende Datei an, damit ein vorheriger Absturz nicht
    /// vom nächsten Start überschrieben wird. Bei Überlänge wird gekürzt.
    static func start() {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        trimIfTooLarge(url)

        guard freopen(url.path(percentEncoded: false), "a", stderr) != nil else { return }
        setvbuf(stderr, nil, _IOLBF, 0)

        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\n=== Start \(stamp) ===\n".utf8))

        NSSetUncaughtExceptionHandler { exception in
            let text = """
                *** Unbehandelte Ausnahme: \(exception.name.rawValue)
                Grund: \(exception.reason ?? "—")
                \(exception.callStackSymbols.joined(separator: "\n"))

                """
            FileHandle.standardError.write(Data(text.utf8))
        }
    }

    private static let maximumBytes = 512 * 1024

    private static func trimIfTooLarge(_ url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > maximumBytes,
            let data = try? Data(contentsOf: url)
        else { return }
        try? data.suffix(maximumBytes / 2).write(to: url)
    }
}
