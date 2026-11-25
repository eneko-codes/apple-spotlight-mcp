import Foundation

public enum ToolError: Error, Equatable {
    case noReadRootsConfigured
    case pathOutOfScope(requested: String, resolved: String, readRoots: [String])
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case nonexistentDate(argument: String, value: String)
    case rangeEndsBeforeItStarts(from: String, to: String)
    case unknownArguments([String], allowed: [String])
    case unknownTool(String)
    case timedOut(seconds: Int)
    case emptySearch
    case permissionDenied(path: String, detail: String)
    case storeFailure(String)

    public var message: String {
        switch self {
        case .noReadRootsConfigured:
            return """
                This server has no read roots configured, so it can see nothing at all.

                That is the safe default, not a fault: an unconfigured server would
                otherwise start with the whole disk in reach. Name the folders Claude
                may search inside in:
                  Claude Desktop → Settings → Extensions → Spotlight → Folders Claude may read

                Nothing outside that list can be found or read.
                """

        case .pathOutOfScope(let requested, let resolved, let readRoots):
            // A few of the roots and the count of the rest: the list is the person's own
            // configuration and may be long.
            let scope =
                readRoots.isEmpty
                ? "(none configured)"
                : readRoots.prefix(5).joined(separator: ", ")
                    + (readRoots.count > 5 ? " and \(readRoots.count - 5) more" : "")
            let resolution =
                resolved == requested
                ? "" : "\n\nIt resolves to:\n  \(ToolStandard.echo(resolved))\n(symlinks and .. are followed before the check, always)."
            return """
                Path '\(ToolStandard.echo(requested))' is outside the scope this extension was configured with.\
                \(resolution)

                Readable folders: \(scope)

                This is not something to work around: the person installing the extension
                chose those folders in its settings, deliberately keeping everything else
                out of reach. Change them in Claude Desktop → Settings → Extensions.
                """

        case .missingArgument(let name):
            return "Missing required argument '\(ToolStandard.echo(name))'."

        case .badArgument(let name, let reason):
            return "Argument '\(ToolStandard.echo(name))' is not valid: \(reason)"

        case .unknownArguments(let names, let allowed):
            let shown = names.prefix(3).map { "'\(ToolStandard.echo($0))'" }.joined(separator: ", ")
            let others = names.count > 3 ? " and \(names.count - 3) more" : ""
            let list = allowed.isEmpty ? "none: this tool takes no arguments" : allowed.joined(separator: ", ")
            return """
                Not an argument of this tool: \(shown)\(others). Nothing was run.

                Allowed arguments: \(list)
                """

        case .unknownTool(let name):
            return "'\(ToolStandard.echo(name))' is not a tool of this server."

        case .timedOut(let seconds):
            return """
                The call did not finish within \(seconds) seconds and was abandoned. This \
                server only reads, so nothing was changed.

                Narrow the search with another filter or a smaller folder, then try again. \
                spotlight_status says whether Spotlight is answering at all.
                """

        case .nonexistentDate(let argument, let value):
            return """
                Argument '\(argument)' names a day or a time that does not exist: \
                '\(ToolStandard.echo(value))'

                Check the day of the month, and that the time is not one the clocks skip when \
                they go forward. Nothing was moved to a nearby date.
                """

        case .rangeEndsBeforeItStarts(let from, let to):
            return """
                The range ends before it starts: \(from) is after \(to). Pass a range that \
                starts before it ends, for example from_date=2026-08-01 and to_date=2026-08-31; \
                both days are included.
                """

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: '\(ToolStandard.echo(value))'

                Use one of:
                \(DateParsing.acceptedForms)
                """

        case .emptySearch:
            return """
                spotlight_search was given no filter, so it would return every indexed
                file in scope in arbitrary order.

                Pass at least one of: name_contains, text_contains, kind, content_type,
                tag, from_date, to_date, min_size, max_size.
                """

        case .permissionDenied(let path, let detail):
            return """
                macOS refused access to '\(ToolStandard.echo(path))': \(ToolStandard.echo(detail))

                The path is inside the configured scope, so this is a system permission,
                not this server's allow-list. Two different grants can be missing:

                For Desktop, Documents or Downloads:
                  System Settings → Privacy & Security → Files and Folders → enable the folder
                  under "apple-spotlight-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Archivos y carpetas)

                For anywhere else — iCloud Drive, an external disk, another user's folder:
                  System Settings → Privacy & Security → Full Disk Access → add and enable
                  "apple-spotlight-mcp"
                  (Spanish UI: Privacidad y seguridad → Acceso total al disco)

                Then restart Claude Desktop: the permission is resolved when the process
                starts. Full Disk Access has no consent dialog — it is never requested,
                only granted by hand.
                """

        case .storeFailure(let detail):
            return "Spotlight returned an error: \(ToolStandard.echo(detail))"
        }
    }
}
