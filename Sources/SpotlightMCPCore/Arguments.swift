import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool hands `notices` to `Format`, which puts them before the data.
public final class Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    /// Refuses any argument the tool's schema does not list. Without this a call that still
    /// uses a renamed argument would run without it and return a wider answer than asked for.
    public func refuseUnknown(allowed: [String]) throws {
        let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
        guard !unknown.isEmpty else { return }
        throw ToolError.unknownArguments(unknown, allowed: allowed.sorted())
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    private func wholeNumber(_ name: String) throws -> Int? {
        guard let raw = given(name) else { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return number
    }

    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A quantity: a count or a size. Outside its range it is moved to the nearest allowed
    /// value, and `notices` gains the sentence that says which value was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let number = try wholeNumber(name) else { return fallback }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// A quantity the caller may omit, where the absence means "no bound".
    public func optionalInt(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let number = try wholeNumber(name) else { return nil }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: Configuration.offsetRange)
        )
    }

    /// One of a fixed set of words, compared case-insensitively.
    public func choice(_ name: String, among allowed: [String], default fallback: String) throws
        -> String
    {
        guard let raw = given(name) else { return fallback }
        let text = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Empty text is "not given", as it is for every other text argument.
        if text == "" { return fallback }
        guard let text, allowed.contains(text) else {
            throw ToolError.badArgument(
                name: name, reason: "expected one of: " + allowed.joined(separator: ", "))
        }
        return text
    }

    // MARK: Dates

    public func optionalDate(_ name: String) throws -> ParsedDate? {
        guard let raw = try optionalString(name) else { return nil }
        return try DateParsing.parse(raw, argument: name, calendar: calendar)
    }
}
