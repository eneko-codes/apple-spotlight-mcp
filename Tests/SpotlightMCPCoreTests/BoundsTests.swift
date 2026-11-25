import Foundation
import Testing

@testable import SpotlightMCPCore

/// Answers a search from a list of invented matches, the way the runner does: it knows the
/// total, and returns only the rows of the page asked for. Remembers the last query so a
/// test can see what the tool asked Spotlight.
private final class ListingStore: SpotlightStore, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: SpotlightQuery?
    let hits: [SearchHit]
    let timedOut: Bool
    let delay: Duration?

    init(count: Int, pathWidth: Int = 60, timedOut: Bool = false, delay: Duration? = nil) {
        hits = (0..<count).map { Self.hit($0, pathWidth: pathWidth) }
        self.timedOut = timedOut
        self.delay = delay
    }

    static func name(_ index: Int) -> String { "invented-\(String(format: "%04d", index)).txt" }

    static func hit(_ index: Int, pathWidth: Int) -> SearchHit {
        let folder = "/Users/user/Documents/"
        let leaf = name(index)
        let padding = String(repeating: "d", count: max(0, pathWidth - folder.count - leaf.count - 1))
        let path = padding.isEmpty ? folder + leaf : folder + padding + "/" + leaf
        return SearchHit(
            path: path, name: leaf, sizeBytes: 1_234_567,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), kindDescription: "Plain Text")
    }

    var lastQuery: SpotlightQuery? { lock.withLock { recorded } }

    func canonicalise(_ path: String) throws -> CanonicalPath {
        CanonicalPath(path: (path as NSString).standardizingPath, exists: true)
    }
    func probe(_ path: String) -> RootState { .reachable }
    func indexState(scopes: [String]) async -> IndexState { .responding }

    func search(_ query: SpotlightQuery) async throws -> SearchPage {
        lock.withLock { recorded = query }
        if let delay { try await Task.sleep(for: delay) }
        let page = Array(hits.dropFirst(query.offset).prefix(query.limit))
        return SearchPage(results: page, total: hits.count, timedOut: timedOut)
    }
}

