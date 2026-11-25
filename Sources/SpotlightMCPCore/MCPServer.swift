import Foundation
import Synchronization

/// What answers a `tools/call`. Each server's dispatcher conforms; the protocol layer
/// below knows nothing else about it.
public protocol ToolHandler: Sendable {
    func handle(_ call: ToolCall) async -> ToolOutput
}

/// Turns one line of JSON-RPC 2.0 into at most one line of reply.
///
/// This is the whole of the Model Context Protocol the server needs over stdio: `initialize`,
/// `ping`, `tools/list` and `tools/call`, one JSON message per line. It takes and returns
/// text so the tests drive it without a pipe. This file and `Value.swift` are the same in
/// every server; what differs is passed in.
public struct MCPHandler: Sendable {

    /// Newest first. A client asking for one of these gets it back; any other request is
    /// answered with the newest, and the client decides whether it can speak that.
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let name: String
    private let version: String
    private let instructions: String
    private let catalog: [Tool]
    private let tools: any ToolHandler

    public init(
        name: String, version: String, instructions: String, catalog: [Tool],
        tools: any ToolHandler
    ) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.catalog = catalog
        self.tools = tools
    }

    private enum Failure {
        static let parse = (code: -32700, message: "Parse error")
        static let invalidRequest = (code: -32600, message: "Invalid request")
        static let methodNotFound = (code: -32601, message: "Method not found")
        static let invalidParameters = (code: -32602, message: "Invalid params")
    }

    /// `nil` for a notification or a client's own response, which are never answered.
    public func respond(to line: String) async -> String? {
        guard let message = try? JSONDecoder().decode(Value.self, from: Data(line.utf8)) else {
            return Self.encode(error: Failure.parse, id: .null)
        }
        guard let fields = message.objectValue else {
            return Self.encode(error: Failure.invalidRequest, id: .null)
        }
        // A message with no method is the client answering something; this server asks
        // nothing, so there is nothing to do with it.
        guard let method = fields["method"]?.stringValue else {
            return fields["id"] == nil ? Self.encode(error: Failure.invalidRequest, id: .null) : nil
        }
        // No id means a notification: it must not be answered, even when it is unknown.
        guard let id = fields["id"] else { return nil }

        let parameters = fields["params"]?.objectValue
        switch method {
        case "initialize":
            return Self.encode(result: initialize(parameters), id: id)
        case "ping":
            return Self.encode(result: .object([:]), id: id)
        case "tools/list":
            return Self.encode(result: .object(["tools": .array(catalog.map(\.json))]), id: id)
        case "tools/call":
            guard let toolName = parameters?["name"]?.stringValue else {
                return Self.encode(error: Failure.invalidParameters, id: id)
            }
            let output = await tools.handle(
                ToolCall(
                    name: toolName, arguments: parameters?["arguments"]?.objectValue,
                    progressToken: Self.progressToken(parameters)))
            return Self.encode(
                result: .object(["content": output.json, "isError": .bool(output.isError)]),
                id: id)
        default:
            return Self.encode(error: Failure.methodNotFound, id: id)
        }
    }

    private func initialize(_ parameters: [String: Value]?) -> Value {
        let requested = parameters?["protocolVersion"]?.stringValue ?? ""
        let negotiated = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
        return .object([
            "protocolVersion": .string(negotiated),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object(["name": .string(name), "version": .string(version)]),
            "instructions": .string(instructions),
        ])
    }

    /// The specification allows a string or an integer and nothing else; any other value is
    /// treated as no request for progress.
    private static func progressToken(_ parameters: [String: Value]?) -> Value? {
        switch parameters?["_meta"]?.objectValue?["progressToken"] {
        case .string(let token)?: return .string(token)
        case .int(let token)?: return .int(token)
        default: return nil
        }
    }

    /// A `notifications/progress` line for a call that sent `token`. `progress` must grow
    /// with each notification, and none may follow the call's answer.
    public static func progress(
        token: Value, progress: Double, total: Double? = nil, message: String? = nil
    ) -> String? {
        var parameters: [String: Value] = ["progressToken": token, "progress": .double(progress)]
        if let total { parameters["total"] = .double(total) }
        if let message { parameters["message"] = .string(message) }
        return line([
            "jsonrpc": .string("2.0"), "method": .string("notifications/progress"),
            "params": .object(parameters),
        ])
    }

    private static func encode(result: Value, id: Value) -> String? {
        line(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private static func encode(error: (code: Int, message: String), id: Value) -> String? {
        line([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .int(error.code), "message": .string(error.message)]),
        ])
    }

    /// JSONEncoder emits no raw newline unless asked to pretty-print, and escapes the ones
    /// inside strings, so a message is always exactly one line.
    private static func line(_ fields: [String: Value]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(Value.object(fields))).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Reads requests until the input ends, answering each on its own task so a slow or stuck
