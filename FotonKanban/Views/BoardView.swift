import AppKit
import FotonKanbanCore
import SwiftUI
import UniformTypeIdentifiers

/// Drag and Drop auf dem Board.
///
/// Auf einer Karte landen zwei verschiedene Dinge: eine andere Karte beim
/// Umsortieren und eine Audiodatei aus dem Finder. SwiftUI erwartet pro
/// Ansicht einen Zieltyp, deshalb laufen beide über **einen** Handler, der
/// nach Anbietertyp verzweigt.
enum TrackDrag {
    private static let prefix = "foton-track:"

    /// Dateien zuerst: Ein Finder-Objekt bietet oft zusätzlich eine
    /// Textdarstellung an, die sonst fälschlich als Karte gelesen würde.
    static let acceptedTypes: [UTType] = [.fileURL, .utf8PlainText, .text]

    /// Mehrere IDs durch Komma getrennt: Wer eine Karte aus einer Auswahl
    /// zieht, zieht die ganze Auswahl mit.
    static func payload(_ ids: [String]) -> String { prefix + ids.joined(separator: ",") }

    static func ids(from text: String) -> [String] {
        guard text.hasPrefix(prefix) else { return [] }
        return text.dropFirst(prefix.count).split(separator: ",").map(String.init)
    }

    /// Verteilt die abgelegten Objekte. `audio` bleibt weg, wo Dateien nichts
    /// zu suchen haben — etwa auf einer Spalte ohne Zielkarte.
    @MainActor
    static func handle(
        _ providers: [NSItemProvider],
        move: @escaping @MainActor ([String]) -> Void,
        audio: (@MainActor (URL) -> Void)? = nil
    ) -> Bool {
        if let audio,
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            })
        {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url,
                    BounceIndex.audioExtensions.contains(url.pathExtension.lowercased())
                else { return }
                Task { @MainActor in audio(url) }
            }
            return true
        }

        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) })
        else { return false }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text else { return }
            let moved = ids(from: text)
            guard !moved.isEmpty else { return }
            Task { @MainActor in move(moved) }
        }
        return true
    }
}

/// Vier Spalten für die vier Zustände. Innerhalb einer Spalte steht oben, was
/// wichtiger ist — die vertikale Position *ist* die Priorität.
struct BoardView: View {
    @Environment(BoardModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(alignment: .top, spacing: 12) {
            ForEach(Status.allCases, id: \.self) { status in
                ColumnView(status: status)
            }
        }
        .padding(16)
        .navigationTitle(title)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Tracks durchsuchen")
        .toolbar {
            // Nur in der Gesamtansicht wird etwas ausgeblendet, und nur wenn
            // es überhaupt ein veröffentlichtes Release gibt.
            if model.sidebarSelection == .allTracks,
                !model.repository.releasedReleases.isEmpty {
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: Binding(
                        get: { model.showsReleasedTracks },
                        set: { model.showsReleasedTracks = $0 }
                    )) {
                        Label(
                            "Veröffentlichte einblenden",
                            systemImage: model.showsReleasedTracks ? "eye" : "eye.slash"
                        )
                    }
                    .help(
                        model.showsReleasedTracks
                            ? "Tracks veröffentlichter Releases ausblenden"
                            : "Tracks veröffentlichter Releases einblenden"
                    )
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.createTrack(release: currentRelease)
                } label: {
                    Label("Neuer Track", systemImage: "plus")
                }
                .help("Neuen Track in der open-Spalte anlegen")
            }
        }
    }

    private var title: String {
        switch model.sidebarSelection {
        case .backlog: "Backlog"
        case .release(let id): model.repository.release(id)?.title ?? "Release"
        default: "Board"
        }
    }

    /// Ein Track, der aus einer Release-Ansicht heraus angelegt wird, gehört
    /// gleich zu diesem Release.
    private var currentRelease: String? {
        if case .release(let id) = model.sidebarSelection { return id }
        return nil
    }
}

private struct ColumnView: View {
    @Environment(BoardModel.self) private var model
    let status: Status

    @State private var isTargeted = false

