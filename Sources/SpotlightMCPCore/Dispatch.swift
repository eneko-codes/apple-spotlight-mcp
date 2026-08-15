import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches the disk directly — everything goes through `SpotlightStore`, which is
/// what lets the tests drive every branch below against an in-memory scope with no real
/// files and no TCC grant.
///
/// Every path argument, without exception, is turned into a `ScopedPath` by
/// `PathScope.resolve` before it is used. There is no other way to obtain one, so a tool
/// added later cannot forget the check: it will not compile.
public struct SpotlightTools: Sendable {
    private let store: any SpotlightStore
    private let scope: PathScope
    private let configuration: Configuration
    private let calendar: Calendar
    private let format: Format

    public init(
        store: any SpotlightStore,
        configuration: Configuration = Configuration(),
        calendar: Calendar = .current
    ) {
        self.store = store
        self.configuration = configuration
        self.calendar = calendar
        self.format = Format(calendar: calendar)
        self.scope = PathScope(configuration: configuration, store: store)
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        switch parameters.name {
        case ToolCatalog.statusName:
            return await status()

        case ToolCatalog.searchName:
            return try await search(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
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

    private func search(_ arguments: Arguments) async throws -> String {
        guard scope.hasReadRoots else { throw ToolError.noReadRootsConfigured }

        var query = SpotlightQuery()
        query.nameContains = arguments.optionalString("name_contains")
        query.textContains = arguments.optionalString("text_contains")
        query.kind = arguments.optionalString("kind")
        query.contentType = arguments.optionalString("content_type")
        query.tag = arguments.optionalString("tag")
        query.modifiedAfter = try arguments.optionalDate("modified_after")
        query.modifiedBefore = try arguments.optionalDate("modified_before")
        query.minimumSizeBytes = try arguments.optionalInt("min_size")
        query.maximumSizeBytes = try arguments.optionalInt("max_size")

        // An unfiltered Spotlight query returns the whole index in arbitrary order, which
        // is never what was meant and is expensive to produce before it can be discarded.
        guard !query.isEmpty else { throw ToolError.emptySearch }

        // A named folder is scope-checked like any other path; an unnamed one falls back
        // to every read root, so a search can never widen past the allow-list.
        if let folder = arguments.optionalString("folder") {
            query.scopes = [try scope.resolve(folder).path]
        } else {
            query.scopes = scope.searchScopes
        }

        query.limit = try arguments.int(
            "limit", default: configuration.searchLimit, in: Configuration.searchLimitRange)
        query.offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)

        return format.searchResults(try await store.search(query), query: query)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
