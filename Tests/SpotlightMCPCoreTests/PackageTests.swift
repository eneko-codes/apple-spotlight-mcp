import Foundation
import Testing

@Suite("Package")
struct PackageTests {

    /// Found from this file rather than the working directory, which SwiftPM does not
    /// promise for a test run.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SpotlightMCPCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root

    /// The server is built from the system's own frameworks and nothing else. A dependency
    /// is a decision for the owner, so adding one has to break this test first.
    @Test("The package declares no third-party dependency")
    func noDependencies() throws {
        let package = try String(
            contentsOf: Self.root.appending(path: "Package.swift"), encoding: .utf8)
        #expect(!package.contains(".package("), "Package.swift declares a dependency")
        #expect(!package.contains(".product("))
    }
}
