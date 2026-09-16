// Adapted from codex-island (MIT), Copyright (c) 2026 Eric Park.
// See THIRD_PARTY_NOTICES.md.
import Foundation

enum UsageLogLines {
    static func streamLines(at url: URL, maxLineBytes: Int = 16_777_216, onLine: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        var pending = Data()          // partial line carried across chunk reads
        var skippingLongLine = false  // discarding an over-cap line until its '\n'

        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }

            var lineStart = 0
            while let nl = firstNewline(in: chunk, from: lineStart) {
                if skippingLongLine {
                    // Reached the end of the abandoned line; resume normally.
                    skippingLongLine = false
                    pending.removeAll(keepingCapacity: true)
                } else if pending.isEmpty {
                    // A line wholly inside one chunk never touches `pending`, so
                    // honor the cap here too — otherwise the "over-cap line is
                    // never delivered" contract would silently break for any
                    // caller whose cap is below the 64KB chunk size.
                    let len = nl - lineStart
                    if len > 0, len <= maxLineBytes { onLine(chunk[lineStart..<nl]) }
                } else {
                    pending.append(chunk[lineStart..<nl])
                    if pending.count <= maxLineBytes { onLine(pending) }
                    pending.removeAll(keepingCapacity: true)
                }
                lineStart = nl + 1
            }

            // Bytes after the last newline form (the start of) the next line.
            if lineStart < chunk.count, !skippingLongLine {
                pending.append(chunk[lineStart..<chunk.count])
                if pending.count > maxLineBytes {
                    pending.removeAll(keepingCapacity: true)
                    skippingLongLine = true
                }
            }
        }
        if !skippingLongLine, !pending.isEmpty { onLine(pending) }
    }

    /// Offset of the first 0x0A at or after `start` within `data`, or nil.
    /// `memchr` is vectorized and skips the per-byte bounds-checked `Data`
    /// subscript that dominated the scan profile on large session logs.
    /// Callers pass a fresh chunk (startIndex 0), so the returned offset is a
    /// valid `Int` subscript into it.
    private static func firstNewline(in data: Data, from start: Int) -> Int? {
        guard start < data.count else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress else { return nil }
            guard let hit = memchr(base + start, 0x0A, data.count - start) else { return nil }
            return UnsafeRawPointer(hit) - base
        }
    }

}
