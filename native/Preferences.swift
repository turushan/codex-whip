import Foundation
import Darwin

struct RetrySettings: Codable, Equatable {
    var retrySeconds: Int
    var scanSeconds: Int
    var message: String

    enum CodingKeys: String, CodingKey {
        case retrySeconds = "retry_seconds"
        case scanSeconds = "scan_seconds"
        case message
    }
}

private struct PreferencesError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) { errorDescription = description }
}

/// Reads the worker's preferences directly; retry state and history belong to the worker.
final class PreferencesStore {
    let directory: URL
    let defaults: RetrySettings

    init(directory: URL, defaults: RetrySettings) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.lastPathComponent.isEmpty, directory.path != "/" else {
            throw PreferencesError("Preferences need an absolute local state directory.")
        }
        try Self.validate(defaults)
        // Resolve existing ancestors (including macOS /var), but never follow the state
        // directory itself if someone replaces it with a symbolic link.
        let standardized = directory.standardizedFileURL
        self.directory = Self.canonicalParent(of: standardized)
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
        self.defaults = defaults
    }

    static func bundledDefaults(in bundle: Bundle = .main) throws -> RetrySettings {
        guard let value = bundle.object(forInfoDictionaryKey: "WhipDefaultSettings") else {
            throw PreferencesError("The app is missing its bundled preference defaults. Rebuild or reinstall Codex Whip.")
        }
        do { return try decodeObject(value) }
        catch {
            throw PreferencesError("The app's bundled preference defaults are invalid: \(error.localizedDescription) Rebuild or reinstall Codex Whip.")
        }
    }

    func read() throws -> RetrySettings {
        guard let descriptor = try openDirectory(create: false) else { return defaults }
        defer { close(descriptor) }
        guard let snapshot = try readSnapshot(in: descriptor) else { return defaults }
        return try Self.decode(snapshot.data)
    }

    @discardableResult
    func update(_ mutate: (inout RetrySettings) -> Void) throws -> RetrySettings {
        try change { current in
            var settings = current
            mutate(&settings)
            return settings
        }
    }

    func write(_ settings: RetrySettings) throws {
        _ = try change { _ in settings }
    }

    private func change(_ transform: (RetrySettings) -> RetrySettings) throws -> RetrySettings {
        var descriptor = try openDirectory(create: false)
        defer { if let descriptor { close(descriptor) } }
        let previous = try descriptor.flatMap { try readSnapshot(in: $0) }
        let current = try previous.map { try Self.decode($0.data) } ?? defaults
        let settings = transform(current)
        try Self.validate(settings)
        if descriptor == nil { descriptor = try openDirectory(create: true) }
        guard let descriptor else { throw PreferencesError("Cannot create the preferences directory.") }
        try persist(settings, previous: previous, in: descriptor)
        return settings
    }

    private struct Snapshot {
        let data: Data
        let device: dev_t
        let inode: ino_t
    }

    private func readSnapshot(in directoryDescriptor: Int32) throws -> Snapshot? {
        let descriptor = openat(directoryDescriptor, "settings.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw systemError("Cannot read settings.json")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw systemError("Cannot inspect settings.json") }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid() else {
            throw PreferencesError("settings.json must be a regular file owned by your user. Check the state directory before trying again.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError("Cannot read settings.json")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return Snapshot(data: data, device: metadata.st_dev, inode: metadata.st_ino)
    }

    private func persist(_ settings: RetrySettings, previous: Snapshot?, in descriptor: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(settings)
        data.append(0x0A)

        guard fchmod(descriptor, 0o700) == 0 else { throw systemError("Cannot make the preferences directory private") }
        let name = ".settings-\(UUID().uuidString).tmp"
        let temporary = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temporary >= 0 else { throw systemError("Cannot create a private preferences file") }
        defer {
            close(temporary)
            unlinkat(descriptor, name, 0)
        }
        guard fchmod(temporary, 0o600) == 0 else { throw systemError("Cannot make settings.json private") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(temporary, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError("Cannot write settings.json")
                }
                guard count > 0 else { throw PreferencesError("Cannot finish writing settings.json. Check available disk space.") }
                offset += count
            }
        }
        guard fsync(temporary) == 0 else { throw systemError("Cannot save settings.json to disk") }

        // CLI saves use atomic replacement too. Abort if that replacement happened
        // after this menu action read its starting value, preserving the newer edit.
        try verifyDirectory(descriptor)
        let latest = try readSnapshot(in: descriptor)
        guard Self.matches(previous, latest) else {
            throw PreferencesError("Preferences changed while saving. Open Preferences and try your change again.")
        }
        let result: Int32
        if previous == nil {
            result = renameatx_np(descriptor, name, descriptor, "settings.json", UInt32(RENAME_EXCL))
        } else {
            result = renameat(descriptor, name, descriptor, "settings.json")
        }
        guard result == 0 else { throw systemError("Cannot replace settings.json") }
    }

    private static func matches(_ first: Snapshot?, _ second: Snapshot?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case let (first?, second?):
            return first.device == second.device && first.inode == second.inode && first.data == second.data
        default: return false
        }
    }

    private func verifyDirectory(_ descriptor: Int32) throws {
        guard let current = try openDirectory(create: false) else {
            throw PreferencesError("The preferences directory moved while saving. Try your change again.")
        }
        defer { close(current) }
        var original = stat()
        var latest = stat()
        guard fstat(descriptor, &original) == 0, fstat(current, &latest) == 0 else {
            throw systemError("Cannot inspect the preferences directory")
        }
        guard original.st_dev == latest.st_dev, original.st_ino == latest.st_ino else {
            throw PreferencesError("The preferences directory changed while saving. Try your change again.")
        }
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError("Cannot open the preferences directory") }
        var keepDescriptor = false
        defer { if !keepDescriptor { close(descriptor) } }
        for component in directory.pathComponents.dropFirst() {
            var child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0 && errno == ENOENT {
                if !create { return nil }
                guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                    throw systemError("Cannot create the preferences directory")
                }
                child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else { throw systemError("Cannot open the preferences directory safely") }
            close(descriptor)
            descriptor = child
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw systemError("Cannot inspect the preferences directory") }
        guard metadata.st_uid == geteuid() else {
            throw PreferencesError("The preferences directory must be owned by your user. Check its ownership before trying again.")
        }
        keepDescriptor = true
        return descriptor
    }

    private static func canonicalParent(of directory: URL) -> URL {
        var ancestor = directory.deletingLastPathComponent()
        var missing: [String] = []
        var metadata = stat()
        while lstat(ancestor.path, &metadata) != 0 && errno == ENOENT && ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        // Foundation deliberately retains /var on macOS even though it is a
        // symlink; descriptor traversal needs the actual /private/var path.
        var resolved = ancestor
        if let path = realpath(ancestor.path, nil) {
            resolved = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            free(path)
        }
        for component in missing.reversed() { resolved.appendPathComponent(component, isDirectory: true) }
        return resolved
    }

    private static func decode(_ data: Data) throws -> RetrySettings {
        do { return try decodeObject(JSONSerialization.jsonObject(with: data)) }
        catch {
            throw PreferencesError("Invalid settings.json: \(error.localizedDescription) Correct the file before saving preferences.")
        }
    }

    private static func decodeObject(_ value: Any) throws -> RetrySettings {
        guard let object = value as? [String: Any],
              Set(object.keys) == Set(["retry_seconds", "scan_seconds", "message"]) else {
            throw PreferencesError("Settings must contain exactly retry_seconds, scan_seconds, and message.")
        }
        guard let retry = integer(object["retry_seconds"]), (60...86400).contains(retry) else {
            throw PreferencesError("retry_seconds must be an integer from 60 to 86400 seconds.")
        }
        guard let scan = integer(object["scan_seconds"]), (15...3600).contains(scan) else {
            throw PreferencesError("scan_seconds must be an integer from 15 to 3600 seconds.")
        }
        guard let message = object["message"] as? String else {
            throw PreferencesError("message must contain nonblank text of at most 4000 characters.")
        }
        let settings = RetrySettings(retrySeconds: retry, scanSeconds: scan, message: message)
        try validate(settings)
        return settings
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        // JSONDecoder accepts 300.0 as Int. NSNumber retains JSON number type, so
        // reject floating point and Boolean tokens before constructing settings.
        guard ["s", "i", "l", "q", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) else { return nil }
        return Int(number.stringValue)
    }

    private static func validate(_ settings: RetrySettings) throws {
        guard (60...86400).contains(settings.retrySeconds) else {
            throw PreferencesError("retry_seconds must be an integer from 60 to 86400 seconds.")
        }
        guard (15...3600).contains(settings.scanSeconds) else {
            throw PreferencesError("scan_seconds must be an integer from 15 to 3600 seconds.")
        }
        let scalars = settings.message.unicodeScalars
        guard scalars.count <= 4000, scalars.contains(where: { !isPythonWhitespace($0.value) }) else {
            throw PreferencesError("message must contain nonblank text of at most 4000 characters.")
        }
    }

    private static func isPythonWhitespace(_ value: UInt32) -> Bool {
        switch value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    private func systemError(_ action: String) -> PreferencesError {
        let detail = String(cString: strerror(errno))
        return PreferencesError("\(action): \(detail). Check \(directory.path) and try again.")
    }
}
