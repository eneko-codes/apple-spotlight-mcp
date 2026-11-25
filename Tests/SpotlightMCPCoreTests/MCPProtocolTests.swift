import Foundation
import Synchronization
import Testing

@testable import SpotlightMCPCore

/// The copied protocol layer (`MCPServer.swift`, `Value.swift`), driven as JSON text in and
/// out against a stub tool. It is the same file in every server except for the import.
@Suite("MCP protocol layer")
struct MCPProtocolTests {

    /// Answers every call with what it was asked, so a test can see what reached the tool.
    private struct EchoTools: ToolHandler {
        func handle(_ call: ToolCall) async -> ToolOutput {
            if call.name == "stuck" {
                try? await Task.sleep(for: .seconds(60))
            }
            if call.name == "picture" {
                return ToolOutput(
                    content: [.text("a picture"), .image(data: "AAAA", mimeType: "image/png")],
                    isError: false)
            }
            let token = call.progressToken.map { "\($0)" } ?? "none"
            return ToolOutput(text: "\(call.name) token=\(token)", isError: call.name == "fails")
        }
    }

    private let handler = MCPHandler(
        name: "stub", version: "0.0.1", instructions: "Stub instructions.",
        catalog: [
            Tool(
                name: "echo", description: "Echoes.",
                inputSchema: ["type": "object", "additionalProperties": false],
                annotations: .init(readOnlyHint: true))
        ],
        tools: EchoTools())

    private func decode(_ line: String?) throws -> [String: Value] {
        let text = try #require(line)
        #expect(!text.contains("\n"))
        return try #require(try JSONDecoder().decode(Value.self, from: Data(text.utf8)).objectValue)
    }

    private func result(_ line: String?) throws -> [String: Value] {
        try #require(try decode(line)["result"]?.objectValue)
    }

    @Test("initialize negotiates the version and describes the server")
    func initialize() async throws {
        let known = try result(
            await handler.respond(
                to: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        #expect(known["protocolVersion"] == "2025-06-18")
        #expect(known["serverInfo"] == ["name": "stub", "version": "0.0.1"])
        #expect(known["instructions"] == "Stub instructions.")
        #expect(known["capabilities"] == ["tools": ["listChanged": false]])

        let unknown = try result(
            await handler.respond(
                to: #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect(unknown["protocolVersion"]?.stringValue == MCPHandler.supportedVersions[0])
    }

    @Test("notifications and client responses get no answer")
    func silence() async {
        #expect(await handler.respond(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await handler.respond(to: #"{"jsonrpc":"2.0","method":"no/such/notification"}"#) == nil)
        #expect(await handler.respond(to: #"{"jsonrpc":"2.0","id":3,"result":{}}"#) == nil)
    }

    @Test("malformed input and unknown methods get JSON-RPC errors")
    func errors() async throws {
        #expect(try decode(await handler.respond(to: "not json"))["error"]?.objectValue?["code"] == -32700)
        #expect(try decode(await handler.respond(to: "[1]"))["error"]?.objectValue?["code"] == -32600)
        let unknown = try decode(await handler.respond(to: #"{"jsonrpc":"2.0","id":"a","method":"nope"}"#))
        #expect(unknown["error"]?.objectValue?["code"] == -32601)
        #expect(unknown["id"] == "a")
        let nameless = try decode(
            await handler.respond(to: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{}}"#))
        #expect(nameless["error"]?.objectValue?["code"] == -32602)
    }

    @Test("ping answers with an empty object")
    func ping() async throws {
        #expect(try result(await handler.respond(to: #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#)).isEmpty)
    }

    @Test("tools/list sends the catalogue it was given")
    func list() async throws {
        let tools = try #require(
            try result(await handler.respond(to: #"{"jsonrpc":"2.0","id":6,"method":"tools/list"}"#))["tools"])
        #expect(
            tools == [
                [
                    "name": "echo", "description": "Echoes.",
                    "inputSchema": ["type": "object", "additionalProperties": false],
                    "annotations": ["readOnlyHint": true],
                ]
            ])
    }

    @Test("tools/call returns the tool's blocks and error flag")
    func call() async throws {
        let plain = try result(
            await handler.respond(
                to: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"fails","arguments":{"a":1}}}"#))
        #expect(plain["content"] == [["type": "text", "text": "fails token=none"]])
        #expect(plain["isError"] == true)

        let picture = try result(
            await handler.respond(
                to: #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"picture"}}"#))
        #expect(
            picture["content"] == [
                ["type": "text", "text": "a picture"],
                ["type": "image", "data": "AAAA", "mimeType": "image/png"],
            ])
        #expect(picture["isError"] == false)
    }

    @Test("a progress token reaches the tool only when it is a string or an integer")
    func progressToken() async throws {
        func text(_ meta: String) async throws -> String? {
            let reply = try result(
                await handler.respond(
                    to: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"echo","_meta":\#(meta)}}"#))
            return reply["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        }
        #expect(try await text(#"{"progressToken":"abc"}"#) == #"echo token=string("abc")"#)
        #expect(try await text(#"{"progressToken":42}"#) == "echo token=int(42)")
        #expect(try await text(#"{"progressToken":{"x":1}}"#) == "echo token=none")
    }

    @Test("a progress notification carries the token and only the fields given")
    func progressNotification() throws {
        let full = try decode(MCPHandler.progress(token: "abc", progress: 50, total: 100, message: "half"))
        #expect(full["method"] == "notifications/progress")
        #expect(full["id"] == nil)
        #expect(full["params"] == ["progressToken": "abc", "progress": 50, "total": 100, "message": "half"])

        let bare = try decode(MCPHandler.progress(token: 7, progress: 1))
        #expect(bare["params"] == ["progressToken": 7, "progress": 1])
    }

    @Test("numbers keep their kind through a round trip and read leniently")
    func numbers() throws {
        let decoded = try JSONDecoder().decode(Value.self, from: Data(#"[true, 1, 1.5, 2.0, null]"#.utf8))
        #expect(decoded == [true, 1, 1.5, 2, nil])
        #expect(Value.double(2).intValue == 2)
        #expect(Value.double(2.5).intValue == nil)
        #expect(Value.int(3).doubleValue == 3)
        #expect(Value.bool(true).intValue == nil)
        let name = "x"
        let interpolated: Value = "\(name)y"
        #expect(interpolated == .string("xy"))
    }

    // MARK: Serving

    /// Feeds `lines` as the whole input and collects every line written.
    private func served(_ lines: [String], grace: Duration) async -> (written: [String], elapsed: Duration) {
        let written = Mutex<[String]>([])
        let input = AsyncStream<String> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        let started = ContinuousClock.now
        await serve(
            lines: input, handler: handler, write: { line in written.withLock { $0.append(line) } },
            grace: grace)
        return (written.withLock { $0 }, ContinuousClock.now - started)
    }

    @Test("calls already running when the input ends are still answered")
    func endOfInputAnswersQuickCalls() async {
        let outcome = await served(
            [
                #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo"}}"#,
            ], grace: .seconds(5))
        #expect(outcome.written.count == 2)
        #expect(outcome.elapsed < .seconds(5))
    }

    @Test("a stuck call does not keep the server alive after the input ends")
    func endOfInputAbandonsStuckCalls() async {
        let outcome = await served(
            [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"stuck"}}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
            ], grace: .milliseconds(200))
        #expect(outcome.written.count == 1)
        #expect(outcome.elapsed < .seconds(5))
    }
}
