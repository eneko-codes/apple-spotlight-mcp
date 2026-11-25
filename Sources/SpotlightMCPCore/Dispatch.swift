import Foundation

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches the disk directly — everything goes through `SpotlightStore`, which is
/// what lets the tests drive every branch below against an in-memory scope with no real
/// files and no TCC grant.
///
/// Every path argument, without exception, is turned into a `ScopedPath` by
/// `PathScope.resolve` before it is used. There is no other way to obtain one, so a tool
/// added later cannot forget the check: it will not compile.
public struct SpotlightTools: ToolHandler {
    private let store: any SpotlightStore
    private let scope: PathScope
    private let configuration: Configuration
    private let calendar: Calendar
    private let format: Format
    private let timeout: Duration

    public init(
        store: any SpotlightStore,
        configuration: Configuration = Configuration(),
        calendar: Calendar = .current,
        timeout: Duration = SpotlightTools.defaultTimeout
    ) {
        self.timeout = timeout
        self.store = store
        self.configuration = configuration
        self.calendar = calendar
        self.format = Format(calendar: calendar)
        self.scope = PathScope(configuration: configuration, store: store)
    }

    /// Spotlight is given 20 seconds to gather (`SystemSpotlightStore.gatheringDeadline`), and
    /// that reports partial results. This is the backstop above it, for work that never
    /// comes back at all, and it stays inside `ToolStandard.timeLimit`.
    public static let defaultTimeout = Duration.seconds(60)

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            if let error = error as? ToolError {
                return ToolOutput(text: error.message, isError: true)
            }
            return ToolOutput(
                text: ToolError.storeFailure(error.localizedDescription).message, isError: true)
        case nil:
            let error = ToolError.timedOut(seconds: Int(timeout.components.seconds))
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            return ToolOutput(text: error.message, isError: true)
        }
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        switch parameters.name {
        case ToolCatalog.statusName:
            try arguments.refuseUnknown(allowed: ToolCatalog.argumentNames(of: ToolCatalog.status))
            return await status()

        case ToolCatalog.searchName:
            try arguments.refuseUnknown(
                allowed: ToolCatalog.argumentNames(of: ToolCatalog.search(configuration)))
            return try await search(arguments)

        default:
            throw ToolError.unknownTool(parameters.name)
        }
    }

    private func status() async -> String {
        let probes = scope.probeRoots()
        // Probed over the read roots only: asking about scopes nothing can be searched
        // from would report a failure that means nothing.
        let index =
            scope.searchScopes.isEmpty
            ? IndexState.empty : await store.indexState(scopes: scope.searchScopes)
        return format.status(
            probes: probes, indexState: index, binaryPath: Self.binaryPath,
            configuration: configuration)
    }

    /// The stretch of time a search covers. `modifiedBefore` is the first instant past it,
    /// because `to_date` is included: a plain day runs to the end of that day, and a time
    /// covers the minute or second it was written to.
    private func modifiedRange(from: ParsedDate?, to: ParsedDate?) throws -> (Date?, Date?) {
        let upper = to.map { to -> Date in
            if to.isDateOnly { return calendar.date(byAdding: .day, value: 1, to: to.date) ?? to.date }
            return to.date.addingTimeInterval(to.isMinutePrecision ? 60 : 1)
        }
        if let from, let upper, upper <= from.date {
            throw ToolError.rangeEndsBeforeItStarts(from: "from_date", to: "to_date")
        }
        return (from?.date, upper)
    }

    private func search(_ arguments: Arguments) async throws -> String {
        guard scope.hasReadRoots else { throw ToolError.noReadRootsConfigured }

        var query = SpotlightQuery()
        query.nameContains = try arguments.optionalString("name_contains")
        query.textContains = try arguments.optionalString("text_contains")
        query.kind = try arguments.optionalString("kind")
        query.contentType = try arguments.optionalString("content_type")
        query.tag = try arguments.optionalString("tag")
        (query.modifiedAfter, query.modifiedBefore) = try modifiedRange(
            from: try arguments.optionalDate("from_date"), to: try arguments.optionalDate("to_date"))
        query.minimumSizeBytes = try arguments.optionalInt("min_size", in: Configuration.sizeRange)
        query.maximumSizeBytes = try arguments.optionalInt("max_size", in: Configuration.sizeRange)
        if let minimum = query.minimumSizeBytes, let maximum = query.maximumSizeBytes,
            minimum > maximum
        {
            throw ToolError.badArgument(
                name: "min_size", reason: "it is larger than max_size, so no file can match")
        }
        query.sort = SearchSort(
            rawValue: try arguments.choice(
                "sort", among: SearchSort.allCases.map(\.rawValue), default: SearchSort.modified.rawValue))!

        // An unfiltered Spotlight query returns the whole index in arbitrary order, which
        // is never what was meant and is expensive to produce before it can be discarded.
        guard !query.isEmpty else { throw ToolError.emptySearch }

        // A named folder is scope-checked like any other path; an unnamed one falls back
        // to every read root, so a search can never widen past the allow-list.
        if let folder = try arguments.optionalString("folder") {
            query.scopes = [try scope.resolve(folder).path]
        } else {
            query.scopes = scope.searchScopes
        }

        let paging = try arguments.page(
            defaultLimit: configuration.searchLimit, limits: Configuration.searchLimitRange)
        query.limit = paging.limit
        query.offset = paging.offset

        return format.searchResults(
            try await store.search(query), query: query, notices: arguments.notices)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
