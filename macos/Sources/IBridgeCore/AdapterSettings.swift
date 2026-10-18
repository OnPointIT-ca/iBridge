import Foundation
import Darwin

/// Local consent is separate from both macOS permissions and remote token scopes.
/// This file is never writable through the bridge protocol.
@MainActor
public final class AdapterSettings {
    private struct Document: Codable {
        var version = 1
        var notesEnabled = false
        var messagesEnabled = false
    }

    private var document: Document
    private let directory: Int32
    private static let filename = "adapter-settings.json"

    public var notesEnabled: Bool { document.notesEnabled }
    public var messagesEnabled: Bool { document.messagesEnabled }

    public init(stateDirectory: URL) throws {
        try NativePaths.prepareDirectory(stateDirectory)
        let fd = open(stateDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        do {
            document = try Self.load(fd)
            directory = fd
        } catch {
            close(fd)
            throw error
        }
    }

    deinit { close(directory) }

    public func setNotesEnabled(_ enabled: Bool) throws {
        var updated = document
        updated.notesEnabled = enabled
        try save(updated)
        document = updated
    }

    public func setMessagesEnabled(_ enabled: Bool) throws {
        var updated = document
        updated.messagesEnabled = enabled
        try save(updated)
        document = updated
    }

    private static func load(_ directory: Int32) throws -> Document {
        let fd = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return Document() }
            throw failure()
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= 4_096 else { throw failure() }
        var bytes = [UInt8](repeating: 0, count: 4_097)
        var size = 0
        while size < bytes.count {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!.advanced(by: size), $0.count - size)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure() }
            if count == 0 { break }
            size += count
        }
        guard size <= 4_096,
              let saved = try? JSONDecoder().decode(Document.self, from: Data(bytes.prefix(size))),
              saved.version == 1 else { throw failure() }
        return saved
    }

    private func save(_ updated: Document) throws {
        let data = try JSONEncoder().encode(updated)
        let temporary = ".adapter-settings-\(UUID().uuidString).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure() }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.failure() }
                offset += count
            }
        }
        guard fsync(fd) == 0,
              renameat(directory, temporary, directory, Self.filename) == 0 else { throw Self.failure() }
        if fsync(directory) != 0 && errno != EINVAL { throw Self.failure() }
    }

    private static func failure() -> NativeError {
        NativeError("configuration_error", "Local adapter settings could not be loaded or saved securely.", status: 503)
    }
}
