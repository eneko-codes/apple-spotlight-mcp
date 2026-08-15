import Foundation

/// A canonical path — `~` expanded, `..` removed, every symlink resolved — that has
/// already been checked against the allow-list.
///
/// The initialiser is `fileprivate`, so the only code in the whole module that can mint
/// one is `PathScope` below. A store method therefore cannot be reached with a path
/// nobody vetted: forgetting the check is a compile error rather than an escape, and the
/// tests cannot skip past the guard either.
public struct ScopedPath: Sendable, Equatable, Hashable {
    public let path: String
    /// Whether the leaf existed at the moment it was resolved.
    public let exists: Bool

    fileprivate init(path: String, exists: Bool) {
        self.path = path
        self.exists = exists
    }
}

/// The allow-list, enforced. This server only ever reads, so there is one list rather
/// than the read/write pair `apple-filesystem-mcp` carries.
///
/// This is the whole point of the server, so it is one small file with one exported
/// operation: turn a string the model wrote into a `ScopedPath`, or refuse. Because
/// `ScopedPath`'s initialiser is fileprivate to *this* file, no other code in the module
/// can fabricate one — a store method that takes a path can only ever be handed a path
/// that came through here.
///
/// The order matters and is not negotiable: **canonicalise first, then compare.**
/// Comparing the raw string would let `~/Documents/../../../etc` and a symlink pointing
/// out of the tree both pass a prefix test while landing somewhere else entirely.
public struct PathScope: Sendable {
    private let store: any SpotlightStore
    /// Roots as configured, kept for error messages: the person recognises what they
    /// typed, not its canonical form.
    private let configuredReadRoots: [String]
    /// The same roots canonicalised once, which is what every containment test uses.
    /// `/tmp` is a symlink to `/private/tmp` on macOS, so a root compared raw would
    /// reject every path resolved through it.
    private let readRoots: [String]

    public init(configuration: Configuration, store: any SpotlightStore) {
        self.store = store
        self.configuredReadRoots = configuration.readRoots
        self.readRoots = configuration.readRoots.compactMap {
            Self.canonicalRoot($0, store: store)
        }
    }

    /// A root that cannot be canonicalised is dropped rather than kept raw. Keeping it
    /// would mean comparing against a string no real path can ever match, which reads as
    /// a scope that exists and silently governs nothing.
    private static func canonicalRoot(_ path: String, store: any SpotlightStore) -> String? {
        guard let canonical = try? store.canonicalise(path) else { return nil }
        return normalise(canonical.path)
    }

    /// Drops a trailing slash so `/Users/x/Docs/` and `/Users/x/Docs` are one root. The
    /// filesystem root itself keeps its slash — there is nothing left to drop.
    private static func normalise(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// True when `candidate` is the root itself or lies underneath it.
    ///
    /// The separator in the prefix is what stops `/Users/eneko/Documents-old` from
    /// matching the root `/Users/eneko/Documents`. A bare `hasPrefix` is the classic way
    /// this check is got wrong.
    static func contains(root: String, candidate: String) -> Bool {
        if candidate == root { return true }
        let boundary = root.hasSuffix("/") ? root : root + "/"
        return candidate.hasPrefix(boundary)
    }

    public var hasReadRoots: Bool { !readRoots.isEmpty }

    /// The canonical read roots, for substituting into a search that named no folder.
    public var searchScopes: [String] { readRoots }

    /// Canonicalise, then check. The only door to a `ScopedPath`.
    public func resolve(_ raw: String) throws -> ScopedPath {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: "path", reason: "it is empty")
        }
        guard hasReadRoots else { throw ToolError.noReadRootsConfigured }

        let canonical = try store.canonicalise(trimmed)
        let path = Self.normalise(canonical.path)

        guard readRoots.contains(where: { Self.contains(root: $0, candidate: path) }) else {
            throw ToolError.pathOutOfScope(
                requested: trimmed, resolved: path, readRoots: configuredReadRoots)
        }
        return ScopedPath(path: path, exists: canonical.exists)
    }

    /// Probes every configured root, for `spotlight_status`. The canonical form is
    /// carried alongside when it differs, because a symlinked root governs a subtree
    /// nobody typed and that is worth seeing before it surprises someone.
    public func probeRoots() -> [RootProbe] {
        configuredReadRoots.map { raw in
            let canonical = (try? store.canonicalise(raw)).map { Self.normalise($0.path) }
            return RootProbe(
                path: raw, state: store.probe(canonical ?? raw),
                canonicalPath: canonical == raw ? nil : canonical)
        }
    }
}