/// call never holds up the ones behind it.
///
/// Closing the input is how a client shuts a stdio server down: the specification has it
/// wait for the process to exit, then send SIGTERM. So the end of input waits at most
/// `grace` for calls still running, long enough for a quick one to be answered, and then
/// returns so the process can exit and clean up, even while a call is stuck. A call still
/// running then is abandoned, its answer never written.
public func serve<Lines: AsyncSequence>(
    lines: Lines, handler: MCPHandler, write: @escaping @Sendable (String) -> Void,
    grace: Duration = .seconds(2)
) async where Lines.Element == String {
    // Unstructured tasks, not a task group: a group cannot be left before every child has
    // finished, and a stuck call would keep the server alive.
    let calls = CallsInFlight()
    do {
        for try await line in lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            calls.started()
            Task {
                if let reply = await handler.respond(to: line) { write(reply) }
                calls.finished()
            }
        }
    } catch {
        // A read error ends the input like end of file does.
    }
    await calls.drain(within: grace)
}

/// Counts the calls `serve` has started and not finished, so the end of input can wait for
/// them to reach zero, for a bounded time.
private final class CallsInFlight: Sendable {

    private struct State {
        var running = 0
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func started() {
        state.withLock { $0.running += 1 }
    }

    func finished() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.running -= 1
            guard state.running == 0 else { return nil }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Returns when no call is running or `grace` has passed, whichever comes first. Whoever
    /// takes the waiter out under the lock resumes it, so it is resumed exactly once.
    ///
    /// The timer is a dispatch timer, not `Task.sleep`: a call stuck in a synchronous system
    /// call holds a thread of the cooperative pool, and enough of them could starve a timer
    /// that needs one.
    func drain(within grace: Duration) async {
        let seconds = Double(grace.components.seconds) + Double(grace.components.attoseconds) / 1e18
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { state -> Bool in
                if state.running == 0 { return true }
                state.waiter = continuation
                return false
            }
            if idle {
                continuation.resume()
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                let waiter = self.state.withLock { state -> CheckedContinuation<Void, Never>? in
                    defer { state.waiter = nil }
                    return state.waiter
                }
                waiter?.resume()
            }
        }
    }
}

/// Serves standard input and output until the client closes the input.
///
/// stdout is the JSON-RPC stream and carries nothing else: a stray line there breaks every
/// response after it. Diagnostics go to stderr.
public func serveStandardStreams(handler: MCPHandler) async {
    await serve(
        lines: FileHandle.standardInput.bytes.lines, handler: handler,
        write: writeStandardOutput)
}

/// Replies are written from concurrent tasks, and a pipe keeps a write whole only up to
/// PIPE_BUF (512 bytes on macOS); a longer reply could interleave with another without it.
private let standardOutputLock = Mutex(())

/// One line per call, under the lock. `try?`: the throwing overload reports a closed pipe as
/// an error, where the plain `write(_:)` raises an exception Swift cannot catch.
@Sendable public func writeStandardOutput(_ line: String) {
    let data = Data((line + "\n").utf8)
    standardOutputLock.withLock { _ in try? FileHandle.standardOutput.write(contentsOf: data) }
}
