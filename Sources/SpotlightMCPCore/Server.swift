import Foundation
import MCP

public enum SpotlightMCPServer {

    public static let name = "apple-spotlight-mcp"
    public static let version = "1.0.1"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the allow-list, and the fact that Spotlight and the allow-list are two
    /// separate checks.
    public static let instructions = """
        Searches files on this Mac through Spotlight (NSMetadataQuery). No Finder, no \
        Apple events, no network.

        ONE SCOPE. A list of folders that may be searched, chosen by the person who \
        installed the extension. Every path is canonicalised — ~ expanded, .. removed, \
        symlinks followed — and then checked against that list before anything happens. \
        A path outside it is refused and the error names the configured scope. Call \
        spotlight_status first: it reports the list, whether macOS is actually letting \
        this process reach it, and whether Spotlight is answering — though that last \
        check is a fast, coarse canary, not spotlight_search itself, and it can \
        under-report. A real search's own result always outweighs it: if \
        spotlight_search returns matches, trust them even after a discouraging status.

        spotlight_search asks Spotlight, which has already read the contents of \
        everything it indexed — 'text_contains' is the reason to use this at all: it \
        finds a word inside a PDF, a Pages document or a source file without opening \
        anything. Spotlight answers from its index, though: a file it has not indexed — \
        an excluded volume, a network share, something written seconds ago — is invisible \
        here however plainly it exists, and every query carries a deadline it reports if \
        it hits.

        A path this server returns still has to pass whatever allow-list the tool that \
        opens it enforces — apple-filesystem-mcp for a file's contents, apple-pdf-mcp for \
        a PDF's text, apple-vision-mcp for OCR. Spotlight's index and a read allow-list \
        are two separate checks.

        This server never writes anything and has no delete of any kind.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing in
    /// this function opens a file by itself.
    public static func run(
        store: any SpotlightStore = SystemSpotlightStore(),
        configuration: Configuration = Configuration()
    ) async throws {
        let tools = SpotlightTools(store: store, configuration: configuration)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all(configuration)) }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
