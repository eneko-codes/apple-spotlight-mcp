import Foundation

/// The limits of the MCP tool standard this server follows, and the helpers that keep a
/// tool inside them.
///
/// A server cannot tell which client is calling, and each client moves a large result out
/// of the conversation at a different size. So the server bounds what it returns, and says
/// in one fixed wording what it left out. This file is the same in every server, like
/// `MCPServer.swift` and `Value.swift`.
public enum ToolStandard {

    /// The longest text one result may hold, counted in UTF-16 code units, the way a
    /// JavaScript client measures a string. It sits below the smallest size at which a
    /// Claude client stops passing a result into the conversation.
    public static let longestResult = 40_000

    /// What a call with no optional argument aims to return, in characters.
    public static let usualPage = 10_000

    /// The longest server instructions and the longest tool description. A client cuts
    /// longer text, and the model reads only what comes before the cut.
    public static let longestDescription = 4_000

    /// The longest error text.
    public static let longestError = 10_000

    /// The longest a call may take to answer.
    public static let timeLimit = Duration.seconds(200)

    /// Moves `asked` into `range`. When that changes it, a notice saying which value was
    /// used is added to `notices`, so no argument is ever adjusted silently.
    public static func clamp(
        _ asked: Int, to range: ClosedRange<Int>, argument: String, notices: inout [String]
    ) -> Int {
        let used = Swift.min(Swift.max(asked, range.lowerBound), range.upperBound)
        if used != asked {
            notices.append(Notice.adjusted(argument: argument, asked: asked, range: range, used: used))
        }
        return used
    }

    /// The part of `text` that starts `characterOffset` characters in and holds at most
    /// `maxCharacters`, with the notice that says where it sits in the whole. The notice is
    /// `nil` when the window is the whole text. Characters are Swift's, so a window never
    /// splits one, and the next window starts exactly where this one ended. `label` names
    /// the text in the notice when the result holds more than that text.
    public static func window(
        of text: String, characterOffset: Int, maxCharacters: Int, label: String? = nil
    ) -> (text: String, notice: String?) {
        let total = text.count
        let asked = Swift.max(characterOffset, 0)
        let start = text.index(text.startIndex, offsetBy: Swift.min(asked, total))
        let end = text.index(start, offsetBy: Swift.max(maxCharacters, 0), limitedBy: text.endIndex) ?? text.endIndex
        let part = String(text[start..<end])
        return (part, Notice.window(offset: asked, count: part.count, total: total, label: label))
    }

    /// What a result left out goes first: one sentence a line, a blank line, then the data.
    public static func withNotices(_ notices: [String], _ text: String) -> String {
        notices.isEmpty ? text : notices.joined(separator: "\n") + "\n\n" + text
    }

    /// Renders `size` rows or characters and, while the text is longer than a result may
    /// be, halves `size` and renders again.
    ///
    /// A tool's maximum is chosen so that ordinary rows fit without this. It is here for
    /// what no maximum can foresee (one row far wider than the rest, a text whose characters
    /// take several UTF-16 units each), so that such a result holds less and says where to
    /// resume, and never reaches the guard to be cut. `render` builds its notice from what
    /// it rendered, so the notice stays true.
    public static func fitting(_ size: Int, render: (Int) -> String) -> String {
        var size = size
        var text = render(size)
        while text.utf16.count > longestResult, size > 1 {
            size /= 2
            text = render(size)
        }
        return text
    }

    /// One page of `rows`: the notices, the sentence that places the page in the whole when
    /// it is not the whole, then what `render` makes of the rows on the page. `rows` is
    /// every matching row, already in the order the tool states.
    public static func page<Row>(
        of rows: [Row], limit: Int, offset: Int, things: String, notices: [String],
        render: ([Row]) -> String
    ) -> String {
        fitting(limit) { size in
            let page = Array(rows.dropFirst(offset).prefix(size))
            let position = Notice.page(offset: offset, count: page.count, total: rows.count, things: things)
            return withNotices(notices + [position].compactMap { $0 }, render(page))
        }
    }

    /// How much of a caller's own text an error may repeat.
    public static let echoWidth = 80

    /// `text` as an error may repeat it: at most `echoWidth` characters.
    public static func echo(_ text: String) -> String {
        text.count > echoWidth ? String(text.prefix(echoWidth)) + "…" : text
    }

    /// The names of the texts a client would cut: the instructions and each tool
    /// description longer than `longestDescription`. A server's tests expect it empty.
    public static func overlongTexts(instructions: String, catalog: [Tool]) -> [String] {
        var names: [String] = []
        if instructions.utf16.count > longestDescription { names.append("instructions") }
        for tool in catalog where (tool.description ?? "").utf16.count > longestDescription {
            names.append(tool.name)
        }
        return names
    }
}

