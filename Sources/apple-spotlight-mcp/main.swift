import Foundation
import SpotlightMCPCore

// Launcher only. Everything testable lives in SpotlightMCPCore, which the test target
// imports; an executable target cannot be imported.
do {
    // Settings come from the Claude extension manifest, which substitutes the person's
    // user_config into this process's arguments. The allow-list arrives this way, so a
    // parse that quietly went wrong is a scope that quietly went wrong — which is why
    // spotlight_status prints the configuration it actually ended up with.
    try await SpotlightMCPServer.run(
        configuration: Configuration.parse(Array(CommandLine.arguments.dropFirst())))
} catch {
    // Exiting 0 here would be indistinguishable from a clean shutdown, which is how a
    // server disappears mid-session with nothing to show for it.
    Diagnostics.fatal(error)
    exit(1)
}
