import Foundation
import Testing

@testable import SpotlightMCPCore

/// A `SpotlightStore` that only knows how to canonicalise.
///
/// `PathScope` is the one thing in this module worth proving exhaustively, and it needs
/// exactly one store method: everything else exists so the type conforms. `search`
/// throws rather than returning something plausible — a scope test that accidentally
/// reached a real file or a live Spotlight index should fail loudly, not quietly pass.
///
/// Canonicalisation is modelled rather than performed: the map below says what each raw
/// path resolves to, which is how a symlink pointing out of the allow-list can be
/// expressed without creating one on the real filesystem.
struct StubStore: SpotlightStore {

    /// raw path → where it really lands. Anything absent resolves to itself.
    var resolutions: [String: String] = [:]
    var existing: Set<String> = []

    func canonicalise(_ path: String) throws -> CanonicalPath {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = resolutions[expanded] ?? (expanded as NSString).standardizingPath
        return CanonicalPath(path: resolved, exists: existing.contains(resolved))
    }

    func probe(_ path: String) -> RootState { .reachable }
    func indexState(scopes: [String]) async -> IndexState { .responding }

    func search(_ query: SpotlightQuery) async throws -> SearchPage {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }
}

/// The safety property this whole server exists for: a path outside the configured roots
/// must never resolve, however it is spelled.
@Suite("Path scope")
struct PathScopeTests {

    private func scope(
        read: [String] = ["/Users/invented/Documents", "/Users/invented/Code"],
        resolutions: [String: String] = [:]
    ) -> PathScope {
        var configuration = Configuration()
        configuration.readRoots = read
        return PathScope(configuration: configuration, store: StubStore(resolutions: resolutions))
    }

    @Test("A path inside a read root resolves")
    func insideReadRootResolves() throws {
        let resolved = try scope().resolve("/Users/invented/Documents/notes.md")
        #expect(resolved.path == "/Users/invented/Documents/notes.md")
    }

    @Test("A read root itself resolves")
    func rootItselfResolves() throws {
        let resolved = try scope().resolve("/Users/invented/Documents")
        #expect(resolved.path == "/Users/invented/Documents")
    }

    @Test("A path outside every read root is refused")
    func outsideReadRootIsRefused() {
        #expect(throws: ToolError.self) {
            try scope().resolve("/Users/invented/Library/Keychains")
        }
    }

    /// The reason canonicalisation happens before comparison. Compared raw, this string
    /// starts with a read root and would pass a prefix test while landing in the home
    /// directory.
    @Test("Dot-dot cannot climb out of a read root")
    func dotDotCannotEscape() {
        #expect(throws: ToolError.self) {
            try scope().resolve("/Users/invented/Documents/../../../etc/passwd")
        }
    }

    /// The other half of the same rule. A symlink inside an allowed root that points
    /// somewhere else entirely must be judged by where it lands, not by its own path.
    @Test("A symlink pointing out of the scope is judged by where it lands")
    func symlinkOutOfScopeIsRefused() {
        let escaping = scope(resolutions: [
            "/Users/invented/Documents/shortcut": "/Users/invented/Library/Secrets"
        ])
        #expect(throws: ToolError.self) {
            try escaping.resolve("/Users/invented/Documents/shortcut")
        }
    }

    /// `/tmp` is a symlink to `/private/tmp` on macOS, so a root compared in its raw form
    /// would reject every path that resolved through it. The roots are canonicalised too.
    @Test("A root that is itself a symlink still governs its subtree")
    func symlinkedRootStillGoverns() throws {
        var configuration = Configuration()
        configuration.readRoots = ["/tmp/invented"]
        let store = StubStore(resolutions: [
            "/tmp/invented": "/private/tmp/invented",
            "/tmp/invented/file.txt": "/private/tmp/invented/file.txt",
        ])
        let pathScope = PathScope(configuration: configuration, store: store)

        let resolved = try pathScope.resolve("/tmp/invented/file.txt")
        #expect(resolved.path == "/private/tmp/invented/file.txt")
    }

    /// A sibling whose name merely begins with a root's name is not inside it.
    @Test("A prefix match on the name alone is not containment")
    func siblingWithSharedPrefixIsRefused() {
        #expect(throws: ToolError.self) {
            try scope().resolve("/Users/invented/Documents-private/secret")
        }
    }

    @Test("With no read roots nothing resolves at all")
    func noReadRootsRefusesEverything() {
        let empty = scope(read: [])
        #expect(throws: ToolError.self) { try empty.resolve("/Users/invented") }
    }

    @Test("An empty path is refused")
    func emptyPathIsRefused() {
        #expect(throws: ToolError.self) { try scope().resolve("   ") }
    }
}
