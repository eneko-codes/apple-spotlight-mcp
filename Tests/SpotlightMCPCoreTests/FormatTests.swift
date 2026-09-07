import Foundation
import Testing

@testable import SpotlightMCPCore

/// `Format.status` is a pure function of `RootProbe`/`IndexState` values, so the wording
/// around a non-responding index can be checked without ever touching a real Spotlight
/// query — the same fixtures-first approach `CLAUDE.md` asks for.
@Suite("Status rendering")
struct FormatTests {

    private static let format = Format(calendar: Calendar(identifier: .gregorian))
    private static let probe = RootProbe(path: "/Users/x/Documents", state: .reachable)

    @Test("A responding index gets no hedging language at all")
    func respondingIsUnremarkable() {
        let text = Self.format.status(
            probes: [Self.probe], indexState: .responding, binaryPath: "/bin/x",
            configuration: Configuration())
        #expect(!text.contains("canary"))
        #expect(!text.contains("double-check"))
    }

    @Test("An empty index state is presented as a hint, not proof of a blind search")
    func emptyIsHedgedNotAsserted() {
        let text = Self.format.status(
            probes: [Self.probe], indexState: .empty, binaryPath: "/bin/x",
            configuration: Configuration())
        #expect(text.contains("under-reporting"))
        #expect(text.contains("double-check"))
        #expect(text.contains("try the real search"))
    }

    @Test("A timed-out index state is distinguished from a genuine empty result")
    func timedOutNamesItsOwnCause() {
        let text = Self.format.status(
            probes: [Self.probe], indexState: .timedOut, binaryPath: "/bin/x",
            configuration: Configuration())
        #expect(text.contains("took longer to answer"))
        #expect(text.contains("(timedOut)"))
    }
}
