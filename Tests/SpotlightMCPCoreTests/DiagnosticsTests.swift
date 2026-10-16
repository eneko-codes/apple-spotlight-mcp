import Foundation
import Testing

@testable import SpotlightMCPCore

@Suite("Diagnostics")
struct DiagnosticsTests {

    private enum SampleError: Error {
        case notFound(identifier: String)
        case plain
    }

    @Test("An enum error is reported by case, never by its payload")
    func enumPayloadStaysOut() {
        let kind = Diagnostics.kind(of: SampleError.notFound(identifier: "/Users/user/secret.txt"))
        #expect(kind.hasSuffix("SampleError.notFound"))
        #expect(!kind.contains("secret"))
        #expect(!kind.contains("/Users"))
        #expect(Diagnostics.kind(of: SampleError.plain).hasSuffix("SampleError.plain"))
    }

    @Test("A non-enum error is reduced to domain and code, dropping its description")
    func foundationErrorHasNoDescription() {
        let error = NSError(
            domain: "TestDomain", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "could not open /Users/user/private.pdf"])
        let kind = Diagnostics.kind(of: error)
        #expect(kind == "TestDomain#7")
    }

    @Test("A tool name that is not a plain identifier cannot reach the log")
    func toolNameIsSanitised() {
        #expect(Diagnostics.toolName("notes_search") == "notes_search")
        #expect(Diagnostics.toolName("evil\nfatal forged line") == "invalid")
        #expect(Diagnostics.toolName("") == "invalid")
        #expect(Diagnostics.toolName(String(repeating: "a", count: 65)) == "invalid")
    }

    @Test("A line is one line")
    func lineEndsOnce() {
        let line = Diagnostics.line("info", "stopped")
        #expect(line.filter { $0 == "\n" }.count == 1)
        #expect(line.hasSuffix("stopped\n"))
    }
}
