import Foundation
import MirrorServer

@main
struct Entry {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let code = try await CLI.run(arguments)
        if code != CLI.ExitCode.ok { exit(code) }
    }
}
