import Foundation

/// Settings the person installing the extension can change.
///
/// These arrive as command-line arguments because that is how a Claude extension passes
/// `user_config`: the manifest substitutes `${user_config.key}` into `mcp_config.args`.
/// Parsing is hand-rolled rather than pulling in an argument-parsing package — the whole
/// surface is two settings, and every dependency in this repo has to earn its place.
public struct Configuration: Sendable, Equatable {

    /// Folders Claude may search inside. Not a default a caller can widen — a boundary.
    ///
    /// **Empty means nothing is reachable, not everything.** This server never writes,
    /// so there is no second, narrower list the way `apple-filesystem-mcp` has — but the
    /// same fail-closed default applies: a server that does nothing until it is
    /// configured is a nuisance for one minute; one that starts with the home directory
    /// in scope is a different kind of program entirely.
    public var readRoots: [String] = []

    /// Default page size for `spotlight_search`. The tool's own `limit` still wins.
    public var searchLimit: Int = 50

    public init() {}

    public static let searchLimitRange = 1...500

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...10_000

    /// True when an argument is an unsubstituted manifest placeholder.
    ///
    /// Claude Desktop leaves `${user_config.key}` untouched when the person left that
    /// setting empty, so the literal text arrives as an argument. Observed live in the
    /// calendar server: an empty `multiple: true` list produced a bare
    /// `${user_config.calendars}`.
    ///
    /// Taking those at face value is worse than ignoring them: a read-root list would
    /// come to contain one folder nobody has, and every real path would fall out of
    /// scope with an error blaming the caller.
    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("${") && trimmed.hasSuffix("}")
    }

    /// `--read-roots`, then every bare argument until the next flag; `--search-limit`
    /// takes exactly one. Unknown flags are ignored rather than fatal — a server that
    /// will not launch is much harder to diagnose than one running on a default.
    public static func parse(_ arguments: [String]) -> Configuration {
        var configuration = Configuration()
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--read-roots":
                var values: [String] = []
                var cursor = index + 1
                while cursor < arguments.count, !arguments[cursor].hasPrefix("--") {
                    let value = arguments[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty && !isPlaceholder(value) { values.append(value) }
                    cursor += 1
                }
                configuration.readRoots = values
                index = cursor

            case "--search-limit":
                let value = index + 1 < arguments.count ? arguments[index + 1] : nil
                if let value, !isPlaceholder(value), let number = Int(value) {
                    configuration.searchLimit = min(
                        max(number, searchLimitRange.lowerBound), searchLimitRange.upperBound)
                }
                index += 2

            default:
                index += 1
            }
        }
        return configuration
    }
}
