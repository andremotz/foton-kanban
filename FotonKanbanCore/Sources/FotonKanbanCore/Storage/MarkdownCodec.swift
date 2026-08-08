import Foundation

public enum MarkdownCodecError: Error, Equatable {
    /// Die Datei hat keinen Frontmatter-Block und gehört damit nicht zum Board.
    case notAKanbanFile
}

/// Übersetzt zwischen Modell und Markdown. Leitgedanke: Alles, was diese App
/// nicht versteht, überlebt den Roundtrip unverändert.
public enum MarkdownCodec {
    static let notesHeading = "Notizen"
    static let checklistHeading = "Checkliste"
    private static let separator = " — "

    // MARK: - Track

    private static let trackKeys: Set<String> = [
        "id", "title", "phase", "status", "release", "order", "review-rounds",
        "created", "updated", "tags",
    ]

    public static func decodeTrack(_ markdown: String, fallbackID: String) throws -> Track {
        guard let document = MarkdownDocument.parse(markdown) else {
            throw MarkdownCodecError.notAKanbanFile
        }
        let front = document.frontmatter
        let id = front.nonEmptyString("id") ?? fallbackID
        let phase = front.nonEmptyString("phase").flatMap(Phase.init(rawValue:)) ?? .jamSession
        let status = front.nonEmptyString("status").flatMap(Status.init(rawValue:)) ?? .open
        let created = front.timestamp("created") ?? Date()
        let updated = front.timestamp("updated") ?? created

        return Track(
            id: id,
            title: front.nonEmptyString("title") ?? id,
            phase: phase,
            status: status,
            release: front.nonEmptyString("release"),
            order: front["order"]?.intValue ?? Ordering.step,
            reviewRounds: front["review-rounds"]?.intValue ?? 0,
            created: created,
            updated: updated,
            tags: front["tags"]?.listValue ?? [],
            notes: document[section: notesHeading] ?? "",
            checks: decodeChecks(document[section: checklistHeading] ?? ""),
            unknownFrontmatter: front.except(trackKeys),
            extraSections: document.sections(except: [notesHeading, checklistHeading])
        )
    }

    public static func encode(_ track: Track) -> String {
        var front = Frontmatter()
        front.set("id", track.id)
        front.set("title", track.title)
        front.set("phase", track.phase.rawValue)
        front.set("status", track.status.rawValue)
        front.set("release", track.release)
        front.set("order", track.order)
        if track.reviewRounds > 0 { front.set("review-rounds", track.reviewRounds) }
        front.set("created", DateFormatting.timestamp(track.created))
        front.set("updated", DateFormatting.timestamp(track.updated))
        if !track.tags.isEmpty { front["tags"] = .list(track.tags) }
        front.merge(unknown: track.unknownFrontmatter)

        var document = MarkdownDocument()
        document.frontmatter = front
        document.sections = [BodySection(heading: notesHeading, content: track.notes)]
        if !track.checks.isEmpty {
            document.sections.append(
                BodySection(heading: checklistHeading, content: encodeChecks(track.checks))
            )
        }
        document.sections.append(contentsOf: track.extraSections)
        return document.serialized()
    }

    // MARK: - Release

    private static let releaseKeys: Set<String> = [
        "id", "title", "target", "state", "created", "updated",
    ]

    public static func decodeRelease(_ markdown: String, fallbackID: String) throws -> Release {
        guard let document = MarkdownDocument.parse(markdown) else {
            throw MarkdownCodecError.notAKanbanFile
        }
        let front = document.frontmatter
        let id = front.nonEmptyString("id") ?? fallbackID
        let state = front.nonEmptyString("state").flatMap(ReleaseState.init(rawValue:)) ?? .planned
        let created = front.timestamp("created") ?? Date()
        let updated = front.timestamp("updated") ?? created

        return Release(
            id: id,
            title: front.nonEmptyString("title") ?? id,
            target: front.nonEmptyString("target").flatMap(DateFormatting.day(from:)),
            state: state,
            created: created,
            updated: updated,
            notes: document[section: notesHeading] ?? "",
            unknownFrontmatter: front.except(releaseKeys),
            extraSections: document.sections(except: [notesHeading])
        )
    }

    public static func encode(_ release: Release) -> String {
        var front = Frontmatter()
        front.set("id", release.id)
        front.set("title", release.title)
        front.set("target", release.target.map(DateFormatting.day))
        front.set("state", release.state.rawValue)
        front.set("created", DateFormatting.timestamp(release.created))
        front.set("updated", DateFormatting.timestamp(release.updated))
        front.merge(unknown: release.unknownFrontmatter)

        var document = MarkdownDocument()
        document.frontmatter = front
        document.sections = [BodySection(heading: notesHeading, content: release.notes)]
        document.sections.append(contentsOf: release.extraSections)
        return document.serialized()
    }

    // MARK: - Konfiguration

    /// Auch die Einstellungen sind eine Markdown-Datei — ein Format im Repo
    /// statt zwei.
    public static func decodeConfig(_ markdown: String) -> Config {
        guard let front = MarkdownDocument.parse(markdown)?.frontmatter else { return .default }
        let situations = front["listening-situations"]?.listValue?.filter { !$0.isEmpty }
        let cadence = front["release-cadence-weeks"]?.intValue
        return Config(
            listeningSituations: situations.flatMap { $0.isEmpty ? nil : $0 }
                ?? Config.default.listeningSituations,
            releaseCadenceWeeks: cadence.flatMap { $0 > 0 ? $0 : nil }
                ?? Config.default.releaseCadenceWeeks
        )
    }

    public static func encode(_ config: Config) -> String {
        var front = Frontmatter()
        front["listening-situations"] = .list(config.listeningSituations)
        front.set("release-cadence-weeks", config.releaseCadenceWeeks)

        var document = MarkdownDocument()
        document.frontmatter = front
        document.sections = [
            BodySection(
                heading: notesHeading,
                content: "Diese Abhörsituationen bilden die Checkliste jedes Tracks."
            )
        ]
        return document.serialized()
    }

    // MARK: - Checkliste

    static func encodeChecks(_ checks: [ListeningCheck]) -> String {
        checks.map { check in
            let mark = check.isChecked ? "x" : " "
            let note = check.note.isEmpty ? "" : "\(separator)\(check.note)"
            return "- [\(mark)] \(check.situation)\(note)"
        }
        .joined(separator: "\n")
    }

    /// Zeilen, die keine Checkbox sind, werden übergangen — so stört eine
    /// dazwischengeschriebene Zeile den Import nicht.
    static func decodeChecks(_ text: String) -> [ListeningCheck] {
        text.components(separatedBy: "\n").compactMap {
            decodeCheck($0.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func decodeCheck(_ line: String) -> ListeningCheck? {
        let marks = ["- [x] ": true, "- [X] ": true, "- [ ] ": false]
        guard let match = marks.first(where: { line.hasPrefix($0.key) }) else { return nil }
        let rest = String(line.dropFirst(match.key.count))

        guard let range = rest.range(of: separator) else {
            return ListeningCheck(
                situation: rest.trimmingCharacters(in: .whitespaces), isChecked: match.value
            )
        }
        return ListeningCheck(
            situation: String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
            isChecked: match.value,
            note: String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        )
    }
}
