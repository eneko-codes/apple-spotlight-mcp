import Foundation
import MCP
import Testing

@testable import SpotlightMCPCore

/// Checks on the advertised surface itself. None of these open a file.
@Suite("Catalogue")
struct CatalogueTests {

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let tools = ToolCatalog.all()
        let names = tools.map(\.name)
        #expect(names.count == Set(names).count)
        for tool in tools {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union such as
    /// `["string", "null"]` and hands the model a bare `{}` in its place. The fault is
    /// invisible until a caller happens to use that field, so the whole catalogue is
    /// walked here rather than trusted to review.
    @Test("No property declares a union type")
    func noUnionTypesInSchemas() {
        for tool in ToolCatalog.all() {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { continue }
            for (property, definition) in properties {
                guard case .object(let fields) = definition else { continue }
                if case .array = fields["type"] {
                    Issue.record("\(tool.name).\(property) declares a union type")
                }
            }
        }
    }

    @Test("Every tool is read-only")
    func everyToolIsReadOnly() {
        for tool in ToolCatalog.all() {
            #expect(tool.annotations.readOnlyHint == true, "\(tool.name) is mis-annotated")
        }
    }
}
