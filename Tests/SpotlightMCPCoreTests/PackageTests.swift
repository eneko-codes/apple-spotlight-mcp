import Foundation
import Testing

@testable import SpotlightMCPCore

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

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appending(path: "extension/manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("The manifest, the server constant and Info.plist carry the same version")
    func versionsAgree() throws {
        let manifestVersion = try #require(try manifest()["version"] as? String)
        let plistData = try Data(contentsOf: Self.root.appending(path: "Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(manifestVersion == SpotlightMCPServer.version)
        #expect(plist["CFBundleShortVersionString"] as? String == SpotlightMCPServer.version)
    }

    /// A tool missing from the manifest has no permission switch at all. The manifest also
    /// names the date arguments, so a rename in the code that the prose missed fails here.
    @Test("The manifest lists exactly the tools offered and names the arguments the schema has")
    func manifestAgreesWithTheCatalogue() throws {
        let listed = try #require(try manifest()["tools"] as? [[String: Any]])
        #expect(Set(listed.compactMap { $0["name"] as? String }) == Set(ToolCatalog.all().map(\.name)))
        let search = try #require(listed.first { $0["name"] as? String == ToolCatalog.searchName })
        let description = try #require(search["description"] as? String)
        for name in ToolCatalog.argumentNames(of: ToolCatalog.search(Configuration())) {
            #expect(description.contains(name), "\(name) is missing from the manifest description")
        }
        #expect(!description.contains("modified_after"))
    }
}
