import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
public enum ToolCatalog {

    public static let statusName = "spotlight_status"
    public static let searchName = "spotlight_search"

    public static func all(_ configuration: Configuration = Configuration()) -> [Tool] {
        [status, search(configuration)]
    }

    /// The names a call may use, read from the schema so the two cannot drift apart.
    static func argumentNames(of tool: Tool) -> [String] {
        guard case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [] }
        return Array(properties.keys)
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// `type` is the single string `"string"`, never `["string", "null"]`. Claude
    /// Desktop's schema sanitiser drops a property whose `type` is a union and hands the
    /// model a bare `{}` in its place.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(
        _ description: String, minimum: Int, maximum: Int, default def: Int?
    ) -> Value {
        var schema: [String: Value] = [
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum),
        ]
        if let def { schema["default"] = .int(def) }
        return .object(schema)
    }

    private static let pathHelp = """
        Absolute path, or one starting with ~. It is canonicalised — ~ expanded, .. \
        removed, symlinks followed — and then checked against the configured folders \
        before anything happens.
        """

    private static let dateHelp = """
        Accepts 2026-08-12 (that whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    // MARK: Tools

    static let status = Tool(
        name: statusName,
        title: "Spotlight scope and permissions",
        description: """
            Reports which folders this server may search, whether macOS is actually \
            letting it reach them, and whether Spotlight is answering for them. Reads no \
            file contents.

            Call it first in any session that will search files: it separates "outside \
            the configured scope" from "macOS refused" from "Spotlight looks slow or \
            unresponsive right now", which are three different problems with three \
            different fixes. That third check is a fast, narrow canary query, though, \
            not spotlight_search itself — it has been observed under-reporting a folder \
            that a real search then answered correctly. Treat a non-responding result \
            here as a reason to double-check, never as proof that spotlight_search will \
            find nothing: if a search comes back with real matches, believe the search.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static func search(_ configuration: Configuration) -> Tool {
        let limits = Configuration.searchLimitRange
        let sizes = Configuration.sizeRange
        return Tool(
            name: searchName,
            title: "Search files with Spotlight",
            description: """
                Returns one page of the files Spotlight matches, most recently modified first: \
                one path per match with its size, modification time and kind. A page holds \
                \(configuration.searchLimit) files unless 'limit' (\(limits.lowerBound)–\(limits.upperBound)) says \
                otherwise. When more matches exist the result says how many and gives the \
                'offset' that returns the next page; 'sort' changes the order \
                (modified, created, name or size) and ties are ordered by path, so pages \
                never overlap. If Spotlight has not finished at its deadline, the result \
                holds what had arrived and says it is partial: narrow the filters.

                Filters, any combination (at least one is required): 'name_contains', \
                'text_contains' (TEXT INSIDE THE FILE), 'kind', 'content_type' (a UTI), \
                'from_date' and 'to_date' (modification time, both inclusive), \
                'min_size' and 'max_size' (bytes), 'tag' (a Finder tag), and 'folder' to \
                search under one folder.

                'text_contains' is the reason to use this at all: Spotlight has already \
                read the contents of every PDF, Pages document, mail message and source \
                file it indexed, so it finds a word inside them without opening anything. \
                Spotlight answers from its index. A file it has not indexed — an excluded \
                volume, a network share, something written seconds ago — is invisible here \
                however plainly it exists.

                Sorting by 'modified' with no other filter than a recent 'from_date' is how \
                you ask for recent work; there is deliberately no separate "recent files" tool.
                """,
            inputSchema: object(properties: [
                "name_contains": string("Substring of the file name."),
                "text_contains": string(
                    "Words to find INSIDE the file, using Spotlight's indexed contents."),
                "kind": string(
                    """
                    Finder's own kind description, matched as a substring: "PDF", \
                    "Folder", "Pages", "JPEG image".
                    """),
                "content_type": string(
                    """
                    A UTI matched against the type tree, so "public.image" finds a PNG and \
                    a HEIC, and "com.adobe.pdf" finds PDFs.
                    """),
                "tag": string("A Finder tag name, matched exactly."),
                "from_date": string(
                    "Only files modified at or after this, included. \(dateHelp)"),
                "to_date": string(
                    """
                    Only files modified up to and including this: a plain day covers the \
                    whole day. \(dateHelp)
                    """),
                "min_size": integer(
                    "Smallest file size in bytes.", minimum: sizes.lowerBound,
                    maximum: sizes.upperBound, default: nil),
                "max_size": integer(
                    "Largest file size in bytes.", minimum: sizes.lowerBound,
                    maximum: sizes.upperBound, default: nil),
                "folder": string(
                    "Restrict the search to this folder and everything under it. \(pathHelp) "
                        + "Omit to search every configured readable folder."),
                "sort": .object([
                    "type": .string("string"),
                    "enum": .array(SearchSort.allCases.map { .string($0.rawValue) }),
                    "default": .string(SearchSort.modified.rawValue),
                    "description": .string(
                        """
                        Order of the matches: modified, created and size put the newest or \
                        largest first; name goes A to Z. Ties are ordered by path.
                        """),
                ]),
                "limit": integer(
                    "Number of files in the page.",
                    minimum: limits.lowerBound, maximum: limits.upperBound,
                    default: configuration.searchLimit),
                "offset": integer(
                    "Number of matches to skip; pass the offset the result gives for the next page.",
                    minimum: Configuration.offsetRange.lowerBound,
                    maximum: Configuration.offsetRange.upperBound, default: 0),
            ]),
            annotations: .init(
                readOnlyHint: true, destructiveHint: false, idempotentHint: true,
                openWorldHint: false)
        )
    }
}
