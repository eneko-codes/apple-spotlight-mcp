import Foundation

public struct ParsedDate: Sendable, Equatable {
    public let date: Date
    /// True when the caller wrote only a day. A date-only bound is taken at the start of
    /// that day, which is what makes `modified_after: 2026-08-12` mean "on or after the
    /// 12th" rather than "after noon on the 12th".
    public let isDateOnly: Bool

    public init(date: Date, isDateOnly: Bool) {
        self.date = date
        self.isDateOnly = isDateOnly
    }
}

/// Parsing and rendering of the three date forms this server accepts.
///
/// Deliberately strict. A lenient parser that guesses at `10/08/2026` will one day read
/// it as 8 October for a caller who meant 10 August, and a date filter that quietly
/// covers the wrong two months returns a plausible, wrong answer.
public enum DateParsing {

    public static let acceptedForms = """
        - 2026-08-12                  a whole day, local time
        - 2026-08-12T09:00            local time
        - 2026-08-12T09:00:00+02:00   explicit offset
        """

    public static func parse(_ raw: String, argument: String, calendar: Calendar) throws
        -> ParsedDate
    {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let components = dayComponents(text) {
            guard let day = calendar.date(from: components) else {
                throw ToolError.badDate(argument: argument, value: text)
            }
            return ParsedDate(date: calendar.startOfDay(for: day), isDateOnly: true)
        }

        if let components = localComponents(text) {
            guard let moment = calendar.date(from: components) else {
                throw ToolError.badDate(argument: argument, value: text)
            }
            return ParsedDate(date: moment, isDateOnly: false)
        }

        // Only reached for a string carrying its own offset or Z suffix, where the
        // machine's time zone is irrelevant.
        let optionSets: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
        ]
        for options in optionSets {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let moment = formatter.date(from: text) {
                return ParsedDate(date: moment, isDateOnly: false)
            }
        }

        throw ToolError.badDate(argument: argument, value: text)
    }

    /// `YYYY-MM-DD` and nothing else.
    private static func dayComponents(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// `YYYY-MM-DDTHH:MM` or `YYYY-MM-DDTHH:MM:SS`, with no offset suffix.
    private static func localComponents(_ text: String) -> DateComponents? {
        let halves = text.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2, var day = dayComponents(String(halves[0])) else { return nil }

        let time = halves[1]
        // A trailing Z or offset means the string is absolute; that is the ISO path.
        guard !time.contains("Z"), !time.contains("+"), time.filter({ $0 == "-" }).isEmpty
        else { return nil }

        let pieces = time.split(separator: ":")
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ $0.count == 2 }),
            let hour = Int(pieces[0]), let minute = Int(pieces[1]),
            (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        let second = pieces.count == 3 ? Int(pieces[2]) : 0
        guard let second, (0...59).contains(second) else { return nil }

        day.hour = hour
        day.minute = minute
        day.second = second
        return day
    }

    // MARK: Rendering

    /// `2026-08-12 09:00`. Hand-rolled rather than `DateFormatter` so output does not
    /// change shape with the machine's locale: a model that has learned to read a
    /// timestamp should not be handed a different one on a differently configured Mac.
    /// Sortable as a string, which is what a listing wants.
    public static func timestamp(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0)
    }
}
