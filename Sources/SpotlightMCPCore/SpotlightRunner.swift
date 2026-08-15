import Foundation

/// Runs one `NSMetadataQuery` and returns its results.
///
/// `NSMetadataQuery` is a live, notification-driven object: it must be started on a
/// run loop, it keeps updating after the first pass, and it never guarantees it will
/// finish. None of that suits a request/response tool, so this wraps one query into a
/// single `await` that either returns a page or reports that it gave up.
///
/// Sits below the `SpotlightStore` seam. Nothing here is reachable from the tool tests,
/// which is why it does as little as possible: build the query, wait for the gathering
/// pass, read the rows, stop.
enum SpotlightRunner {

    struct Outcome: Sendable {
        let rows: [SearchHit]
        /// Matches found in total, which can exceed `rows.count` when a page was asked
        /// for. It is what lets a truncated answer say what it withheld.
        let total: Int
        /// True when the deadline passed before Spotlight finished gathering. The rows
        /// are then whatever had arrived, and the caller must say so rather than
        /// presenting a partial answer as complete.
        let timedOut: Bool
    }

    /// - Parameter deadline: seconds to wait for the gathering pass. Spotlight can stall
    ///   indefinitely on an unindexed or network volume, and a tool call that never
    ///   returns is worse than one that admits it timed out.
    static func gather(
        predicate: NSPredicate,
        scopes: [String],
        sortDescriptors: [NSSortDescriptor],
        offset: Int,
        limit: Int,
        deadline: TimeInterval
    ) async -> Outcome {
        // NSPredicate and NSSortDescriptor are not Sendable, and both have to cross onto
        // the main queue below. They are safe to hand over here because the caller builds
        // them, passes them in and never touches them again — this function is the only
        // owner from now on. The compiler cannot see that, hence the annotation.
        nonisolated(unsafe) let predicate = predicate
        nonisolated(unsafe) let sortDescriptors = sortDescriptors

        return await withCheckedContinuation { continuation in
            // The query and its observer are driven from the main run loop because
            // NSMetadataQuery posts its notifications there and does nothing at all
            // without one running.
            DispatchQueue.main.async {
                let query = NSMetadataQuery()
                query.predicate = predicate
                query.sortDescriptors = sortDescriptors
                query.searchScopes = scopes.map { URL(fileURLWithPath: $0) }
                // The results are read once, in a single pass. Live updates would mean
                // rows changing under a caller that has already been handed an answer.
                query.enableUpdates()

                // Guards the continuation: the deadline and the finish notification race,
                // and resuming a continuation twice is a crash rather than a warning.
                let finished = Finished()

                var observer: (any NSObjectProtocol)?

                func complete(timedOut: Bool) {
                    guard finished.claim() else { return }
                    if let observer { NotificationCenter.default.removeObserver(observer) }
                    query.stop()

                    let total = query.resultCount
                    var rows: [SearchHit] = []
                    if limit > 0, offset < total {
                        for index in offset..<min(offset + limit, total) {
                            guard let item = query.result(at: index) as? NSMetadataItem else {
                                continue
                            }
                            rows.append(hit(from: item))
                        }
                    }
                    continuation.resume(
                        returning: Outcome(rows: rows, total: total, timedOut: timedOut))
                }

                observer = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
                ) { _ in complete(timedOut: false) }

                DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
                    complete(timedOut: true)
                }

                guard query.start() else { return complete(timedOut: false) }
            }
        }
    }

    /// Reads the five attributes a search result reports. Anything more belongs to a
    /// stat-style tool over one path, which is a different server's job.
    private static func hit(from item: NSMetadataItem) -> SearchHit {
        let path = item.value(forAttribute: NSMetadataItemPathKey) as? String ?? ""
        return SearchHit(
            path: path,
            name: item.value(forAttribute: NSMetadataItemFSNameKey) as? String
                ?? (path as NSString).lastPathComponent,
            sizeBytes: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.intValue
                ?? 0,
            modifiedAt: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
            kindDescription: item.value(forAttribute: NSMetadataItemKindKey) as? String)
    }
}

/// One-shot latch. Everything touching it runs on the main queue, so a plain `Bool` is
/// enough and a lock would only obscure that.
private final class Finished {
    private var done = false

    func claim() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if done { return false }
        done = true
        return true
    }
}
