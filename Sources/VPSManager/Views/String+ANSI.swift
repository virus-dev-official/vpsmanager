import Foundation

extension String {
    /// Strips ANSI escape sequences (color codes, cursor movement, etc.) so raw CLI
    /// output like `pm2 logs` displays cleanly in a plain SwiftUI Text view instead
    /// of showing literal escape codes.
    func strippingANSICodes() -> String {
        guard let regex = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[a-zA-Z]") else { return self }
        let range = NSRange(startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: "")
    }
}