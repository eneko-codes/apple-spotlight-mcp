import Foundation

/// Value types crossing the store seam. Nothing here imports a filesystem or Spotlight
/// API, which is what lets the tests build a scope in memory.

// MARK: - Paths

/// The result of canonicalising a raw path string, before any scope check.
public struct CanonicalPath: Sendable, Equatable {
    public let path: String
    public let exists: Bool

    public init(path: String, exists: Bool) {
        self.path = path
        self.exists = exists
    }
}

// `ScopedPath` deliberately lives in PathScope.swift instead: its initialiser is
// fileprivate, so that file is the only place in the module able to mint one.

// MARK: - Spotlight

/// Every filter mirrors a Spotlight attribute. Nothing here is computed: if the index
/// does not store it, it is not a filter.
public struct SpotlightQuery: Sendable, Equatable {
    public var nameContains: String?
    public var textContains: String?
    /// `kMDItemKind`, the localised description Finder shows ("PDF Document").
    public var kind: String?
    /// A UTI matched against `kMDItemContentTypeTree`, so `public.image` finds a PNG.
    public var contentType: String?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var minimumSizeBytes: Int?
    public var maximumSizeBytes: Int?
    public var tag: String?
    /// Folders to search within. Always non-empty by the time it reaches the store: the
    /// read roots are substituted when the caller names none, so a query can never
    /// widen to the whole disk.
    public var scopes: [String] = []
    public var limit: Int = 50
    public var offset: Int = 0

    public init() {}

    public var isEmpty: Bool {
        nameContains == nil && textContains == nil && kind == nil && contentType == nil
            && modifiedAfter == nil && modifiedBefore == nil && minimumSizeBytes == nil
            && maximumSizeBytes == nil && tag == nil
    }
}

public struct SearchHit: Sendable, Equatable {
    public let path: String
    public let name: String
    public let sizeBytes: Int
    public let modifiedAt: Date?
    public let kindDescription: String?

    public init(
        path: String, name: String, sizeBytes: Int, modifiedAt: Date?, kindDescription: String?
    ) {
        self.path = path
        self.name = name
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.kindDescription = kindDescription
    }
}

public struct SearchPage: Sendable, Equatable {
    public let results: [SearchHit]
    public let total: Int

    public init(results: [SearchHit], total: Int) {
        self.results = results
        self.total = total
    }
}

// MARK: - Status

/// What one configured root is actually worth right now. There is no API that asks TCC
/// "may I read this folder?", so the only honest answer comes from trying.
public enum RootState: String, Sendable, Equatable {
    case reachable
    case missing
    /// The path is there and macOS refused. This is the TCC denial, and the one the
    /// status message has to explain how to fix.
    case notPermitted
}

public struct RootProbe: Sendable, Equatable {
    public let path: String
    public let state: RootState
    /// Set when the configured root does not canonicalise to itself — a symlinked root
    /// silently governs a different subtree than the one that was typed.
    public let canonicalPath: String?

    public init(path: String, state: RootState, canonicalPath: String? = nil) {
        self.path = path
        self.state = state
        self.canonicalPath = canonicalPath
    }
}

/// Result of a bounded probe query against Spotlight. `spotlight_search` is worthless
/// where the index is off, and the failure mode is an empty result set that looks like
/// "no matches", so it is measured rather than assumed.
public enum IndexState: String, Sendable, Equatable {
    case responding
    case empty
    case timedOut
}
