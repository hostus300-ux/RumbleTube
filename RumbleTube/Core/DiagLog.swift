import Foundation

/// A small rolling log of things that went wrong (failed requests, parse misses, playback errors).
/// Shared from Settings → Report a problem so a fix can target exactly what broke.
/// Never records cookies, usernames, passwords or search text: only paths, status codes and error text.
final class DiagLog: @unchecked Sendable {
    static let shared = DiagLog()
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 400
    private let url: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("diagnostics.log")
    private let stamp: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); return f }()

    private init() {
        if let url, let s = try? String(contentsOf: url, encoding: .utf8) {
            lines = Array(s.split(separator: "\n").map(String.init).suffix(limit))
        }
    }

    func log(_ area: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(area)] \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        let text = lines.joined(separator: "\n")
        lock.unlock()
        if let url { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Request failure: logs host + path only (no query string, so search terms stay private).
    func request(_ url: URL?, status: Int? = nil, error: Error? = nil) {
        let where_ = url.map { "\($0.host ?? "")\($0.path)" } ?? "?"
        var m = where_
        if let status { m += " → HTTP \(status)" }
        if let error { m += " → \(error.localizedDescription)" }
        log("net", m)
    }

    var entries: [String] { lock.lock(); defer { lock.unlock() }; return lines }

    func clear() {
        lock.lock(); lines = []; lock.unlock()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Text for the report: a header (app/iOS version, sign-in yes/no) plus the log.
    func report(header: [String: String]) -> String {
        let head = header.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        let body = entries.isEmpty ? "(no problems logged)" : entries.joined(separator: "\n")
        return "RumbleTube problem report\n\(head)\n\n\(body)\n"
    }

    /// Writes the report to a temporary .txt for sharing.
    func reportFile(header: [String: String]) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("RumbleTube-report.txt")
        try? report(header: header).write(to: u, atomically: true, encoding: .utf8)
        return u
    }
}
