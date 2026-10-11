import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The SDK's files, under `<storage dir>/kontala/`.
///
/// Every write goes to a temporary file first and is renamed into place, so a process killed mid-write leaves the last
/// good file rather than half of one. The first failure latches the store off for the process, as
/// tag/core/core.cookie.ts latches its in-memory jar: ids stay populated in memory, and the debug log says why.
///
/// Nothing is written while `writable` is false, which is while consent is anything but granted, as the tag writes no
/// cookie then: only an essential write, the visitor's own opt-out, is kept regardless. Only the core's queue touches
/// it.
package final class FileStore {
    private let dir: URL?
    private var failed = false
    package private(set) var lastError: String?

    /// Whether anything but an essential write may be made.
    package var writable = true

    package init(baseDir: String?) {
        dir = baseDir.map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("kontala", isDirectory: true)
        }
    }

    package var available: Bool { dir != nil && !failed }

    package func directory() -> URL? { available ? dir : nil }

    package func file(_ name: String) -> URL? {
        guard available, let dir = dir else { return nil }
        return dir.appendingPathComponent(name)
    }

    package func readJson(_ name: String) -> JSONObject? {
        guard let f = file(name) else { return nil }
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        do {
            return Json.decodeObject(try Data(contentsOf: f))
        } catch {
            // A file that cannot be read is as good as none; it is overwritten.
            lastError = "\(error)"
            return nil
        }
    }

    /// The file's text, or nil where there is none or it cannot be read.
    package func readString(_ name: String) -> String? {
        guard let f = file(name), FileManager.default.fileExists(atPath: f.path) else { return nil }
        guard let data = try? Data(contentsOf: f) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    package func writeJson(_ name: String, _ value: JSONObject, essential: Bool = false) -> Bool {
        writeString(name, Json.encode(value), essential: essential)
    }

    @discardableResult
    package func writeString(_ name: String, _ content: String, essential: Bool = false) -> Bool {
        if !writable && !essential { return false }
        guard let f = file(name) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileStore.atomicWrite(Array(content.utf8), to: f.path)
            return true
        } catch {
            fail("\(error)")
            return false
        }
    }

    /// Appends [content] to the file, creating it; never latches the store, since a crash's row is written from a
    /// thread that may be the last to run.
    package static func append(_ content: String, to path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if fd < 0 { return false }
        defer { close(fd) }
        let bytes = Array(content.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written != bytes.count { return false }
        fsync(fd)
        return true
    }

    @discardableResult
    package func delete(_ name: String) -> Bool {
        guard let f = file(name) else { return false }
        if !FileManager.default.fileExists(atPath: f.path) { return true }
        do {
            try FileManager.default.removeItem(at: f)
            return true
        } catch {
            fail("\(error)")
            return false
        }
    }

    package func exists(_ name: String) -> Bool {
        guard let f = file(name) else { return false }
        return FileManager.default.fileExists(atPath: f.path)
    }

    private func fail(_ e: String) {
        failed = true
        lastError = e
    }

    private struct WriteError: Error, CustomStringConvertible {
        let description: String
    }

    /// Writes [bytes] to a temporary file beside [path], syncs it and renames it into place.
    private static func atomicWrite(_ bytes: [UInt8], to path: String) throws {
        let tmp = path + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd < 0 { throw WriteError(description: "could not open \(tmp): errno \(errno)") }
        var ok = true
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written != bytes.count { ok = false }
        if fsync(fd) != 0 { ok = false }
        close(fd)
        if !ok { throw WriteError(description: "could not write \(tmp): errno \(errno)") }
        if rename(tmp, path) != 0 { throw WriteError(description: "could not rename \(tmp): errno \(errno)") }
    }
}
