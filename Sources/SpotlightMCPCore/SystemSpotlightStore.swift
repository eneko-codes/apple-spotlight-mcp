import Foundation

/// The only file in this repository that touches the real disk.
///
/// Everything above the `SpotlightStore` seam is proven against an in-memory scope. This
/// is the part that cannot be, so it is kept as thin as it can be: no policy, no
/// formatting, no decisions about what is allowed — those all happen above, and by the
/// time a `ScopedPath` reaches any method here it has already passed the allow-list.
public struct SystemSpotlightStore: SpotlightStore {

    /// Computed rather than stored: `FileManager` is not `Sendable`, so it cannot be
    /// held by a type that is. The shared instance is the only one documented as safe
    /// to use from several threads, and nothing here ever wanted a different one.
    private var fileManager: FileManager { .default }

    public init() {}

    // MARK: - Resolution

    /// Expands `~`, standardises away `.` and `..`, and resolves every symlink.
    ///
    /// A missing leaf is normal enough to tolerate — the same resolution the sibling
    /// filesystem server uses — so it walks up to the deepest ancestor that does exist,
    /// canonicalises that, and re-appends the components below it. Canonicalising only
    /// what exists is what stops a symlinked parent from hiding the real destination
    /// from the scope check.
    public func canonicalise(_ path: String) throws -> CanonicalPath {
        let expanded = (path as NSString).expandingTildeInPath
        // A relative path has no meaning here: the process's working directory is
        // whatever Claude Desktop happened to spawn it in, which is nobody's intent.
        guard expanded.hasPrefix("/") else {
            throw ToolError.badArgument(
                name: "path",
                reason: "'\(path)' is not absolute. Give a full path, or one starting with ~")
        }

        let standardised = URL(fileURLWithPath: expanded).standardizedFileURL
        if fileManager.fileExists(atPath: standardised.path) {
            return CanonicalPath(path: standardised.resolvingSymlinksInPath().path, exists: true)
        }

        var missing: [String] = []
        var ancestor = standardised
        while ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor = ancestor.deletingLastPathComponent()
            if fileManager.fileExists(atPath: ancestor.path) {
                let resolved = missing.reversed().reduce(ancestor.resolvingSymlinksInPath()) {
                    $0.appendingPathComponent($1)
                }
                return CanonicalPath(path: resolved.path, exists: false)
            }
        }
        return CanonicalPath(path: standardised.path, exists: false)
    }

    // MARK: - Status

    public func probe(_ path: String) -> RootState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else {
            return fileManager.isReadableFile(atPath: path) ? .reachable : .notPermitted
        }
        // The only honest test of a TCC-protected folder is to open it: the path exists
        // and is perfectly visible, and the refusal only arrives on the first read.
        do {
            _ = try fileManager.contentsOfDirectory(atPath: path)
            return .reachable
        } catch {
            return Self.isPermissionError(error) ? .notPermitted : .missing
        }
    }

    public func indexState(scopes: [String]) async -> IndexState {
        // Matches anything with a name, which is everything Spotlight has. The question
        // is whether the index answers for these folders at all, not what is in them.
        let outcome = await SpotlightRunner.gather(
            predicate: NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*"),
            scopes: scopes, sortDescriptors: [], offset: 0, limit: 1, deadline: 3.0)
        if outcome.timedOut { return .timedOut }
        return outcome.total > 0 ? .responding : .empty
    }

    // MARK: - Reads

    public func search(_ query: SpotlightQuery) async throws -> SearchPage {
        var clauses: [NSPredicate] = []
        if let name = query.nameContains {
            clauses.append(NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, name))
        }
        if let text = query.textContains {
            clauses.append(
                NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemTextContentKey, text))
        }
        if let kind = query.kind {
            clauses.append(NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemKindKey, kind))
        }
        if let type = query.contentType {
            // The type *tree* rather than the exact type, so "public.image" matches a PNG
            // and a HEIC. There is no NSMetadataItem constant for it; the raw Spotlight
            // attribute name is the API.
            clauses.append(NSPredicate(format: "kMDItemContentTypeTree == %@", type))
        }
        if let tag = query.tag {
            clauses.append(NSPredicate(format: "kMDItemUserTags == %@", tag))
        }
        if let after = query.modifiedAfter {
            clauses.append(
                NSPredicate(
                    format: "%K >= %@", NSMetadataItemFSContentChangeDateKey, after as NSDate))
        }
        if let before = query.modifiedBefore {
            clauses.append(
                NSPredicate(
                    format: "%K < %@", NSMetadataItemFSContentChangeDateKey, before as NSDate))
        }
        if let minimum = query.minimumSizeBytes {
            clauses.append(
                NSPredicate(format: "%K >= %ld", NSMetadataItemFSSizeKey, minimum))
        }
        if let maximum = query.maximumSizeBytes {
            clauses.append(
                NSPredicate(format: "%K <= %ld", NSMetadataItemFSSizeKey, maximum))
        }

        let outcome = await SpotlightRunner.gather(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: clauses),
            scopes: query.scopes,
            sortDescriptors: [
                NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)
            ],
            offset: query.offset, limit: query.limit, deadline: 20.0)

        return SearchPage(results: outcome.rows, total: outcome.total)
    }

    // MARK: - Helpers

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileReadNoPermissionError
                || nsError.code == NSFileWriteNoPermissionError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        return false
    }
}
