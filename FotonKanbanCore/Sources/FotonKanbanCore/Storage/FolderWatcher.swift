import Foundation

/// Meldet Änderungen am Board-Ordner, die nicht von dieser App kommen —
/// ein `git pull`, ein zweiter Mac, ein Texteditor.
///
/// FSEvents statt eines Datei-Deskriptors, weil auch Änderungen *innerhalb*
/// bestehender Dateien erkannt werden müssen, nicht nur neue und gelöschte.
public final class FolderWatcher {
    private let url: URL
    private let latency: TimeInterval
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "de.fotonkanban.folderwatcher")
    private var stream: FSEventStreamRef?

    /// - Parameter latency: Sammelzeit, in der FSEvents mehrere Änderungen zu
    ///   einer Meldung zusammenfasst. Ein Git-Pull schreibt viele Dateien auf
    ///   einmal — die sollen ein Neuladen auslösen, nicht dreißig.
    public init(url: URL, latency: TimeInterval = 0.4, handler: @escaping @Sendable () -> Void) {
        self.url = url
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }

        let box = Unmanaged.passRetained(HandlerBox(handler)).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: box,
            retain: nil,
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<HandlerBox>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<HandlerBox>.fromOpaque(info).takeUnretainedValue().handler()
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path(percentEncoded: false)] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
        ) else {
            Unmanaged<HandlerBox>.fromOpaque(box).release()
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Trägt den Swift-Closure durch den C-Callback von FSEvents.
private final class HandlerBox: Sendable {
    let handler: @Sendable () -> Void

    init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }
}
