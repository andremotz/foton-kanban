import Foundation

/// Ein Frontmatter-Wert in der Form, in der er in der Datei steht. Nur so viel
/// YAML, wie dieses Format braucht — dafür ohne Abhängigkeiten.
public enum FrontmatterValue: Hashable, Codable, Sendable {
    case scalar(String)
    case list([String])

    public var stringValue: String? {
        if case .scalar(let value) = self { return value }
        return nil
    }

    public var listValue: [String]? {
        switch self {
        case .list(let values): values
        case .scalar(let value): value.isEmpty ? [] : [value]
        }
    }

    public var intValue: Int? {
        guard case .scalar(let value) = self else { return nil }
        return Int(value)
    }
}

/// Ein `## `-Abschnitt des Bodys. Abschnitte, die diese App nicht kennt,
/// werden hierüber unverändert durch den Roundtrip getragen.
public struct BodySection: Hashable, Codable, Sendable {
    /// Überschrift ohne `## `. Leer für Text vor der ersten Überschrift.
    public var heading: String
    public var content: String

    public init(heading: String, content: String) {
        self.heading = heading
        self.content = content
    }
}

/// Geordnete Frontmatter-Schlüssel. Die Reihenfolge beim Schreiben ist fest,
/// damit Git-Diffs nur echte Änderungen zeigen.
struct Frontmatter {
    private(set) var keys: [String] = []
    private var values: [String: FrontmatterValue] = [:]

    subscript(key: String) -> FrontmatterValue? {
        get { values[key] }
        set {
            if let newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = newValue
            } else {
                values[key] = nil
                keys.removeAll { $0 == key }
            }
        }
    }

    mutating func set(_ key: String, _ value: String?) {
        guard let value else { return }
        self[key] = .scalar(value)
    }

    mutating func set(_ key: String, _ value: Int) {
        self[key] = .scalar(String(value))
    }

    /// Skalar, sofern vorhanden und nicht leer.
    func nonEmptyString(_ key: String) -> String? {
        guard let value = values[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    func timestamp(_ key: String) -> Date? {
        nonEmptyString(key).flatMap(DateFormatting.timestamp(from:))
    }

    /// Alle Schlüssel außer den übergebenen — das, was die App nicht kennt.
    func except(_ known: Set<String>) -> [String: FrontmatterValue] {
        var result: [String: FrontmatterValue] = [:]
        for key in keys where !known.contains(key) {
            result[key] = values[key]
        }
        return result
    }

    mutating func merge(unknown: [String: FrontmatterValue]) {
        for key in unknown.keys.sorted() {
            self[key] = unknown[key]
        }
    }

    func serialized() -> String {
        keys.compactMap { key in
            guard let value = values[key] else { return nil }
            return switch value {
            case .scalar(let scalar): "\(key): \(YAMLScalar.write(scalar))"
            case .list(let items): "\(key): [\(items.map(YAMLScalar.write).joined(separator: ", "))]"
            }
        }
        .joined(separator: "\n")
    }

    /// Zerlegt einen Frontmatter-Block. Unbekannte Strukturen werden als
    /// Skalar behandelt, statt den Parser scheitern zu lassen.
    static func parse(_ block: String) -> Frontmatter {
        var frontmatter = Frontmatter()
        let lines = block.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }

            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if rest.hasPrefix("["), rest.hasSuffix("]") {
                let inner = String(rest.dropFirst().dropLast())
                let items = inner
                    .components(separatedBy: ",")
                    .map { YAMLScalar.read($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
                frontmatter[key] = .list(items)
            } else if rest.isEmpty, index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                var items: [String] = []
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    guard item.hasPrefix("- ") else { break }
                    items.append(YAMLScalar.read(String(item.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                frontmatter[key] = .list(items)
            } else {
                frontmatter[key] = .scalar(YAMLScalar.read(rest))
            }
        }
        return frontmatter
    }
}

/// Anführungszeichen setzen und entfernen — genau dort, wo YAML sie braucht.
enum YAMLScalar {
    static func read(_ raw: String) -> String {
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    static func write(_ value: String) -> String {
        guard needsQuoting(value) else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func needsQuoting(_ value: String) -> Bool {
        if value.isEmpty { return true }
        if value != value.trimmingCharacters(in: .whitespaces) { return true }
        if ["true", "false", "yes", "no", "null", "~", "on", "off"].contains(value.lowercased()) {
            return true
        }
        if let first = value.first, "[]{}#&*!|>%@`,\"'-?:".contains(first) { return true }
        if value.contains(": ") || value.contains(" #") || value.contains("\n") { return true }
        return false
    }
}
