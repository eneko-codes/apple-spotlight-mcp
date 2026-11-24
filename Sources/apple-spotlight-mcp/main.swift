import Foundation
import SpotlightMCPCore

// Launcher only. Everything testable lives in SpotlightMCPCore, which the test target
// imports; an executable target cannot be imported.
//
// Settings come from the Claude extension manifest, which substitutes the person's
// user_config into this process's arguments. The allow-list arrives this way, so a
// parse that quietly went wrong is a scope that quietly went wrong — which is why
// spotlight_status prints the configuration it actually ended up with.
await SpotlightMCPServer.run(
    configuration: Configuration.parse(Array(CommandLine.arguments.dropFirst())))
