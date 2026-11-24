import Foundation

/// A JSON value. The protocol layer, the tool catalogue and the argument reader all speak
/// it, so nothing here depends on a third-party JSON or protocol package.
public enum Value: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Value])
    case object([String: Value])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: a JSON `true` must not be read as the number 1, and `1` must not
        // become a double. Foundation refuses the cross-type reads, so the first match wins.
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Int.self) {
            self = .int(number)
        } else if let number = try? container.decode(Double.self) {
            self = .double(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([Value].self) {
            self = .array(items)
        } else if let fields = try? container.decode([String: Value].self) {
            self = .object(fields)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .int(let number): try container.encode(number)
        case .double(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .array(let items): try container.encode(items)
        case .object(let fields): try container.encode(fields)
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// A whole number, whether it arrived as `20` or as `20.0`; never a fraction.
    public var intValue: Int? {
        switch self {
        case .int(let number):
            return number
        case .double(let number):
            return Int(exactly: number)
        default:
            return nil
        }
    }

    /// Any JSON number. A client may send `2` where a fraction is allowed, and JSON does not
    /// tell the two apart.
    public var doubleValue: Double? {
        switch self {
        case .int(let number):
            return Double(number)
        case .double(let number):
            return number
        default:
            return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    public var arrayValue: [Value]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectValue: [String: Value]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}

// Literals keep schemas and test arguments readable: `["type": "object"]` rather than
// `.object(["type": .string("object")])`.
extension Value: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringInterpolation,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(stringInterpolation: DefaultStringInterpolation) {
        self = .string(String(stringInterpolation: stringInterpolation))
    }
    public init(arrayLiteral elements: Value...) { self = .array(elements) }

    /// A repeated key keeps its last value, as a JSON parser would.
    public init(dictionaryLiteral elements: (String, Value)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// A tool as advertised in `tools/list`.
public struct Tool: Sendable {

    public struct Annotations: Sendable {
        public var readOnlyHint: Bool?
        public var destructiveHint: Bool?
        public var idempotentHint: Bool?
        public var openWorldHint: Bool?

        public init(
            readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil, idempotentHint: Bool? = nil,
            openWorldHint: Bool? = nil
        ) {
            self.readOnlyHint = readOnlyHint
            self.destructiveHint = destructiveHint
            self.idempotentHint = idempotentHint
            self.openWorldHint = openWorldHint
        }

        var json: Value {
            var fields: [String: Value] = [:]
            if let readOnlyHint { fields["readOnlyHint"] = .bool(readOnlyHint) }
            if let destructiveHint { fields["destructiveHint"] = .bool(destructiveHint) }
            if let idempotentHint { fields["idempotentHint"] = .bool(idempotentHint) }
            if let openWorldHint { fields["openWorldHint"] = .bool(openWorldHint) }
            return .object(fields)
        }
    }

    public var name: String
    public var title: String?
    public var description: String?
    public var inputSchema: Value
    public var annotations: Annotations

    public init(
        name: String, title: String? = nil, description: String? = nil, inputSchema: Value,
        annotations: Annotations = Annotations()
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    var json: Value {
        var fields: [String: Value] = [
            "name": .string(name), "inputSchema": inputSchema, "annotations": annotations.json,
        ]
        if let title { fields["title"] = .string(title) }
        if let description { fields["description"] = .string(description) }
        return .object(fields)
    }
}

/// What a `tools/call` asks for.
public struct ToolCall: Sendable {
    public var name: String
    public var arguments: [String: Value]?
    /// Set when the client asked for progress notifications on this call: a string or an
    /// integer, to be echoed back in each one (`MCPHandler.progress`).
    public var progressToken: Value?

    public init(name: String, arguments: [String: Value]? = nil, progressToken: Value? = nil) {
        self.name = name
        self.arguments = arguments
        self.progressToken = progressToken
    }
}

/// What a tool answers: content blocks in order, flagged when they describe a failure.
public struct ToolOutput: Sendable, Equatable {

    public enum Block: Sendable, Equatable {
        case text(String)
        /// `data` is base64, as the protocol carries it.
        case image(data: String, mimeType: String)
    }

    public var content: [Block]
    public var isError: Bool

    public init(content: [Block], isError: Bool) {
        self.content = content
        self.isError = isError
    }

    public init(text: String, isError: Bool) {
        self.init(content: [.text(text)], isError: isError)
    }

    /// Every text block, joined by newlines; images are left out.
    public var text: String {
        content.compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
    }

    var json: Value {
        .array(
            content.map { block in
                switch block {
                case .text(let text):
                    return ["type": "text", "text": .string(text)]
                case .image(let data, let mimeType):
                    return ["type": "image", "data": .string(data), "mimeType": .string(mimeType)]
                }
            })
    }
}
