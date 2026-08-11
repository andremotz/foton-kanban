import AppKit
import FotonKanbanCore
import SwiftUI

struct TrackInspector: View {
    @Environment(BoardModel.self) private var model
    /// Der Stand aus dem Modell — maßgeblich für Phase, Spalte und Release.
    let track: Track

    /// Lokaler Entwurf für Textfelder und Haken, damit Tippen nicht bei jedem
    /// Zeichen eine Datei schreibt. Wird verzögert zurückgeschrieben.
    @State private var draft: Track
    @State private var tagText: String

    init(track: Track) {
        self.track = track
        _draft = State(initialValue: track)
        _tagText = State(initialValue: track.tags.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section {
                TextField("Titel", text: $draft.title, axis: .vertical)
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .labelsHidden()

                Picker("Phase", selection: phaseBinding) {
                    ForEach(Phase.allCases, id: \.self) { Text($0.title).tag($0) }
                }

                Picker("Spalte", selection: statusBinding) {
                    ForEach(Status.allCases, id: \.self) { Text($0.title).tag($0) }
                }

                Picker("Release", selection: releaseBinding) {
                    Text("Backlog").tag(String?.none)
                    ForEach(model.repository.scheduledReleases) { release in
                        Text(release.title).tag(String?.some(release.id))
                    }
                }

                TextField("Tags", text: $tagText, prompt: Text("synth, dark"))
                    .onSubmit(commitTags)
            }

            Section("Notizen") {
                TextEditor(text: $draft.notes)
                    .font(.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
            }

            if !draft.checks.isEmpty {
                Section {
                    ForEach($draft.checks) { $check in
                        HStack(spacing: 6) {
                            Toggle(isOn: $check.isChecked) {
                                // Breit genug für "Bose Lautsprecher" — sonst
                                // steht auf halber Liste nur "Bose Lauts…".
                                Text(check.situation)
                                    .frame(width: 134, alignment: .leading)
                                    .lineLimit(1)
                            }
                            .toggleStyle(.checkbox)

                            TextField("Notiz", text: $check.note)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .labelsHidden()
                                .frame(minWidth: 40)
                        }
                    }
                } header: {
                    HStack {
                        Text("Abhören")
                        Spacer()
                        Button("Zurücksetzen") { model.resetChecks(for: track.id) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Nimmt alle Haken zurück, die Notizen bleiben stehen")
                    }
                }
            }

            let bounces = model.bounces(for: track)
            if !bounces.isEmpty {
                Section("Bounce") {
                    BounceRow(bounce: bounces[0], isCurrent: true)

                    if bounces.count > 1 {
                        DisclosureGroup("Ältere Fassungen (\(bounces.count - 1))") {
                            ForEach(bounces.dropFirst()) { bounce in
                                BounceRow(bounce: bounce, isCurrent: false)
                            }
                        }
                        .font(.caption)
                    }

                    if track.audio != nil {
                        HStack {
                            Label("Von Hand zugewiesen", systemImage: "pin")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Zuordnung lösen") { model.clearAudio(for: track.id) }
                                .buttonStyle(.link)
                                .font(.caption)
                                .help("Danach sucht die App die aktuelle Fassung wieder selbst")
                        }
                    }
                }
            }

            Section {
                if track.reviewRounds > 0 {
                    LabeledContent("Review-Runden", value: "\(track.reviewRounds)")
                }
                LabeledContent(
                    "Geändert",
                    value: draft.updated.formatted(date: .abbreviated, time: .shortened)
                )
                Button("Track löschen", role: .destructive) {
                    model.delete(trackID: track.id)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: track.id) {
            draft = track
            tagText = track.tags.joined(separator: ", ")
        }
        // Setzt der Nutzer die Checkliste zurück, kommt die Änderung aus dem
        // Modell und muss in den Entwurf übernommen werden.
        .onChange(of: track.checks) { _, new in
            if new != draft.checks { draft.checks = new }
        }
        .onChange(of: draft) { _, new in
            model.scheduleSave(new)
        }
        .onDisappear(perform: commitTags)
    }

    // Phase, Spalte und Release laufen über das Modell statt über den Entwurf:
    // dort hängen Phasenwechsel, Rundenzählung und Priorität dran.
    private var phaseBinding: Binding<Phase> {
        Binding(
            get: { track.phase },
            set: { model.setPhase($0, for: track.id) }
        )
    }

    private var statusBinding: Binding<Status> {
        Binding(
            get: { track.status },
            set: { model.move(trackID: track.id, to: $0) }
        )
    }

    private var releaseBinding: Binding<String?> {
        Binding(
            get: { track.release },
            set: { model.setRelease($0, for: track.id) }
        )
    }

    private func commitTags() {
        let tags = tagText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard tags != draft.tags else { return }
        draft.tags = tags
    }
}

/// Eine Fassung: Dateiname, Datum und die beiden Wege dorthin.
private struct BounceRow: View {
    let bounce: Bounce
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.open(bounce.url)
            } label: {
                Image(systemName: isCurrent ? "play.circle.fill" : "play.circle")
                    .font(isCurrent ? .title3 : .body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Im Standardprogramm öffnen")

            VStack(alignment: .leading, spacing: 1) {
                Text(bounce.fileName)
                    .font(isCurrent ? .callout : .caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if bounce.date > .distantPast {
                        Text(bounce.date.formatted(date: .abbreviated, time: .omitted))
                    }
                    if bounce.isMaster { Text("Master") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([bounce.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Im Finder zeigen")
        }
        .padding(.vertical, 1)
    }
}
