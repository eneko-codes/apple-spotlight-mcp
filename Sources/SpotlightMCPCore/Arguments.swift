import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
public struct Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    // MARK: Scalars

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Clamps rather than rejects: a model asking for 5000 results means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    /// An integer the caller may legitimately omit, where the absence means "no bound"
    /// rather than a default value.
    public func optionalInt(_ name: String) throws -> Int? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return number
    }

    // MARK: Dates

    public func optionalDate(_ name: String) throws -> Date? {
        guard let raw = optionalString(name) else { return nil }
        return try DateParsing.parse(raw, argument: name, calendar: calendar).date
    }
}