/// The sentences that tell the model what a result does not hold. They go before the data,
/// in the text of the result, and read the same in every server.
public enum Notice {

    /// For a page of rows. `total` is `nil` when the server knows only that more exist.
    /// Returns `nil` for a result that starts at the beginning and holds everything.
    public static func page(offset: Int, count: Int, total: Int?, things: String) -> String? {
        let last = offset + count
        guard let total else {
            return "Showing \(offset + 1)–\(last) \(things); more exist. Pass offset=\(last) for the next page."
        }
        guard offset > 0 || last < total else { return nil }
        guard count > 0 else {
            return "Showing 0 of \(total) \(things): offset=\(offset) is past the end. That is all."
        }
        let shown = "Showing \(offset + 1)–\(last) of \(total) \(things)."
        return last < total ? "\(shown) Pass offset=\(last) for the next page." : "\(shown) That is all."
    }

    /// For a window of one long text. Returns `nil` when the window is the whole text.
    /// `label` names the text when the result holds more than that text.
    public static func window(offset: Int, count: Int, total: Int, label: String? = nil) -> String? {
        let last = offset + count
        guard offset > 0 || last < total else { return nil }
        let characters = label.map { "\($0): characters" } ?? "Characters"
        guard count > 0 else {
            return "\(characters) 0 of \(total): character_offset=\(offset) is past the end. That is all."
        }
        let shown = "\(characters) \(offset + 1)–\(last) of \(total)."
        return last < total ? "\(shown) Pass character_offset=\(last) for the rest." : "\(shown) That is all."
    }

    /// For rows a tool holds back unless asked, such as hidden or inactive ones.
    /// `argument` is what to pass, written as it would be passed: `include_hidden=true`.
    public static func notShown(count: Int, things: String, pass argument: String) -> String {
        "\(count) \(things) are not shown. Pass \(argument) to include them."
    }

    /// For a long field shortened inside each row. `tool` reads one item in full.
    public static func clipped(field: String, width: Int, tool: String) -> String {
        "\(field) is clipped to \(width) characters in each row. Read one in full with \(tool)."
    }

    /// For a search that stopped before it had looked at everything.
    public static func scanStopped(after count: Int, things: String, narrowBy argument: String) -> String {
        "The scan stopped after \(count) \(things); more may exist. Narrow by \(argument)."
    }

    /// For a call that reached its deadline and returns what it had.
    public static func partial(after count: Int, things: String, narrowBy argument: String) -> String {
        "Partial: the time limit was reached after \(count) \(things). Narrow by \(argument)."
    }

    /// For a number moved into its range.
    public static func adjusted(argument: String, asked: Int, range: ClosedRange<Int>, used: Int) -> String {
        "\(argument)=\(asked) is outside \(range.lowerBound)–\(range.upperBound); \(used) was used."
    }

    /// For a result the guard had to cut.
    public static func cut(limit: Int, total: Int) -> String {
        "Cut at \(limit) of \(total) characters. Narrow the call."
    }
}

extension ToolOutput {

    /// The guard behind every tool: the one point each result passes through.
    ///
    /// A tool keeps its own result inside the limit and says how to get the rest. This only
    /// catches the one that forgot, so that no result can leave the server too long for a
    /// client to pass on. The text is cut at the last line break inside the limit, or at the
    /// limit when it has none, and a notice goes first. Text after the cut is dropped;
    /// images are kept.
    public func withinTheStandard() -> ToolOutput {
        let limit = isError ? ToolStandard.longestError : ToolStandard.longestResult
        let total = content.reduce(0) { sum, block in
            if case .text(let text) = block { return sum + text.utf16.count }
            return sum
        }
        guard total > limit else { return self }

        let notice = Notice.cut(limit: limit, total: total)
        var room = limit - notice.utf16.count
        var kept: [Block] = [.text(notice)]
        for block in content {
            guard case .text(let text) = block else {
                kept.append(block)
                continue
            }
            guard room > 0 else { continue }
            if text.utf16.count <= room {
                kept.append(block)
                room -= text.utf16.count
            } else {
                kept.append(.text(Self.cut(text, to: room)))
                room = 0
            }
        }
        return ToolOutput(content: kept, isError: isError)
    }

    /// At most `room` UTF-16 code units of `text`, ending at its last line break when it has
    /// one. A cut that would land inside a surrogate pair moves back one unit.
    private static func cut(_ text: String, to room: Int) -> String {
        let units = text.utf16
        var head = String(units.prefix(room)) ?? String(units.prefix(room - 1)) ?? ""
        if let lineBreak = head.lastIndex(of: "\n") { head = String(head[..<lineBreak]) }
        return head
    }
}