/// The edges of the tool standard for this server's tools: each bound and one past it, the
/// text of each notice, pages that chain, the longest result, and the texts the model reads.
/// Every path, name and size in here is invented.
@Suite("Bounds")
struct BoundsTests {

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }()

    private static var configuration: Configuration {
        var configuration = Configuration()
        configuration.readRoots = ["/Users/user/Documents"]
        return configuration
    }

    private static func call(
        _ arguments: [String: Value] = ["name_contains": "invented"],
        tool: String = ToolCatalog.searchName,
        store: any SpotlightStore, timeout: Duration = SpotlightTools.defaultTimeout
    ) async -> ToolOutput {
        let tools = SpotlightTools(
            store: store, configuration: configuration, calendar: calendar, timeout: timeout)
        return await tools.handle(ToolCall(name: tool, arguments: arguments))
    }

    private static func shown(_ text: String, of count: Int) -> [Int] {
        (0..<count).filter { text.contains(ListingStore.name($0)) }
    }

    private static let defaultLimit = Configuration.defaultSearchLimit
    private static let limits = Configuration.searchLimitRange

    // MARK: Pages

    @Test("A call with only a filter returns one default page, announced before the data")
    func defaultPage() async {
        let total = Self.defaultLimit + 5
        let result = await Self.call(store: ListingStore(count: total))
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(Self.defaultLimit) of \(total) matches. Pass offset=\(Self.defaultLimit) for the next page.\n\n"))
        #expect(Self.shown(result.text, of: total) == Array(0..<Self.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every match from the start carries no notice")
    func wholeResultHasNoNotice() async {
        let result = await Self.call(store: ListingStore(count: Self.defaultLimit))
        #expect(Self.shown(result.text, of: Self.defaultLimit).count == Self.defaultLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
        #expect(!result.text.contains("Partial"))
    }

    @Test("limit at its maximum is used as asked, and a full page of ordinary paths fits a result")
    func limitAtItsMaximum() async {
        let maximum = Self.limits.upperBound
        let total = maximum + 10
        let result = await Self.call(
            ["name_contains": "invented", "limit": .int(maximum)],
            store: ListingStore(count: total, pathWidth: 150))
        #expect(!result.text.contains("is outside"))
        #expect(result.text.hasPrefix("Showing 1–\(maximum) of \(total) matches. Pass offset=\(maximum) for the next page.\n\n"))
        #expect(Self.shown(result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which")
    func limitPastItsRange() async {
        let maximum = Self.limits.upperBound
        let total = maximum + 10
        let store = ListingStore(count: total)

        let over = await Self.call(["name_contains": "x", "limit": .int(maximum + 1)], store: store)
        #expect(
            over.text.hasPrefix(
                """
                limit=\(maximum + 1) is outside \(Self.limits.lowerBound)–\(maximum); \(maximum) was used.
                Showing 1–\(maximum) of \(total) matches. Pass offset=\(maximum) for the next page.


                """))
        #expect(Self.shown(over.text, of: total) == Array(0..<maximum))

        let under = await Self.call(["name_contains": "x", "limit": .int(0)], store: store)
        #expect(under.text.hasPrefix("limit=0 is outside \(Self.limits.lowerBound)–\(maximum); 1 was used.\nShowing 1–1 of \(total) "))
        #expect(Self.shown(under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all")
    func pagesChain() async {
        let store = ListingStore(count: 7)
        let first = await Self.call(["name_contains": "x", "limit": 3], store: store)
        #expect(first.text.hasPrefix("Showing 1–3 of 7 matches. Pass offset=3 for the next page.\n\n"))
        let second = await Self.call(["name_contains": "x", "limit": 3, "offset": 3], store: store)
        #expect(second.text.hasPrefix("Showing 4–6 of 7 matches. Pass offset=6 for the next page.\n\n"))
        let last = await Self.call(["name_contains": "x", "limit": 3, "offset": 6], store: store)
        #expect(last.text.hasPrefix("Showing 7–7 of 7 matches. That is all.\n\n"))
        #expect(Self.shown(first.text, of: 7) == [0, 1, 2])
        #expect(Self.shown(second.text, of: 7) == [3, 4, 5])
        #expect(Self.shown(last.text, of: 7) == [6])
    }

    @Test("An offset past the end says so, and an offset past its range is moved")
    func offsetPastTheEnd() async {
        let store = ListingStore(count: 7)
        let past = await Self.call(["name_contains": "x", "offset": 40], store: store)
        #expect(past.text.hasPrefix("Showing 0 of 7 matches: offset=40 is past the end. That is all."))
        let range = Configuration.offsetRange
        let beyond = await Self.call(["name_contains": "x", "offset": .int(range.upperBound + 1)], store: store)
        #expect(beyond.text.hasPrefix("offset=\(range.upperBound + 1) is outside \(range.lowerBound)–\(range.upperBound); \(range.upperBound) was used."))
        let negative = await Self.call(["name_contains": "x", "offset": -1], store: store)
        #expect(negative.text.hasPrefix("offset=-1 is outside "))
    }

    @Test("A result with more matches than the old paging ceiling can still be paged to its end")
    func deepPaging() async {
        let total = 10_130
        let result = await Self.call(
            ["name_contains": "x", "offset": 10_100, "limit": 50], store: ListingStore(count: total))
        #expect(!result.text.contains("is outside"))
        #expect(result.text.hasPrefix("Showing 10101–\(total) of \(total) matches. That is all.\n\n"))
        #expect(Self.shown(result.text, of: total).count == 30)
    }

    @Test("A page of very long paths holds fewer rows than limit and says where to resume")
    func widePageShrinks() async {
        let maximum = Self.limits.upperBound
        let result = await Self.call(
            ["name_contains": "x", "limit": .int(maximum)],
            store: ListingStore(count: maximum + 20, pathWidth: 3_000))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        #expect(!result.text.contains("Cut at"))
        let shown = Self.shown(result.text, of: maximum + 20)
        #expect(shown == Array(0..<shown.count))
        #expect(shown.count < maximum)
        #expect(result.text.contains("Showing 1–\(shown.count) of \(maximum + 20) matches. Pass offset=\(shown.count) for the next page."))
    }

    @Test("Nothing found is said as no matches, not as a page notice")
    func noMatches() async {
        let result = await Self.call(store: ListingStore(count: 0))
        #expect(result.text.contains("(no matches)"))
        #expect(!result.text.contains("Showing"))
    }

    // MARK: Order

    @Test("sort is read, passed on, and its order is stated; an unknown sort is refused")
    func sortIsHonoured() async {
        for sort in SearchSort.allCases {
            let store = ListingStore(count: 3)
            let result = await Self.call(["name_contains": "x", "sort": .string(sort.rawValue)], store: store)
            #expect(store.lastQuery?.sort == sort)
            #expect(result.text.contains("order: \(sort.summary), then by path"))
        }
        let store = ListingStore(count: 3)
        let unknown = await Self.call(["name_contains": "x", "sort": "random"], store: store)
        #expect(unknown.isError)
        #expect(unknown.text.contains("expected one of: modified, created, name, size"))
        #expect(store.lastQuery == nil)
        let standard = ListingStore(count: 3)
        _ = await Self.call(store: standard)
        #expect(standard.lastQuery?.sort == .modified)
    }

    @Test("Every sort ends on the path, so no two matches tie")
    func sortsEndOnThePath() {
        for sort in SearchSort.allCases {
            let descriptors = SystemSpotlightStore.sortDescriptors(for: sort)
            #expect(descriptors.count == 2)
            #expect(descriptors.last?.key == NSMetadataItemPathKey)
            #expect(descriptors.last?.ascending == true)
        }
    }

    // MARK: Dates and sizes

    @Test("from_date and to_date are inclusive: a day covers the whole day, a minute covers the minute")
    func dateRangeIsInclusive() async throws {
        let day = ListingStore(count: 1)
        _ = await Self.call(["from_date": "2026-08-12", "to_date": "2026-08-12"], store: day)
        let from = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 12)))
        let next = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 13)))
        #expect(day.lastQuery?.modifiedAfter == from)
        #expect(day.lastQuery?.modifiedBefore == next)

        let minute = ListingStore(count: 1)
        _ = await Self.call(["to_date": "2026-08-12T09:00"], store: minute)
        let nine = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 9)))
        #expect(minute.lastQuery?.modifiedBefore == nine.addingTimeInterval(60))
        #expect(minute.lastQuery?.modifiedAfter == nil)

        let second = ListingStore(count: 1)
        _ = await Self.call(["to_date": "2026-08-12T09:00:30+02:00"], store: second)
        #expect(second.lastQuery?.modifiedBefore == nine.addingTimeInterval(31))
    }

    @Test("A date that does not exist, or a range that ends before it starts, is refused")
    func impossibleDates() async {
        for value in ["2026-02-30", "2026-03-29T02:30", "2026-04-31T09:00:00+02:00"] {
            let result = await Self.call(["from_date": .string(value)], store: ListingStore(count: 1))
            #expect(result.isError, "\(value)")
            #expect(result.text.contains("does not exist"), "\(value)")
        }
        let garbled = await Self.call(["from_date": "12/08/2026"], store: ListingStore(count: 1))
        #expect(garbled.isError && garbled.text.contains("is not a date this server accepts"))
        let backwards = await Self.call(
            ["from_date": "2026-08-12", "to_date": "2026-08-11"], store: ListingStore(count: 1))
        #expect(backwards.isError && backwards.text.contains("The range ends before it starts"))
        let same = await Self.call(
            ["from_date": "2026-08-12", "to_date": "2026-08-12"], store: ListingStore(count: 1))
        #expect(!same.isError)
    }

    @Test("A size outside its range is moved and reported; a range that no file fits is refused")
    func sizeBounds() async {
        let range = Configuration.sizeRange
        let store = ListingStore(count: 1)
        let result = await Self.call(
            ["min_size": -5, "max_size": .int(range.upperBound + 1)], store: store)
        #expect(result.text.hasPrefix("""
            min_size=-5 is outside \(range.lowerBound)–\(range.upperBound); \(range.lowerBound) was used.
            max_size=\(range.upperBound + 1) is outside \(range.lowerBound)–\(range.upperBound); \(range.upperBound) was used.
            """))
        #expect(store.lastQuery?.minimumSizeBytes == range.lowerBound)
        #expect(store.lastQuery?.maximumSizeBytes == range.upperBound)

        let edges = await Self.call(
            ["min_size": .int(range.lowerBound), "max_size": .int(range.upperBound)], store: ListingStore(count: 1))
        #expect(!edges.text.contains("is outside"))

        let inverted = await Self.call(["min_size": 10, "max_size": 5], store: ListingStore(count: 1))
        #expect(inverted.isError && inverted.text.contains("larger than max_size"))
        let wrongType = await Self.call(["min_size": "big"], store: ListingStore(count: 1))
        #expect(wrongType.isError && wrongType.text.contains("a whole number was expected"))
    }

    // MARK: Arguments

    @Test("An argument the schema does not list is refused, naming the ones allowed")
    func unknownArguments() async {
        let store = ListingStore(count: 3)
        let renamed = await Self.call(["name_contains": "x", "modified_after": "2026-08-12"], store: store)
        #expect(renamed.isError)
        #expect(renamed.text.contains("Not an argument of this tool: 'modified_after'"))
        #expect(renamed.text.contains("from_date"))
        #expect(store.lastQuery == nil)

        let status = await Self.call(["limit": 5], tool: ToolCatalog.statusName, store: store)
        #expect(status.isError && status.text.contains("this tool takes no arguments"))
    }

    @Test("A wrong type is refused with the form expected")
    func wrongTypes() async {
        let text = await Self.call(["name_contains": 5], store: ListingStore(count: 1))
        #expect(text.isError && text.text.contains("text was expected"))
        let limit = await Self.call(["name_contains": "x", "limit": "ten"], store: ListingStore(count: 1))
        #expect(limit.isError && limit.text.contains("a whole number was expected"))
    }

    // MARK: Errors and time

    @Test("A deadline that passes inside Spotlight is announced as partial, before the data")
    func partialResults() async {
        let store = ListingStore(count: 3, timedOut: true)
        let result = await Self.call(store: store)
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Partial: the time limit was reached after 3 matches. Narrow by "))
        #expect(result.text.contains("Spotlight: partial results"))
        #expect(Self.shown(result.text, of: 3) == [0, 1, 2])
        #expect(!result.text.contains("That is all"))

        let paged = await Self.call(["name_contains": "x", "limit": 2], store: store)
        #expect(paged.text.contains("Showing 1–2 matches; more exist. Pass offset=2 for the next page."))
    }

    @Test("A call that never comes back is abandoned inside the time limit, with an error saying so")
    func callTimesOut() async {
        let result = await Self.call(
            store: ListingStore(count: 1, delay: .seconds(30)), timeout: .milliseconds(50))
        #expect(result.isError)
        #expect(result.text.contains("did not finish within"))
        #expect(SpotlightTools.defaultTimeout <= ToolStandard.timeLimit)
        #expect(Duration.seconds(SystemSpotlightStore.gatheringDeadline) < SpotlightTools.defaultTimeout)
    }

    @Test("An error repeats at most a short piece of what the caller sent")
    func errorsClipWhatTheyEcho() async {
        let long = String(repeating: "n", count: 5000)
        let tool = await Self.call([:], tool: long, store: ListingStore(count: 1))
        #expect(tool.isError && tool.text.contains("is not a tool of this server"))
        #expect(tool.text.count < ToolStandard.echoWidth + 60)

        let folder = await Self.call(["name_contains": "x", "folder": .string("/elsewhere/" + long)], store: ListingStore(count: 1))
        #expect(folder.isError)
        #expect(folder.text.utf16.count <= ToolStandard.longestError / 10)
        #expect(!folder.text.contains(String(repeating: "n", count: ToolStandard.echoWidth + 1)))

        let name = await Self.call(["name_contains": "x", long: 1], store: ListingStore(count: 1))
        #expect(name.isError && name.text.utf16.count <= ToolStandard.longestError / 10)
        let date = await Self.call(["from_date": .string(long)], store: ListingStore(count: 1))
        #expect(date.isError && date.text.utf16.count <= ToolStandard.longestError / 10)
    }

    @Test("Every error this server words is far inside the longest error")
    func errorsAreShort() {
        let long = String(repeating: "n", count: 5000)
        let errors: [ToolError] = [
            .noReadRootsConfigured, .missingArgument(long), .badArgument(name: long, reason: "x"),
            .badDate(argument: "from_date", value: long), .nonexistentDate(argument: "to_date", value: long),
            .rangeEndsBeforeItStarts(from: "from_date", to: "to_date"),
            .unknownArguments([long, long, long, long, long], allowed: ["a", "b"]), .unknownTool(long),
            .timedOut(seconds: 60), .emptySearch, .storeFailure(long),
            .pathOutOfScope(requested: long, resolved: long, readRoots: (0..<50).map { "/Users/user/\($0)" }),
            .permissionDenied(path: long, detail: long),
        ]
        for error in errors {
            #expect(error.message.utf16.count <= ToolStandard.longestError / 5, "\(Diagnostics.kind(of: error))")
        }
    }

    // MARK: What the model reads

    @Test("The instructions and every tool description are within the longest a client keeps")
    func textsAreWithinTheLimit() {
        #expect(ToolStandard.overlongTexts(instructions: SpotlightMCPServer.instructions, catalog: ToolCatalog.all()).isEmpty)
        #expect(!SpotlightMCPServer.instructions.isEmpty)
    }

    private func properties(of tool: Tool) -> [String: [String: Value]] {
        guard case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [:] }
        return properties.compactMapValues(\.objectValue)
    }

    @Test("The schema states the ranges and defaults the code enforces, and the texts quote the same figures")
    func schemaAgreesWithTheCode() throws {
        let tool = ToolCatalog.search(Self.configuration)
        let fields = properties(of: tool)
        let limit = try #require(fields["limit"])
        #expect(limit["minimum"]?.intValue == Self.limits.lowerBound)
        #expect(limit["maximum"]?.intValue == Self.limits.upperBound)
        #expect(limit["default"]?.intValue == Self.configuration.searchLimit)
        let offset = try #require(fields["offset"])
        #expect(offset["minimum"]?.intValue == Configuration.offsetRange.lowerBound)
        #expect(offset["maximum"]?.intValue == Configuration.offsetRange.upperBound)
        for name in ["min_size", "max_size"] {
            #expect(fields[name]?["minimum"]?.intValue == Configuration.sizeRange.lowerBound)
            #expect(fields[name]?["maximum"]?.intValue == Configuration.sizeRange.upperBound)
        }
        let description = try #require(tool.description)
        #expect(description.contains("\(Self.limits.lowerBound)–\(Self.limits.upperBound)"))
        #expect(description.contains("\(Self.configuration.searchLimit) files"))
        #expect(SpotlightMCPServer.instructions.contains("\(Self.limits.upperBound) at most"))
        #expect(fields["modified_after"] == nil && fields["modified_before"] == nil)
        #expect(fields["from_date"] != nil && fields["to_date"] != nil)
        #expect(Set(ToolCatalog.argumentNames(of: tool)) == Set(fields.keys))
    }

    @Test("A page of ordinary rows at the largest limit is inside the longest result")
    func largestPageFits() {
        // An ordinary row: a 150-character path and a line of facts, as the stores builds it.
        let hit = ListingStore.hit(0, pathWidth: 150)
        let row = Format(calendar: Self.calendar).searchResults(
            SearchPage(results: [hit], total: 1), query: SpotlightQuery(), notices: [])
        #expect(row.utf16.count * Self.limits.upperBound <= ToolStandard.longestResult)
    }
}
