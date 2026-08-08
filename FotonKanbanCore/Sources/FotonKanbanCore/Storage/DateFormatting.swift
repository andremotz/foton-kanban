import Foundation

/// Zwei Formate: Zeitstempel mit Zeitzone für `created`/`updated`,
/// reine Tagesdaten für Termine und Review-Runden.
///
/// Die ISO-Formatter sind `nonisolated(unsafe)`, weil Foundation
/// `ISO8601DateFormatter` nicht als `Sendable` markiert. Sie werden nach der
/// Initialisierung nur noch gelesen, und Formatieren ist threadsicher.
enum DateFormatting {
    nonisolated(unsafe) private static let timestampWriter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        formatter.timeZone = .current
        return formatter
    }()

    nonisolated(unsafe) private static let timestampReaders: [ISO8601DateFormatter] = {
        let variants: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withColonSeparatorInTimeZone],
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ]
        return variants.map { options in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            return formatter
        }
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    static func timestamp(_ date: Date) -> String { timestampWriter.string(from: date) }

    static func timestamp(from text: String) -> Date? {
        for reader in timestampReaders {
            if let date = reader.date(from: text) { return date }
        }
        return day(from: text)
    }

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func day(from text: String) -> Date? { dayFormatter.date(from: text) }
}
