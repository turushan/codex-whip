import Foundation

/// Validated private preferences, separate from retry state.
public struct Settings: Equatable, Sendable {
    public var retrySeconds: Int
    public var scanSeconds: Int
    public var message: String
    public var soundEnabled: Bool

    public static let defaultMessage = "Keep using the selected model. Continue the unfinished work."
    public static let defaults = Settings(retrySeconds: 180, scanSeconds: 300, message: defaultMessage, soundEnabled: true)

    public init(retrySeconds: Int, scanSeconds: Int, message: String, soundEnabled: Bool) {
        self.retrySeconds = retrySeconds
        self.scanSeconds = scanSeconds
        self.message = message
        self.soundEnabled = soundEnabled
    }

    public var json: JSON {
        ["retry_seconds": .int(retrySeconds), "scan_seconds": .int(scanSeconds),
         "message": .string(message), "sound_enabled": .bool(soundEnabled)]
    }

    /// Accepts the current keys, or the earlier set without sound_enabled, which then means off.
    public static func validate(_ value: JSON) throws -> Settings {
        let required: Set = ["retry_seconds", "scan_seconds", "message"]
        guard let object = value.object,
              Set(object.keys) == required || Set(object.keys) == required.union(["sound_enabled"]) else {
            throw SettingsError("Settings must contain retry_seconds, scan_seconds, message, and optional sound_enabled.")
        }
        var numbers: [String: Int] = [:]
        for (name, lower, upper) in [("retry_seconds", 60, 86400), ("scan_seconds", 15, 3600)] {
            guard let number = object[name]?.int, (lower...upper).contains(number) else {
                throw SettingsError("\(name) must be an integer from \(lower) to \(upper) seconds.")
            }
            numbers[name] = number
        }
        guard let message = object["message"]?.string,
              !message.trimmingCharacters(in: pythonWhitespace).isEmpty,
              message.unicodeScalars.count <= 4000 else {
            throw SettingsError("message must contain nonblank text of at most 4000 characters.")
        }
        let sound: Bool
        switch object["sound_enabled"] {
        case nil: sound = false
        case .bool(let value)?: sound = value
        default: throw SettingsError("sound_enabled must be true or false.")
        }
        return Settings(retrySeconds: numbers["retry_seconds"]!, scanSeconds: numbers["scan_seconds"]!,
                        message: message, soundEnabled: sound)
    }

    public static func read(directory: URL) throws -> Settings {
        let url = directory.appendingPathComponent("settings.json")
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return defaults
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return defaults
        } catch {
            throw SettingsError("Cannot read settings.json: \(error.localizedDescription)")
        }
        let value: JSON
        do {
            value = try JSON.parse(data)
        } catch {
            throw SettingsError("Cannot read settings.json: \(error)")
        }
        do {
            return try validate(value)
        } catch let error as SettingsError {
            throw SettingsError("Invalid settings.json: \(error.description)")
        }
    }

    @discardableResult
    public static func save(_ value: JSON, directory: URL) throws -> Settings {
        let settings = try validate(value)
        do {
            try FileStore.makePrivateDirectory(directory)
            try FileStore.writeAtomically(Data((try settings.json.serialized(.pretty) + "\n").utf8),
                                          to: directory.appendingPathComponent("settings.json"),
                                          temporaryPrefix: ".settings-")
        } catch let error as SettingsError {
            throw error
        } catch {
            throw SettingsError("Cannot save settings.json: \(error.localizedDescription)")
        }
        return settings
    }

    public static func envelope(directory: URL) throws -> JSON {
        ["settings": try read(directory: directory).json, "defaults": defaults.json]
    }
}

public struct SettingsError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// Changing cadence is measured from the last finished scan, never from settings edits.
public struct ScanScheduler: Sendable {
    public private(set) var lastScan: Double?

    public init() {}

    public func due(_ now: Double, interval: Int) -> Bool {
        guard let lastScan else { return true }
        return now - lastScan >= Double(interval)
    }

    public mutating func finished(_ now: Double) {
        lastScan = now
    }
}

/// The characters Python's str.strip removes, so "blank" means the same in both engines.
let pythonWhitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{1C}\u{1D}\u{1E}\u{1F}"))
