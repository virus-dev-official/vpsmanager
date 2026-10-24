import Foundation

/// The binary has two modes: the normal Mac app, or — when launched with
/// `--mcp` (by Claude Code or another AI agent) — a headless MCP server on
/// stdio that never creates a window or touches AppKit.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
        } else {
            VPSManagerApp.main()
        }
    }
}