    var body: some View {
        let tracks = model.visibleTracks(in: status)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(status.title)
                    .font(.subheadline)
                Spacer()
                Text(tracks.count, format: .number)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tracks) { track in
                        TrackCardView(track: track, status: status, columnIDs: tracks.map(\.id))
                    }
                    // Ablagefläche unterhalb der letzten Karte, damit ein Track
                    // ans Ende der Spalte gezogen werden kann.
                    Color.clear.frame(height: 40)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
            }
            .frame(maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.primary.opacity(0.06))
            }
        }
        .frame(minWidth: 170, maxWidth: .infinity)
        .onDrop(of: TrackDrag.acceptedTypes, isTargeted: $isTargeted) { providers in
            TrackDrag.handle(providers) { ids in
                model.move(trackIDs: ids, to: status)
            }
        }
    }
}

private struct TrackCardView: View {
    @Environment(BoardModel.self) private var model
    let track: Track
    let status: Status
    /// Die Karten der eigenen Spalte in Anzeigereihenfolge — Grundlage für die
    /// Auswahl mit gedrückter Umschalttaste.
    let columnIDs: [String]

    /// Gehört die Karte zur Auswahl, gelten Ziehen und Kontextmenü für alle.
    private var affectsSelection: Bool {
        model.selectedTrackIDs.count > 1 && model.selectedTrackIDs.contains(track.id)
    }

    private var draggedIDs: [String] {
        affectsSelection ? model.selectedTracks.map(\.id) : [track.id]
    }

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Arbeitsname und Veröffentlichungsname in einem Absatz, damit
            // sie zusammen umbrechen statt sich zwei Zeilen zu teilen.
            Group {
                if let released = track.releaseTitle, !released.isEmpty {
                    Text(track.title)
                        + Text("  ")
                        + Text(released).foregroundStyle(Color.accentColor)
                } else {
                    Text(track.title)
                }
            }
            .font(.callout)
            .lineLimit(3)

            HStack(spacing: 6) {
                Text(track.phase.title)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.07))
                    }

                if let badge = track.checklistBadge {
                    Label(badge, systemImage: "checklist")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }

                if track.reviewRounds > 1 {
                    Text("Runde \(track.reviewRounds)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                // Ein Klick genügt zum Reinhören: die neueste Fassung im
                // Standardprogramm.
                if let bounce = model.bounces(for: track).first {
                    Button {
                        NSWorkspace.shared.open(bounce.url)
                    } label: {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Anhören: \(bounce.fileName)")
                }
            }

            HStack(spacing: 6) {
                if let release = model.repository.release(track.release) {
                    Text(release.title)
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("Backlog")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !track.tags.isEmpty {
                    Text(track.tags.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    model.selectedTrackIDs.contains(track.id)
                        ? Color.accentColor : Color.primary.opacity(0.12)
                )
        }
        .overlay(alignment: .top) {
            // Einfügemarke: hier abgelegte Karten landen davor, bekommen also
            // die höhere Priorität.
            if isTargeted {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .offset(y: -5)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            // SwiftUI reicht die Zusatztasten beim Tippen nicht mit, deshalb
            // der Blick auf den aktuellen Tastaturzustand.
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) {
                model.toggleSelection(track.id)
            } else if flags.contains(.shift) {
                model.extendSelection(to: track.id, within: columnIDs)
            } else {
                model.select(track.id)
            }
        }
        .draggable(TrackDrag.payload(draggedIDs))
        .onDrop(of: TrackDrag.acceptedTypes, isTargeted: $isTargeted) { providers in
            TrackDrag.handle(providers) { ids in
                let others = ids.filter { $0 != track.id }
                guard !others.isEmpty else { return }
                model.move(trackIDs: others, to: status, before: track.id)
            } audio: { url in
                model.setAudio(url, for: track.id)
            }
        }
        .contextMenu {
            if affectsSelection {
                Section("\(model.selectedTrackIDs.count) Tracks") {
                    Button("In den Backlog") { model.moveSelectionToBacklog() }
                    Menu("Release zuweisen") {
                        ForEach(model.repository.activeReleases) { release in
                            Button(release.title) { model.assignSelection(to: release.id) }
                        }
                    }
                    Button("Löschen", role: .destructive) { model.deleteSelection() }
                }
                Divider()
            }
            Button("Öffnen") { model.select(track.id) }
            if let bounce = model.bounces(for: track).first {
                Button("Bounce anhören") { NSWorkspace.shared.open(bounce.url) }
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([bounce.url])
                }
            }
            Divider()
            Button("Löschen", role: .destructive) { model.delete(trackID: track.id) }
        }
    }
}
