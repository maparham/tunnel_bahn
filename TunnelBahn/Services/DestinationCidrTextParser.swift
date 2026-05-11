import Foundation

enum DestinationCidrTextParser {
    /// Tokenizes plain-text lists: newlines, `#` line comments, optional comma-separated fragments per line.
    static func candidateStrings(from plainText: String) -> [String] {
        let normalized = plainText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.components(separatedBy: "\n")

        var out: [String] = []
        for raw in rawLines {
            let trimmedLine = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }
            if let first = trimmedLine.first(where: { !$0.isWhitespace }), first == "#" {
                continue
            }
            if trimmedLine.contains(",") {
                for part in trimmedLine.split(separator: ",", omittingEmptySubsequences: false) {
                    let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        out.append(t)
                    }
                }
            } else {
                out.append(trimmedLine)
            }
        }
        return out
    }
}
