import Foundation
import RepriseMCPKit

@main struct RepriseMCPMain {
    static func main() async {
        do { try await RepriseMCPServer.run(arguments: Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("Reprise MCP: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
