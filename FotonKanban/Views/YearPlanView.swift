import FotonKanbanCore
import SwiftUI

/// Die Jahresübersicht: zwölf Monate untereinander, Releases auf ihrem Termin.
/// Der Abstand zum vorherigen Release steht dazwischen — damit lässt sich eine
/// gleichmäßige Kadenz einplanen, ohne irgendwo nachzurechnen.
struct YearPlanView: View {
    @Environment(BoardModel.self) private var model
    @State private var year = Calendar.current.component(.year, from: Date())

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(1...12, id: \.self) { month in
                    MonthRow(year: year, month: month, releases: releases(in: month), gaps: gaps)
                }
            }
            .padding(20)
        }
        .navigationTitle("Jahresplanung \(String(year))")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    year -= 1
                } label: {
                    Label("Vorheriges Jahr", systemImage: "chevron.left")
                }

                Text(String(year))
                    .monospacedDigit()

                Button {
                    year += 1
                } label: {
                    Label("Nächstes Jahr", systemImage: "chevron.right")
                }
            }
        }
    }

    private var releasesThisYear: [Release] {
        model.repository.scheduledReleases.filter { release in
            guard let target = release.target else { return false }
            return calendar.component(.year, from: target) == year
        }
    }

    private func releases(in month: Int) -> [Release] {
        releasesThisYear.filter { release in
            guard let target = release.target else { return false }
            return calendar.component(.month, from: target) == month
        }
    }

    /// Abstand in Wochen zum jeweils vorherigen Release, nach Release-ID.
    private var gaps: [String: Int] {
        var result: [String: Int] = [:]
        let sorted = releasesThisYear
        for (index, release) in sorted.enumerated() where index > 0 {
            guard let previous = sorted[index - 1].target, let current = release.target else { continue }
            let days = calendar.dateComponents([.day], from: previous, to: current).day ?? 0
            result[release.id] = Int((Double(days) / 7).rounded())
        }
        return result
    }
}

private struct MonthRow: View {
    @Environment(BoardModel.self) private var model
    let year: Int
    let month: Int
    let releases: [Release]
    let gaps: [String: Int]

    /// Fest deutsch, damit die Monatsnamen zur übrigen Beschriftung passen —
    /// auch wenn das System auf einer anderen Sprache läuft.
    private static let monthSymbols: [String] = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.monthSymbols
    }()

    private var monthName: String { Self.monthSymbols[month - 1] }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(monthName)
                .font(.subheadline)
                .foregroundStyle(releases.isEmpty ? .secondary : .primary)
                .frame(width: 92, alignment: .leading)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(releases) { release in
                    if let weeks = gaps[release.id] {
                        GapLabel(weeks: weeks, target: model.repository.config.releaseCadenceWeeks)
                    }
                    ReleaseCard(release: release)
                }

                Button {
                    addRelease()
                } label: {
                    Label("Release", systemImage: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Release Mitte \(monthName) einplanen")
            }
            .frame(maxWidth: 520, alignment: .leading)

            Spacer()
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func addRelease() {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 15
        guard let date = Calendar.current.date(from: components) else { return }
        model.createRelease(target: date)
    }
}

private struct GapLabel: View {
    let weeks: Int
    let target: Int

    private var isOffTarget: Bool { abs(weeks - target) > 1 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down")
            Text("\(weeks) Wochen Abstand")
            if isOffTarget {
                Text("· Ziel \(target)")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
    }
}

private struct ReleaseCard: View {
    @Environment(BoardModel.self) private var model
    let release: Release

    @State private var title: String
    @State private var showsDeleteConfirmation = false
    @FocusState private var isTitleFocused: Bool

    init(release: Release) {
        self.release = release
        _title = State(initialValue: release.title)
    }

    private var tracks: [Track] { model.repository.tracks(inRelease: release.id) }
    private var finished: Int { tracks.count(where: \.isFinished) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Titel", text: $title)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($isTitleFocused)
                    .onSubmit(commitTitle)
                    // Nicht nur bei Enter sichern: wer den Namen tippt und
                    // dann wegklickt, hätte ihn sonst verloren.
                    .onChange(of: isTitleFocused) { _, focused in
                        if !focused { commitTitle() }
                    }

                Spacer()

                Menu {
                    Button("Tracks anzeigen") {
                        model.sidebarSelection = .release(release.id)
                    }
                    Divider()
                    Button("Release löschen", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: 12) {
                DatePicker(
                    "Termin",
                    selection: Binding(
                        get: { release.target ?? Date() },
                        set: { newValue in update { $0.target = newValue } }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()

                Picker("Status", selection: Binding(
                    get: { release.state },
                    set: { newValue in update { $0.state = newValue } }
                )) {
                    ForEach(ReleaseState.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()

                Text("\(finished)/\(tracks.count) fertig")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .onChange(of: release.id) { title = release.title }
        .confirmationDialog(
            "Release \(release.title) löschen?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) { model.delete(releaseID: release.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die \(tracks.count) zugeordneten Tracks wandern in den Backlog.")
        }
    }

    private func commitTitle() {
        guard title != release.title else { return }
        update { $0.title = title }
    }

    private func update(_ change: (inout Release) -> Void) {
        var copy = release
        change(&copy)
        copy.updated = Date()
        model.update(copy)
    }
}
