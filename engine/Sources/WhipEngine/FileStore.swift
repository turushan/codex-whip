import Foundation

/// Private files: directories readable only by this user, and writes that either fully land or not at all.
public enum FileStore {
    public static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(url.path, 0o700) == 0 else { throw posixError() }
    }

    /// Writes beside the target, flushes to disk, then renames over it. Without a prefix the
    /// temporary file is `<name>.tmp`, as the state journal has always used.
    public static func writeAtomically(_ data: Data, to url: URL, temporaryPrefix: String? = nil) throws {
        let directory = url.deletingLastPathComponent()
        let temporary: URL
        if let temporaryPrefix {
            temporary = directory.appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString.prefix(8)).tmp")
        } else {
            temporary = url.deletingPathExtension().appendingPathExtension("tmp")
        }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var closed = false
        defer {
            if !closed { close(descriptor) }
            if temporaryPrefix != nil { unlink(temporary.path) }
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }
        closed = true
        guard close(descriptor) == 0 else { throw posixError() }
        guard rename(temporary.path, url.path) == 0 else { throw posixError() }
    }

    public static func writeJSON(_ value: JSON, to url: URL) throws {
        try writeAtomically(Data((try value.serialized(.pretty) + "\n").utf8), to: url)
    }

    public static func readJSON(_ url: URL) throws -> JSON {
        try JSON.parse(Data(contentsOf: url))
    }

    static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
