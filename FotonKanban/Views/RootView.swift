import AppKit
import FotonKanbanCore
import SwiftUI

struct RootView: View {
    @Environment(BoardModel.self) private var model

    /// Breite des Seitenpanels. Eine Einstellung des Arbeitsplatzes, kein
    /// Boardinhalt — sie hängt am Bildschirm und gehört deshalb nicht in die
    /// Dateien, die zwischen den Rechnern synchronisiert werden.
    @AppStorage("inspectorWidth") private var inspectorWidth = 320.0
    /// Breite zu Beginn der Ziehbewegung; `translation` zählt von dort.
    @State private var widthAtDragStart: Double?

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
                    // Eigenes Seitenpanel statt `.inspector`: Unter macOS 27
                    // invalidiert dessen Hostansicht ihr Layout während des
                    // Constraint-Durchlaufs und löst damit eine Endlosschleife
                    // aus, die das Fenster mit einer Ausnahme beendet.
                    // Nachgewiesen durch Ein- und Ausbauen: mit `.inspector`
                    // drei von drei Läufen abgestürzt, ohne null von drei.
                    HStack(spacing: 0) {
                        detail
                        if let track = model.selectedTrack {
                            resizeHandle
                            TrackInspector(track: track)
                                .frame(width: inspectorWidth)
                        } else if model.selectedTrackIDs.count > 1 {
                            resizeHandle
                            MultiSelectionPanel()
                                .frame(width: inspectorWidth)
                        }
                    }
                }            }
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

    /// Die Trennlinie mit einem breiteren, unsichtbaren Greifbereich — eine
    /// Linie von einem Punkt Breite trifft man sonst kaum.
    private var resizeHandle: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .contentShape(.rect)
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = widthAtDragStart ?? inspectorWidth
                                widthAtDragStart = start
                                // Das Panel sitzt rechts: Ziehen nach links
                                // vergrößert es.
                                inspectorWidth = (start - value.translation.width)
                                    .clamped(to: 260...620)
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
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

    /// Zustand des Archiv-Abschnitts. Gehört zum Arbeitsplatz, nicht zum
    /// Board — sonst wanderte er über die Cloud auf die anderen Rechner.
    @AppStorage("showsReleasedSection") private var showsReleasedSection = false

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

                ForEach(model.repository.activeReleases) { release in
                    row(for: release)
                }
            }

            // Das Archiv wächst mit jeder EP und wird selten gebraucht —
            // deshalb zugeklappt und unten.
            if !model.repository.releasedReleases.isEmpty {
                Section(isExpanded: $showsReleasedSection) {
                    ForEach(model.repository.releasedReleases) { release in
                        row(for: release)
                    }
                } header: {
                    HStack {
                        Text("Veröffentlicht")
                        Spacer()
                        count(model.repository.releasedReleases.count)
                    }
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

    @ViewBuilder
    private func row(for release: Release) -> some View {
        let isReleased = release.state == .released
        Label {
            HStack {
                Text(release.title)
                Spacer()
                // Bei einer erschienenen EP sagt die Trackzahl nichts mehr —
                // wann sie herauskam, schon. Ohne Termin bleibt die Zahl.
                if isReleased, let target = release.target {
                    Text(Self.monthYear.string(from: target))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    count(model.repository.tracks(inRelease: release.id).count)
                }
            }
        } icon: {
            Image(systemName: icon(for: release.state))
        }
        .foregroundStyle(isReleased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .tag(SidebarItem.release(release.id))
        .contextMenu {
            Toggle("Veröffentlicht", isOn: Binding(
                get: { isReleased },
                set: { model.setReleased($0, for: release.id) }
            ))
        }
    }

    /// Fest deutsch, wie die Monatsnamen in der Jahresplanung — die übrige
    /// Beschriftung ist es auch, selbst wenn das System auf Englisch läuft.
    private static let monthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return formatter
    }()

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


extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
