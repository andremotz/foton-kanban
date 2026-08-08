import FotonKanbanCore
import SwiftUI

/// Übergabeformat für Drag and Drop. Das Präfix verhindert, dass beliebiger
/// Text von außerhalb als Track interpretiert wird.
enum TrackDrag {
    private static let prefix = "foton-track:"

    static func payload(_ id: String) -> String { prefix + id }

    static func id(from items: [String]) -> String? {
        items.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
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
                        TrackCardView(track: track, status: status)
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
        .dropDestination(for: String.self) { items, _ in
            guard let id = TrackDrag.id(from: items) else { return false }
            model.move(trackID: id, to: status)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

private struct TrackCardView: View {
    @Environment(BoardModel.self) private var model
    let track: Track
    let status: Status

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(track.title)
                .font(.callout)
                .lineLimit(2)

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
                    model.selectedTrackID == track.id ? Color.accentColor : Color.primary.opacity(0.12)
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
        .onTapGesture { model.selectedTrackID = track.id }
        .draggable(TrackDrag.payload(track.id))
        .dropDestination(for: String.self) { items, _ in
            guard let id = TrackDrag.id(from: items), id != track.id else { return false }
            model.move(trackID: id, to: status, before: track.id)
            return true
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
            Button("Öffnen") { model.selectedTrackID = track.id }
            Divider()
            Button("Löschen", role: .destructive) { model.delete(trackID: track.id) }
        }
    }
}
