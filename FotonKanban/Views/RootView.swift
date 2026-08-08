import FotonKanbanCore
import SwiftUI

struct RootView: View {
    @Environment(BoardModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Group {
            if model.folderURL == nil {
                WelcomeView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
                } detail: {
                    detail
                }
                .inspector(isPresented: .constant(model.selectedTrack != nil)) {
                    if let track = model.selectedTrack {
                        TrackInspector(track: track)
                            .inspectorColumnWidth(min: 250, ideal: 300, max: 460)
                    }
                }
            }
        }
        .alert(
            "Fehler",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection {
        case .year:
            YearPlanView()
        default:
            BoardView()
        }
    }
}

struct SidebarView: View {
    @Environment(BoardModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.sidebarSelection) {
            Section("Ansicht") {
                Label("Board", systemImage: "square.grid.3x3")
                    .tag(SidebarItem.allTracks)
                Label("Jahresplanung", systemImage: "calendar")
                    .tag(SidebarItem.year)
            }

            Section("Releases") {
                Label {
                    HStack {
                        Text("Backlog")
                        Spacer()
                        count(model.repository.backlog.count)
                    }
                } icon: {
                    Image(systemName: "tray")
                }
                .tag(SidebarItem.backlog)

                ForEach(model.repository.scheduledReleases) { release in
                    Label {
                        HStack {
                            Text(release.title)
                            Spacer()
                            count(model.repository.tracks(inRelease: release.id).count)
                        }
                    } icon: {
                        Image(systemName: icon(for: release.state))
                    }
                    .tag(SidebarItem.release(release.id))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let url = model.folderURL {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .help(url.path(percentEncoded: false))
            }
        }
    }

    private func count(_ value: Int) -> some View {
        Text(value, format: .number)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private func icon(for state: ReleaseState) -> String {
        switch state {
        case .planned: "circle.dashed"
        case .inProgress: "circle.lefthalf.filled"
        case .released: "checkmark.circle"
        }
    }
}

struct WelcomeView: View {
    @Environment(BoardModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            Text("Foton Kanban")
                .font(.title2)

            Text("Wähle einen Ordner für dein Board. Tracks und Releases liegen darin als Markdown-Dateien.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Button("Ordner wählen…") {
                if let url = FolderPicker.choose() { model.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
