import Foundation

/// The seam between the tool layer and the real disk.
///
/// Everything above this protocol is exercised by the tests against an in-memory scope;
/// everything below it can only be verified against real files and a live Spotlight
/// index. Keeping the boundary this thin is what makes the untested surface small
/// enough to check by hand.
///
/// Every path-taking method takes a `ScopedPath`, which cannot be constructed without
/// passing the allow-list check. `canonicalise` is the one exception: it is the step
/// that *feeds* the check, and it reads nothing but the shape of the path.
public protocol SpotlightStore: Sendable {

    // MARK: Resolution

    /// Expands `~`, removes `.`/`..`, and resolves every symlink in the path.
    func canonicalise(_ path: String) throws -> CanonicalPath

    // MARK: Status

    /// Whether the root is there and this process may actually look inside it.
    func probe(_ path: String) -> RootState

    /// Bounded probe of the Spotlight index over the given scopes.
    func indexState(scopes: [String]) async -> IndexState

    // MARK: Reads

    func search(_ query: SpotlightQuery) async throws -> SearchPage
}
