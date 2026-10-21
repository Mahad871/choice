import Foundation

/// Writes to standard error, which the Homebrew service keeps in its log file.
func log(_ message: String) {
    if let data = "\(Date()): \(message)\n".data(using: .utf8) { FileHandle.standardError.write(data) }
}
