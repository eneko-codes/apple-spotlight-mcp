import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    /// Binary units, because that is what the Finder's Get Info shows for a file and a
    /// mismatch between the two is the kind of thing that costs half an hour.
    public static func bytes(_ count: Int) -> String {
        guard count >= 1024 else { return "\(count) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(count) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }

    /// Collapses a multi-line value onto one line, so the one-row-per-file contract that
    /// makes a listing scannable survives a filename containing a newline — which is
    /// legal on APFS and does happen.
    static func oneLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Search

    public func searchResults(_ page: SearchPage, query: SpotlightQuery) -> String {
        var header = "Spotlight: \(page.total) match\(page.total == 1 ? "" : "es")"
        if page.results.count < page.total {
            header += ", showing \(query.offset + 1)–\(query.offset + page.results.count)"
        }
        header += "\n  scope: " + query.scopes.joined(separator: ", ")

        guard !page.results.isEmpty else {
            return header + """


                  (no matches)

                  Spotlight answers from its index, so a file it has not indexed is
                  invisible here however plainly it exists.
                """
        }

        let rows = page.results.map { hit -> String in
            var row = "  " + Self.oneLine(hit.path)
            var facts = [Self.bytes(hit.sizeBytes)]
            if let modified = hit.modifiedAt {
                facts.append(DateParsing.timestamp(modified, calendar: calendar))
            }
            if let kind = hit.kindDescription { facts.append(kind) }
            row += "\n      " + facts.joined(separator: " · ")
            return row
        }
        var text = ([header, ""] + rows).joined(separator: "\n")
        if page.results.count < page.total {
            text += "\n\n  \(page.total - query.offset - page.results.count) more — page with 'offset'."
        }
        return text
    }

    // MARK: Status

    public func status(
        probes: [RootProbe], indexState: IndexState, binaryPath: String,
        configuration: Configuration
    ) -> String {
        let headline =
            probes.isEmpty
            ? "Spotlight scope: NOTHING configured — this server can see no files."
            : "Spotlight scope: \(probes.count) read root(s)."

        var text = headline + "\n\n"
        text += Self.block([
            ("binary", binaryPath),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("time zone", calendar.timeZone.identifier),
            ("search limit", "\(configuration.searchLimit)"),
            ("spotlight", indexState.rawValue),
        ])

        text += "\n\nReadable folders:\n"
        if probes.isEmpty {
            text += "  (none configured — nothing is reachable)"
        } else {
            text += probes.map { probe in
                var line = "  \(probe.path) — \(probe.state.rawValue)"
                if let canonical = probe.canonicalPath { line += "\n      resolves to \(canonical)" }
                return line
            }.joined(separator: "\n")
        }

        if probes.contains(where: { $0.state == .notPermitted }) {
            text += """


                One or more roots are configured but macOS refuses them. That is a system
                permission, not this server's allow-list:
                  System Settings → Privacy & Security → Files and Folders → enable the folders
                  under "apple-spotlight-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Archivos y carpetas)
                Anywhere outside Desktop, Documents and Downloads needs Full Disk Access
                instead, which is granted by hand and never prompts.
                """
        }

        if indexState != .responding {
            text += """


                Spotlight returned nothing for these folders (\(indexState.rawValue)), so
                spotlight_search may be blind here — an unindexed volume or one excluded
                in Spotlight's privacy list looks exactly like "no matches".
                """
        }
        return text
    }
}
