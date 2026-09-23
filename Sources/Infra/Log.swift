import Foundation
import os

/// App log: one line per event, `key=value` pairs, to the unified log and
/// (after `Log.startFile`) a rotating file. See
/// docs/superpowers/specs/2026-09-23-internal-logging-design.md.
enum LogLevel: Int, Comparable {
    case debug, info, warn, error

    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    init?(name: String) {
        switch name.lowercased() {
        case "debug": self = .debug
        case "info": self = .info
        case "warn": self = .warn
        case "error": self = .error
        default: return nil
        }
    }

    var letter: String { ["D", "I", "W", "E"][rawValue] }

    /// info → `.default` so `log show` prints it, like the old NSLog lines.
    var osType: OSLogType { [.debug, .default, .default, .error][rawValue] }
}

struct LogCategory {
    let name: String
    let osLog: OSLog

    init(_ name: String) {
        self.name = name
        osLog = OSLog(subsystem: "dev.dashisland.DashIsland", category: name)
    }

    func debug(_ m: @autoclosure () -> String) { Log.write(.debug, self, m) }
    func info(_ m: @autoclosure () -> String) { Log.write(.info, self, m) }
    func warn(_ m: @autoclosure () -> String) { Log.write(.warn, self, m) }
    func error(_ m: @autoclosure () -> String) { Log.write(.error, self, m) }
}

enum Log {
    static let app = LogCategory("app")
    static let accounts = LogCategory("accounts")
    static let poll = LogCategory("poll")
    static let fetch = LogCategory("fetch")
    static let auth = LogCategory("auth")
    static let burn = LogCategory("burn")
    static let local = LogCategory("local")
    static let window = LogCategory("window")

    // ponytail: plain statics set once at launch before other threads log; no lock.
    nonisolated(unsafe) static var level: LogLevel = .info
    nonisolated(unsafe) private static var file: LogFile?

    static var defaultFileURL: URL {
        CredentialStore.appSupportURL.appendingPathComponent("logs/dashisland.log")
    }

    static var fileURL: URL? { file?.url }

    static func resolveLevel(env: [String: String], defaults: UserDefaults) -> LogLevel {
        env["DASHISLAND_LOG"].flatMap(LogLevel.init(name:))
            ?? defaults.string(forKey: "DashIsland.logLevel").flatMap(LogLevel.init(name:))
            ?? .info
    }

    static func startFile(at url: URL, maxBytes: Int = 2_000_000, keep: Int = 3) {
        file = LogFile(url: url, maxBytes: maxBytes, keep: keep)
    }

    static func redact(_ secret: String?) -> String {
        guard let secret else { return "nil" }
        return secret.count > 6 ? String(secret.prefix(6)) + "…" : "…"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    static func format(_ level: LogLevel, _ category: String, _ message: String, at date: Date) -> String {
        let text = message.replacingOccurrences(of: "\n", with: "⏎")
        return "\(stamp.string(from: date)) \(level.letter) [\(category)] \(text)"
    }

    static func write(_ level: LogLevel, _ category: LogCategory, _ message: () -> String) {
        guard level >= Log.level else { return }
        let text = message()
        os_log("%{public}@", log: category.osLog, type: level.osType, text)
        file?.append(format(level, category.name, text, at: Date()))
    }
}

/// Append-only file with size-based rotation (`.1` newest … `.keep` oldest).
// ponytail: one lock around synchronous writes keeps call order; a writer queue if logging ever shows up in profiles.
final class LogFile: @unchecked Sendable {
    let url: URL
    private let maxBytes: Int
    private let keep: Int
    private let report: (String) -> Void
    private let lock = NSLock()
    private var handle: FileHandle?

    /// `report` hears once when the sink turns off. The default writes to the unified
    /// log only — never back into this file, which is what failed.
    init?(url: URL, maxBytes: Int, keep: Int, report: @escaping (String) -> Void = LogFile.reportToUnifiedLog) {
        self.url = url
        self.maxBytes = maxBytes
        self.keep = keep
        self.report = report
        do {
            handle = try Self.open(url)
        } catch {
            report(Self.sinkOff(error))
            return nil
        }
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = handle else { return }
        do {
            // A dev build and the installed app share this file. When the other one
            // rotated, our fd still points at the moved `.1`; follow the path instead.
            if !Self.isCurrent(current, at: url) {
                try? current.close()
                current = try Self.open(url)
                handle = current
            }
            try current.write(contentsOf: Data((line + "\n").utf8))
            if try current.offset() > UInt64(maxBytes) { try rotate() }
        } catch {
            // Disk full / file gone: stop writing, never crash. Unified log still works.
            handle = nil
            report(Self.sinkOff(error))
        }
    }

    static func reportToUnifiedLog(_ message: String) {
        os_log("%{public}@", log: Log.app.osLog, type: LogLevel.warn.osType, message)
    }

    private static func sinkOff(_ error: Error) -> String {
        let ns = error as NSError
        return "log file sink off domain=\(ns.domain) code=\(ns.code)"
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let fm = FileManager.default
        func path(_ i: Int) -> URL { i == 0 ? url : URL(fileURLWithPath: url.path + ".\(i)") }
        try? fm.removeItem(at: path(keep))
        for i in stride(from: keep - 1, through: 1, by: -1) {
            try? fm.moveItem(at: path(i), to: path(i + 1))
        }
        // Must succeed, or the next append would rotate again on the same big file.
        try fm.moveItem(at: path(0), to: path(1))
        handle = try Self.open(url)
    }

    /// O_APPEND: every write lands at the current end, even with a second writer.
    private static func open(_ url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func isCurrent(_ handle: FileHandle, at url: URL) -> Bool {
        var held = stat()
        var onDisk = stat()
        guard fstat(handle.fileDescriptor, &held) == 0, stat(url.path, &onDisk) == 0 else { return false }
        return held.st_ino == onDisk.st_ino && held.st_dev == onDisk.st_dev
    }
}

extension UUID {
    var short: String { String(uuidString.prefix(8)) }
}
