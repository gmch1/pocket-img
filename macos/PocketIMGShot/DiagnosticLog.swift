import Foundation
import os

enum DiagnosticLog {
    private static let logger = Logger(
        subsystem: "com.gmch.pocketimg.shot",
        category: "lifecycle"
    )
    private static let lock = NSLock()

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("PocketIMGShot.log", isDirectory: false)
    }

    static func record(_ message: String) {
        logger.info("\(message, privacy: .public)")
        lock.lock()
        defer { lock.unlock() }

        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            let url = fileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: [.atomic])
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            logger.error("Unable to write diagnostic log: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func record(_ error: Error, phase: String) {
        let value = error as NSError
        record("\(phase) failed domain=\(value.domain) code=\(value.code)")
    }
}
