import MirrorServer

@main
struct Entry {
    static func main() async throws {
        try await MirrorMCPServer.run()
    }
}
