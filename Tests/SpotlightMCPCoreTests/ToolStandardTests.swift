import Foundation
import Testing

@testable import SpotlightMCPCore

/// The copied tool-standard file (`ToolStandard.swift`): its notices, its helpers and the
/// guard in the protocol layer. It is the same file in every server except for the import.
@Suite("Tool standard")
struct ToolStandardTests {

    @Test("A page notice names what is shown, the total and the next call")
    func pageNotice() {
        #expect(Notice.page(offset: 0, count: 50, total: 50, things: "messages") == nil)
        #expect(
            Notice.page(offset: 0, count: 50, total: 312, things: "messages")
                == "Showing 1–50 of 312 messages. Pass offset=50 for the next page.")
        #expect(
            Notice.page(offset: 300, count: 12, total: 312, things: "messages")
                == "Showing 301–312 of 312 messages. That is all.")
        #expect(
            Notice.page(offset: 400, count: 0, total: 312, things: "messages")
                == "Showing 0 of 312 messages: offset=400 is past the end. That is all.")
        #expect(
            Notice.page(offset: 50, count: 50, total: nil, things: "rows")
                == "Showing 51–100 rows; more exist. Pass offset=100 for the next page.")
        #expect(
            Notice.page(offset: 900, count: 0, total: nil, things: "rows")
                == "Showing 0 rows: offset=900 is past the end. That is all.")
    }

    @Test("The other notices keep their fixed wording")
    func otherNotices() {
        #expect(
            Notice.clipped(field: "Body", width: 160, tool: "message_get")
                == "Body is clipped to 160 characters in each row. Read one in full with message_get.")
        #expect(
            Notice.scanStopped(after: 500, things: "notes", narrowBy: "folder or from_date")
                == "The scan stopped after 500 notes; more may exist. Narrow by folder or from_date.")
        #expect(
            Notice.partial(after: 12, things: "files", narrowBy: "folder")
                == "Partial: the time limit was reached after 12 files. Narrow by folder.")
        #expect(
            Notice.adjusted(argument: "limit", asked: 5000, range: 1...200, used: 200)
                == "limit=5000 is outside 1–200; 200 was used.")
        #expect(Notice.cut(limit: 40_000, total: 48_211) == "Cut at 40000 of 48211 characters. Narrow the call.")
        #expect(
            Notice.notShown(count: 12, things: "idle interfaces", pass: "include_inactive=true")
                == "12 idle interfaces are not shown. Pass include_inactive=true to include them.")
    }

    @Test("The forms added after the first servers keep their wording")
    func laterNotices() {
        #expect(Notice.pages(first: 1, last: 40, total: 40) == nil)
        #expect(Notice.pages(first: 1, last: 3, total: 40) == "Pages 1–3 of 40. Pass first_page=4 for the next pages.")
        #expect(Notice.pages(first: 38, last: 40, total: 40) == "Pages 38–40 of 40. That is all.")
        #expect(
            Notice.cutForGood(limit: 2_000, total: 9_000)
                == "Cut at 2000 of 9000 characters; the rest cannot be read again.")
        #expect(
            Notice.adjusted(argument: "scale", asked: 12.5, range: 0.1...8.0, used: 8.0)
                == "scale=12.5 is outside 0.1–8.0; 8.0 was used.")
    }

    @Test("A CRLF text is cut at its last line break, like an LF one")
    func guardCutsCRLF() {
        let line = String(repeating: "y", count: 998) + "\r\n"
        let cut = ToolOutput(text: String(repeating: line, count: 60), isError: false).withinTheStandard()
        guard case .text(let body) = cut.content[1] else {
            Issue.record("expected the cut text")
            return
        }
        #expect(body.hasSuffix("y"))
        #expect((body.utf16.count + 2) % 1000 == 0)
    }

    @Test("A deadline answers with the work's result, or with nothing once it passes")
    func deadline() async {
        #expect(await Deadline.run(within: .seconds(5)) { 42 } == 42)
        // The work outlasts the limit by far, so a machine too busy to fire the timer on
        // time still sees the limit pass first.
        let late = await Deadline.run(within: .milliseconds(200)) { () -> Int in
            try? await Task.sleep(for: .seconds(60))
            return 1
        }
        #expect(late == nil)
    }

    @Test("Notices go before the data, and none means the data alone")
    func withNotices() {
        #expect(ToolStandard.withNotices([], "data") == "data")
        #expect(ToolStandard.withNotices(["One.", "Two."], "data") == "One.\nTwo.\n\ndata")
    }

    @Test("A page holds the rows asked for and says where it sits")
    func page() {
        let rows = Array(1...120)
        let first = ToolStandard.page(of: rows, limit: 50, offset: 0, things: "rows", notices: ["Adjusted."]) {
            $0.map(String.init).joined(separator: ",")
        }
        #expect(first.hasPrefix("Adjusted.\nShowing 1–50 of 120 rows. Pass offset=50 for the next page.\n\n1,2,"))
        #expect(first.hasSuffix(",50"))

        let last = ToolStandard.page(of: rows, limit: 50, offset: 100, things: "rows", notices: []) {
            $0.map(String.init).joined(separator: ",")
        }
        #expect(last.hasPrefix("Showing 101–120 of 120 rows. That is all.\n\n101,"))

        let whole = ToolStandard.page(of: [1, 2], limit: 50, offset: 0, things: "rows", notices: []) {
            $0.map(String.init).joined(separator: ",")
        }
        #expect(whole == "1,2")
    }

    @Test("A page whose rows are too wide holds fewer of them, and its notice says where to resume")
    func pageShrinksToFit() {
        let wide = String(repeating: "w", count: 1_000)
        let text = ToolStandard.page(of: Array(repeating: wide, count: 200), limit: 100, offset: 0, things: "rows", notices: []) {
            $0.joined(separator: "\n")
        }
        #expect(text.utf16.count <= ToolStandard.longestResult)
        #expect(text.hasPrefix("Showing 1–25 of 200 rows. Pass offset=25 for the next page."))
    }

    @Test("An error repeats only the start of a caller's text")
    func echo() {
        #expect(ToolStandard.echo("short") == "short")
        let long = String(repeating: "a", count: 200)
        #expect(ToolStandard.echo(long) == String(repeating: "a", count: ToolStandard.echoWidth) + "…")
    }

    @Test("A clamped number is reported and one inside its range is not")
    func clamp() {
        var notices: [String] = []
        #expect(ToolStandard.clamp(50, to: 1...200, argument: "limit", notices: &notices) == 50)
        #expect(ToolStandard.clamp(200, to: 1...200, argument: "limit", notices: &notices) == 200)
        #expect(notices.isEmpty)
        #expect(ToolStandard.clamp(201, to: 1...200, argument: "limit", notices: &notices) == 200)
        #expect(ToolStandard.clamp(0, to: 1...200, argument: "limit", notices: &notices) == 1)
        #expect(
            notices == [
                "limit=201 is outside 1–200; 200 was used.", "limit=0 is outside 1–200; 1 was used.",
            ])
    }

    @Test("Windows of a text chain: the next starts where the last ended, and none splits a character")
    func window() {
        let text = "añ👩‍👩‍👧 e\u{301}xyz"
        #expect(text.count == 8)

        let whole = ToolStandard.window(of: text, characterOffset: 0, maxCharacters: 8)
        #expect(whole.text == text)
        #expect(whole.notice == nil)

        let first = ToolStandard.window(of: text, characterOffset: 0, maxCharacters: 3)
        #expect(first.text == "añ👩‍👩‍👧")
        #expect(first.notice == "Characters 1–3 of 8. Pass character_offset=3 for the rest.")

        let second = ToolStandard.window(of: text, characterOffset: 3, maxCharacters: 100)
        #expect(second.text == " e\u{301}xyz")
        #expect(second.notice == "Characters 4–8 of 8. That is all.")
        #expect(first.text + second.text == text)

        let past = ToolStandard.window(of: text, characterOffset: 20, maxCharacters: 5)
        #expect(past.text.isEmpty)
        #expect(past.notice == "Characters 0 of 8: character_offset=20 is past the end. That is all.")

        let labelled = ToolStandard.window(of: text, characterOffset: 0, maxCharacters: 3, label: "Body")
        #expect(labelled.notice == "Body: characters 1–3 of 8. Pass character_offset=3 for the rest.")
    }

    @Test("Instructions and descriptions over the limit are named")
    func overlongTexts() {
        let long = String(repeating: "x", count: ToolStandard.longestDescription + 1)
        let fits = String(repeating: "x", count: ToolStandard.longestDescription)
        let schema: Value = ["type": "object"]
        let catalog = [
            Tool(name: "short", description: fits, inputSchema: schema),
            Tool(name: "long", description: long, inputSchema: schema),
            Tool(name: "none", inputSchema: schema),
        ]
        #expect(ToolStandard.overlongTexts(instructions: fits, catalog: catalog) == ["long"])
        #expect(ToolStandard.overlongTexts(instructions: long, catalog: []) == ["instructions"])
    }

    // MARK: The guard

    @Test("A result at the limit passes untouched and one unit more is cut, with the notice first")
    func guardAtTheLimit() {
        let atLimit = ToolOutput(text: String(repeating: "x", count: ToolStandard.longestResult), isError: false)
        #expect(atLimit.withinTheStandard() == atLimit)

        let over = ToolOutput(text: String(repeating: "x", count: ToolStandard.longestResult + 1), isError: false)
        let cut = over.withinTheStandard()
        let notice = "Cut at 40000 of 40001 characters. Narrow the call."
        #expect(cut.content.first == .text(notice))
        #expect(notice.utf16.count + (cut.text.utf16.count - notice.utf16.count - 1) == ToolStandard.longestResult)
        #expect(cut.content.count == 2)
        guard case .text(let body) = cut.content[1] else {
            Issue.record("expected the cut text")
            return
        }
        #expect(body.utf16.count == ToolStandard.longestResult - notice.utf16.count)
    }

    @Test("The cut falls on the last line break inside the limit")
    func guardCutsAtALineBreak() {
        let line = String(repeating: "y", count: 999) + "\n"
        let cut = ToolOutput(text: String(repeating: line, count: 60), isError: false).withinTheStandard()
        guard case .text(let body) = cut.content[1] else {
            Issue.record("expected the cut text")
            return
        }
        #expect(body.hasSuffix("y"))
        #expect((body.utf16.count + 1) % 1000 == 0)
        #expect(body.utf16.count < ToolStandard.longestResult)
    }

    @Test("A cut never splits a surrogate pair, later text is dropped and images are kept")
    func guardKeepsCharactersAndImages() {
        let emoji = String(repeating: "😀", count: ToolStandard.longestResult)  // two units each
        let output = ToolOutput(
            content: [.text(emoji), .image(data: "AAAA", mimeType: "image/png"), .text("after")],
            isError: false
        ).withinTheStandard()
        #expect(output.content.count == 3)
        guard case .text(let body) = output.content[1] else {
            Issue.record("expected the cut text")
            return
        }
        #expect(body.unicodeScalars.allSatisfy { $0 == "😀" })
        #expect(output.content[2] == .image(data: "AAAA", mimeType: "image/png"))
        #expect(!output.text.contains("after"))
    }

    @Test("An error has its own, shorter limit")
    func guardOnErrors() {
        let fits = ToolOutput(text: String(repeating: "e", count: ToolStandard.longestError), isError: true)
        #expect(fits.withinTheStandard() == fits)
        let over = ToolOutput(text: String(repeating: "e", count: ToolStandard.longestError + 1), isError: true)
        let cut = over.withinTheStandard()
        #expect(cut.isError)
        #expect(cut.content.first == .text("Cut at 10000 of 10001 characters. Narrow the call."))
    }

    /// Returns far more than a result may hold, as a tool that forgot its bound would.
    private struct Flood: ToolHandler {
        func handle(_ call: ToolCall) async -> ToolOutput {
            ToolOutput(text: String(repeating: "row\n", count: 20_000), isError: false)
        }
    }

    @Test("tools/call passes every result through the guard")
    func protocolLayerGuards() async throws {
        let handler = MCPHandler(
            name: "stub", version: "0.0.1", instructions: "Stub.", catalog: [], tools: Flood())
        let line = try #require(
            await handler.respond(
                to: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"flood"}}"#))
        let message = try JSONDecoder().decode(Value.self, from: Data(line.utf8))
        let content = try #require(message.objectValue?["result"]?.objectValue?["content"]?.arrayValue)
        let texts = content.compactMap { $0.objectValue?["text"]?.stringValue }
        #expect(texts.first == "Cut at 40000 of 80000 characters. Narrow the call.")
        #expect(texts.reduce(0) { $0 + $1.utf16.count } <= ToolStandard.longestResult)
    }
}
