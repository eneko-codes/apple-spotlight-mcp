import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
public enum ToolCatalog {

    public static let statusName = "spotlight_status"
    public static let searchName = "spotlight_search"

    public static func all(_ configuration: Configuration = Configuration()) -> [Tool] {
        [status, search(configuration)]
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
        _ description: String, minimum: Int, maximum: Int, default def: Int
    ) -> Value {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
    }

    private static let pathHelp = """
        Absolute path, or one starting with ~. It is canonicalised — ~ expanded, .. \
        removed, symlinks followed — and then checked against the configured folders \
        before anything happens.
        """

    private static let dateHelp = """
        Accepts 2026-08-12 (that day, from midnight), 2026-08-12T09:00 (local time), or \
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

            Call it first in any session that will search files, and again whenever \
            spotlight_search returns nothing you expected: it separates "outside the \
            configured scope" from "macOS refused" from "Spotlight has not indexed \
            this", which are three different problems with three different fixes.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static func search(_ configuration: Configuration) -> Tool {
        Tool(
            name: searchName,
            title: "Search files with Spotlight",
            description: """
                Asks Spotlight for files matching any combination of: name, TEXT INSIDE THE \
                FILE, kind, UTI, modification date range, size range and Finder tag — \
                optionally under one folder. Returns one path per match with size, date and \
                kind.

                'text_contains' is the reason to use this at all: Spotlight has already \
                read the contents of every PDF, Pages document, mail message and source \
                file it indexed, so it finds a word inside them without opening anything. \
                At least one filter is required.

                Spotlight answers from its index. A file it has not indexed — an excluded \
                volume, a network share, something written seconds ago — is invisible here \
                however plainly it exists. Results are capped at \
                \(configuration.searchLimit) by default.

                Sorting by 'modified' descending with no other filter is how you ask for \
                recent work; there is deliberately no separate "recent files" tool.
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
                "modified_after": string("Only files modified at or after this. \(dateHelp)"),
                "modified_before": string("Only files modified before this. \(dateHelp)"),
                "min_size": integer(
                    "Smallest file size in bytes.", minimum: 0, maximum: 1_000_000_000_000,
                    default: 0),
                "max_size": integer(
                    "Largest file size in bytes.", minimum: 0, maximum: 1_000_000_000_000,
                    default: 1_000_000_000_000),
                "folder": string(
                    "Restrict the search to this folder and everything under it. \(pathHelp) "
                        + "Omit to search every configured readable folder."),
                "sort": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("modified"), .string("created"), .string("name"), .string("size"),
                    ]),
                    "default": .string("modified"),
                    "description": .string("Field to sort by, always descending except 'name'."),
                ]),
                "limit": integer(
                    "Maximum number of files to return.",
                    minimum: Configuration.searchLimitRange.lowerBound,
                    maximum: Configuration.searchLimitRange.upperBound,
                    default: configuration.searchLimit),
                "offset": integer(
                    "Skip this many matches; use it to page.",
                    minimum: Configuration.offsetRange.lowerBound,
                    maximum: Configuration.offsetRange.upperBound, default: 0),
            ]),
            annotations: .init(
                readOnlyHint: true, destructiveHint: false, idempotentHint: true,
                openWorldHint: false)
        )
    }
}
