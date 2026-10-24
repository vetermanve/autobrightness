import Foundation

/// Rewrites one assignment in the agent's config file.
///
/// The config is a shell fragment the user also edits by hand, with comments
/// that explain the numbers. So this is a surgical line edit, not a serialiser:
/// everything it does not recognise is copied through byte for byte, and a
/// commented-out assignment stays a comment instead of being revived.
public enum ConfigRewrite {

    /// Returns the file with `key=value` set, replacing the first live
    /// assignment of that key, or appending one when there is none.
    public static func set(_ text: String, key: String, value: String) -> String {
        let assignment = "\(key)=\(value)"
        var lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where isAssignment(line, of: key) {
            // keep any trailing comment: it is usually the unit or the source
            if let hash = trailingComment(in: line) {
                lines[i] = "\(assignment)   \(hash)"
            } else {
                lines[i] = assignment
            }
            return lines.joined(separator: "\n")
        }
        // Append. A file that ends with a newline keeps ending with one.
        if text.isEmpty { return assignment + "\n" }
        if text.hasSuffix("\n") { return text + assignment + "\n" }
        return text + "\n" + assignment + "\n"
    }

    static func isAssignment(_ line: String, of key: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#") else { return false }
        guard t.hasPrefix(key) else { return false }
        let rest = t.dropFirst(key.count)
        return rest.first == "="
    }

    static func trailingComment(in line: String) -> String? {
        // Only a comment outside quotes counts. The values this writes are bare
        // numbers, so a quote anywhere means the line is something else.
        guard !line.contains("\""), !line.contains("'") else { return nil }
        guard let hash = line.firstIndex(of: "#") else { return nil }
        return String(line[hash...])
    }
}
