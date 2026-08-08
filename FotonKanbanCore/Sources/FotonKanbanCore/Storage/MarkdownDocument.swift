import Foundation

/// Frontmatter plus `## `-Abschnitte. Trennt das Dateiformat von der
/// Bedeutung der einzelnen Felder.
struct MarkdownDocument {
    var frontmatter = Frontmatter()
    /// In Dateireihenfolge. Ein Abschnitt mit leerer Überschrift steht für
    /// Text vor der ersten Überschrift.
    var sections: [BodySection] = []

    subscript(section heading: String) -> String? {
        sections.first { $0.heading.caseInsensitiveCompare(heading) == .orderedSame }?.content
    }

    /// Alle Abschnitte außer den übergebenen — das, was die App nicht kennt.
    func sections(except known: [String]) -> [BodySection] {
        sections.filter { section in
            !known.contains { $0.caseInsensitiveCompare(section.heading) == .orderedSame }
        }
    }

    static func parse(_ text: String) -> MarkdownDocument? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()

        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        var document = MarkdownDocument()
        document.frontmatter = Frontmatter.parse(lines[..<end].joined(separator: "\n"))
        document.sections = parseSections(Array(lines[(end + 1)...]))
        return document
    }

    private static func parseSections(_ lines: [String]) -> [BodySection] {
        var sections: [BodySection] = []
        var heading = ""
        var buffer: [String] = []

        func flush() {
            let content = buffer.joined(separator: "\n").trimmedBlankLines()
            guard !heading.isEmpty || !content.isEmpty else { return }
            sections.append(BodySection(heading: heading, content: content))
        }

        for line in lines {
            if line.hasPrefix("## "), !line.hasPrefix("### ") {
                flush()
                heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                buffer = []
            } else {
                buffer.append(line)
            }
        }
        flush()
        return sections
    }

    func serialized() -> String {
        var parts = ["---\n\(frontmatter.serialized())\n---"]
        for section in sections {
            let content = section.content.trimmedBlankLines()
            if section.heading.isEmpty {
                guard !content.isEmpty else { continue }
                parts.append(content)
            } else {
                parts.append(content.isEmpty ? "## \(section.heading)" : "## \(section.heading)\n\n\(content)")
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
}

extension String {
    /// Entfernt führende und abschließende Leerzeilen, lässt die Einrückung
    /// innerhalb des Textes aber unangetastet.
    func trimmedBlankLines() -> String {
        var lines = components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
