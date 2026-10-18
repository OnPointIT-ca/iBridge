import Foundation
import Darwin
import UniformTypeIdentifiers

/// Access is granted only by the local directory picker. Remote paths are always
/// resolved one component at a time relative to an authorized directory descriptor.
@MainActor
public final class DriveAdapter {
    private struct Root: Codable {
        let id: String
        let name: String
        var bookmark: Data
    }
    private struct Store: Codable {
        let version: Int
        let roots: [Root]
    }

    private var roots: [Root]
    private let stateDescriptor: Int32
    private let testRoots: [String: URL]
    private static let storeName = "drive-bookmarks.json"
    private static let maximumBytes = 262_144
    private static let maximumEntries = 10_000
    private static let maximumDirectories = 1_024
    private static let maximumDepth = 16

    public init(stateDirectory: URL) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = open(stateDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DriveFS.error() }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                throw NativeError("unavailable", "The Drive state directory must be private to its owner.", status: 503)
            }
            let saved = try Self.load(from: descriptor)
            self.roots = saved
            self.stateDescriptor = descriptor
            self.testRoots = [:]
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Test-only construction avoids permission prompts and fake security-scoped
    /// bookmarks. It uses exactly the production descriptor traversal and I/O.
    init(testRoots: [String: URL]) throws {
        self.stateDescriptor = -1
        self.testRoots = try testRoots.mapValues { try DriveFS.canonicalDirectoryURL($0) }
        self.roots = testRoots.sorted { $0.key < $1.key }.map {
            Root(id: $0.key, name: $0.value.lastPathComponent, bookmark: Data())
        }
    }

    deinit { if stateDescriptor >= 0 { close(stateDescriptor) } }

    public var selectedRoots: [JSONObject] {
        roots.map { ["id": $0.id, "name": $0.name] }
    }

    public func addRoot(_ url: URL) throws {
        guard stateDescriptor >= 0, url.isFileURL, roots.count < 64 else {
            throw NativeError("invalid_arguments", "Select a local directory; at most 64 roots can be authorized.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Resolve aliases chosen by the owner once, before creating the bookmark.
        // Requests never resolve symlinks supplied in remote paths.
        let canonical = try DriveFS.canonicalDirectoryURL(url)
        let descriptor = try DriveFS.openAbsoluteDirectory(canonical)
        close(descriptor)
        let bookmark: Data
        do {
            bookmark = try canonical.bookmarkData(options: [.withSecurityScope],
                                                  includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw NativeError("unavailable", "The selected directory could not be authorized.", status: 503)
        }
        let root = Root(id: UUID().uuidString.lowercased(), name: canonical.lastPathComponent, bookmark: bookmark)
        let updated = roots + [root]
        try save(updated)
        roots = updated
    }

    public func removeRoot(id: String) throws {
        let updated = roots.filter { $0.id != id }
        try save(updated)
        roots = updated
    }

    public func capabilities(_ policy: ResourcePolicy) -> [String: Bool] {
        let snapshot = roots
        let available = snapshot.contains { root in
            guard policy.allows(.driveRoots, id: root.id) else { return false }
            return (try? withRoot(root.id) { _, _ in true }) ?? false
        }
        return ["drive.roots": true, "drive.list": available, "drive.search": available,
                "drive.read": available, "drive.upload": available]
    }

    public func execute(_ request: NativeRequest) async throws -> JSONObject {
        // Defend this API when invoked directly, as well as through RPC decoding.
        try NativeValidation.validate(request)
        if request.operation == "drive.roots" {
            let allowed = selectedRoots.filter {
                request.resources.allows(.driveRoots, id: $0["id"] as? String ?? "")
            }
            return try Pagination.page(allowed, arguments: request.arguments, context: "drive.roots")
        }
        let rootID = NativeValidation.string(request.arguments, "root_id")
        guard request.resources.allows(.driveRoots, id: rootID) else {
            throw NativeError("permission_denied", "This Drive root is not authorized.", status: 403)
        }
        return try withRoot(rootID) { descriptor, url in
            switch request.operation {
            case "drive.list":
                let path = NativeValidation.optionalString(request.arguments, "path") ?? ""
                try NativeValidation.relativePath(path, allowEmpty: true)
                let directory = try DriveFS.openDirectory(root: descriptor, path: path)
                defer { close(directory) }
                var budget = Self.maximumEntries
                let (items, limited) = try scan(directory, rootID: rootID, path: path, budget: &budget)
                guard !limited else {
                    throw NativeError("scan_limit_exceeded", "This directory exceeds the 10000-entry listing limit.", status: 413)
                }
                return try Pagination.page(items, arguments: request.arguments, context: "drive.list:\(rootID):\(path)")
            case "drive.search":
                return try search(root: descriptor, rootID: rootID, arguments: request.arguments)
            case "drive.read":
                return try read(root: descriptor, rootURL: url, arguments: request.arguments)
            case "drive.upload":
                return try upload(root: descriptor, rootID: rootID, arguments: request.arguments)
            default:
                throw NativeError("unavailable", "This Drive operation is unavailable.", status: 503)
            }
        }
    }

    private func withRoot<T>(_ id: String, _ body: (Int32, URL) throws -> T) throws -> T {
        guard let index = roots.firstIndex(where: { $0.id == id }) else {
            throw NativeError("not_found", "The selected Drive root is unavailable.", status: 404)
        }
        let url: URL
        var scoped = false
        if let testURL = testRoots[id] {
            url = testURL
        } else {
            var stale = false
            do {
                url = try URL(resolvingBookmarkData: roots[index].bookmark,
                              options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
                scoped = url.startAccessingSecurityScopedResource()
            } catch {
                throw NativeError("permission_denied", "Select this Drive directory again on the Mac.", status: 403)
            }
            if stale {
                do {
                    let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                                        includingResourceValuesForKeys: nil, relativeTo: nil)
                    var updated = roots
                    updated[index].bookmark = bookmark
                    try save(updated)
                    roots = updated
                } catch {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    throw NativeError("unavailable", "The Drive authorization could not be refreshed.", status: 503)
                }
            }
        }
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Bookmark resolution can reintroduce the system /var or /tmp aliases.
        // Only the owner-selected bookmark root is canonicalized; remote path
        // components remain subject to descriptor-relative O_NOFOLLOW traversal.
        let canonical: URL
        if testRoots[id] == nil { canonical = try DriveFS.canonicalDirectoryURL(url) }
        else { canonical = url }
        let descriptor = try DriveFS.openAbsoluteDirectory(canonical)
        defer { close(descriptor) }
        return try body(descriptor, canonical)
    }

    private func scan(_ directory: Int32, rootID: String, path: String,
                      budget: inout Int) throws -> ([JSONObject], Bool) {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw DriveFS.error() }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw DriveFS.error() }
        defer { closedir(stream) }
        var items: [JSONObject] = []
        while true {
            errno = 0
            guard let pointer = readdir(stream) else {
                if errno != 0 { throw DriveFS.error() }
                break
            }
            var entry = pointer.pointee
            let name = withUnsafePointer(to: &entry.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name, name != ".", name != ".." else { continue }
            guard budget > 0 else { return (items.sorted(by: Self.sortItems), true) }
            budget -= 1
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw DriveFS.error()
            }
            let kind = info.st_mode & S_IFMT
            // Symlinks, sockets, FIFOs, and devices are never exposed as files.
            guard kind == S_IFREG || kind == S_IFDIR else { continue }
            let relative = path.isEmpty ? name : path + "/" + name
            var item: JSONObject = ["id": rootID + ":" + relative, "root_id": rootID,
                                    "name": name, "path": relative,
                                    "kind": kind == S_IFDIR ? "directory" : "file"]
            if kind == S_IFREG { item["size_bytes"] = Int64(info.st_size) }
            items.append(item)
        }
        return (items.sorted(by: Self.sortItems), false)
    }

    private static func sortItems(_ lhs: JSONObject, _ rhs: JSONObject) -> Bool {
        (lhs["path"] as? String ?? "") < (rhs["path"] as? String ?? "")
    }

    private func search(root: Int32, rootID: String, arguments: JSONObject) throws -> JSONObject {
        let query = NativeValidation.string(arguments, "query")
        var queue: [(String, Int)] = [("", 0)]
        var next = 0
        var remaining = Self.maximumEntries
        var limited = false
        var matches: [JSONObject] = []
        while next < queue.count, remaining > 0, next < Self.maximumDirectories {
            let (path, depth) = queue[next]
            next += 1
            let directory: Int32
            do { directory = try DriveFS.openDirectory(root: root, path: path) }
            catch { limited = true; continue } // Removed, unreadable, or replaced directory.
            let items: [JSONObject]
            do {
                let result = try scan(directory, rootID: rootID, path: path, budget: &remaining)
                items = result.0
                limited = limited || result.1
                close(directory)
            } catch { close(directory); throw error }
            for item in items {
                let name = item["name"] as? String ?? ""
                if name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { matches.append(item) }
                if item["kind"] as? String == "directory" {
                    if depth < Self.maximumDepth, queue.count < Self.maximumDirectories {
                        queue.append((item["path"] as? String ?? "", depth + 1))
                    } else { limited = true }
                }
            }
        }
        if next < queue.count { limited = true }
        var result = try Pagination.page(matches.sorted(by: Self.sortItems), arguments: arguments,
                                         context: "drive.search:\(rootID):\(query)")
        result["scan_truncated"] = limited
        result["search_scope"] = "file_names"
        return result
    }

    private func read(root: Int32, rootURL: URL, arguments: JSONObject) throws -> JSONObject {
        let path = NativeValidation.string(arguments, "path")
        try NativeValidation.relativePath(path)
        let maximum = arguments["max_bytes"] as? Int ?? Self.maximumBytes
        guard (1...Self.maximumBytes).contains(maximum) else {
            throw NativeError("invalid_arguments", "The file read limit is invalid.")
        }
        let (parent, name) = try DriveFS.openParent(root: root, path: path)
        defer { close(parent) }
        // O_EVTONLY obtains identity without opening a cloud placeholder for data.
        let metadataDescriptor = openat(parent, name, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard metadataDescriptor >= 0 else { throw DriveFS.error() }
        defer { close(metadataDescriptor) }
        var info = stat()
        guard fstat(metadataDescriptor, &info) == 0 else { throw DriveFS.error() }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw NativeError("invalid_arguments", "Only regular files can be read.")
        }
        guard info.st_size >= 0, info.st_size <= maximum else {
            throw NativeError("too_large", "The file exceeds the requested read limit.", status: 413)
        }
        let fileURL = rootURL.appendingPathComponent(path)
        if try requestDownloadIfNeeded(fileURL, identity: info) {
            return ["state": "downloading"]
        }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw DriveFS.error() }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw DriveFS.error() }
        guard DriveFS.sameFile(info, opened), opened.st_mode & S_IFMT == S_IFREG else {
            throw NativeError("conflict", "The file changed while it was being opened.", status: 409)
        }
        let data = try DriveFS.readBounded(descriptor, maximum: maximum)
        var finished = stat()
        guard fstat(descriptor, &finished) == 0 else { throw DriveFS.error() }
        guard finished.st_size == opened.st_size,
              finished.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              finished.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else {
            throw NativeError("conflict", "The file changed during the read; request it again.", status: 409)
        }
        let type = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return ["state": "ready", "content_base64": data.base64EncodedString(),
                "size_bytes": data.count, "media_type": type]
    }

    private func requestDownloadIfNeeded(_ url: URL, identity: stat) throws -> Bool {
        // Foundation's iCloud API takes a URL, not a descriptor. A file-reference
        // URL follows the original file identity if an ancestor is renamed or
        // replaced. Verify its target against the securely opened descriptor;
        // never dispatch a download using the remote request's ordinary path.
        guard let reference = (url as NSURL).fileReferenceURL() else {
            throw NativeError("unavailable", "The file identity could not be determined.", status: 503)
        }
        let referencePath = (reference as NSURL).filePathURL
        guard let referencePath else {
            throw NativeError("unavailable", "The file identity is unavailable.", status: 503)
        }
        let canonicalParent = try DriveFS.canonicalDirectoryURL(referencePath.deletingLastPathComponent())
        let referenceParent = try DriveFS.openAbsoluteDirectory(canonicalParent)
        defer { close(referenceParent) }
        let referenceDescriptor = openat(referenceParent, referencePath.lastPathComponent,
                                         O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard referenceDescriptor >= 0 else { throw DriveFS.error() }
        defer { close(referenceDescriptor) }
        var referenced = stat()
        guard fstat(referenceDescriptor, &referenced) == 0,
              DriveFS.sameFile(identity, referenced), referenced.st_mode & S_IFMT == S_IFREG else {
            throw NativeError("conflict", "The file changed while checking availability.", status: 409)
        }
        let values: URLResourceValues
        do {
            values = try reference.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        } catch {
            throw NativeError("unavailable", "File availability could not be determined.", status: 503)
        }
        guard values.isUbiquitousItem == true,
              values.ubiquitousItemDownloadingStatus != .current,
              values.ubiquitousItemDownloadingStatus != .downloaded else { return false }
        do { try FileManager.default.startDownloadingUbiquitousItem(at: reference) }
        catch { throw NativeError("unavailable", "The cloud download could not be requested.", status: 503) }
        return true
    }

    private func upload(root: Int32, rootID: String, arguments: JSONObject) throws -> JSONObject {
        let path = NativeValidation.string(arguments, "path")
        try NativeValidation.relativePath(path)
        let encoded = NativeValidation.string(arguments, "content_base64")
        guard let data = Data(base64Encoded: encoded), data.count <= Self.maximumBytes,
              data.base64EncodedString() == encoded else {
            throw NativeError("invalid_arguments", "Upload content must be canonical base64 of at most 256 KiB.")
        }
        let (parent, name) = try DriveFS.openParent(root: root, path: path)
        defer { close(parent) }
        let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw DriveFS.error() }
        // From here onward a directory entry exists, including for an empty file.
        // Never remove it or report a definitive rejection after a possible effect.
        do {
            try DriveFS.writeAll(descriptor, data: data)
            guard fsync(descriptor) == 0 else { throw DriveFS.error() }
            let closed = close(descriptor)
            guard closed == 0 else {
                throw NativeError("write_uncertain", "The new file could not be confirmed.", status: 503, outcome: "unknown")
            }
        } catch {
            // A failed close must not close the descriptor a second time.
            if (error as? NativeError)?.code != "write_uncertain" { close(descriptor) }
            throw NativeError("write_uncertain", "The upload may have created a file; reconcile before retrying.", status: 503, outcome: "unknown")
        }
        if fsync(parent) != 0 && errno != EINVAL {
            throw NativeError("write_uncertain", "The uploaded file could not be durably confirmed.", status: 503, outcome: "unknown")
        }
        return ["id": rootID + ":" + path, "state": "saved"]
    }

    private static func load(from directory: Int32) throws -> [Root] {
        let descriptor = openat(directory, storeName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return [] }
            throw DriveFS.error()
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw NativeError("unavailable", "The Drive bookmark store must be a private regular file.", status: 503)
        }
        let data = try DriveFS.readBounded(descriptor, maximum: 1_048_576)
        guard let store = try? JSONDecoder().decode(Store.self, from: data), store.version == 1,
              store.roots.count <= 64,
              Set(store.roots.map(\.id)).count == store.roots.count,
              store.roots.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.bookmark.isEmpty }) else {
            throw NativeError("unavailable", "The Drive bookmark store is invalid.", status: 503)
        }
        return store.roots
    }

    private func save(_ updated: [Root]) throws {
        guard stateDescriptor >= 0 else {
            throw NativeError("unavailable", "Bookmark persistence is unavailable in this test instance.", status: 503)
        }
        let data = try JSONEncoder().encode(Store(version: 1, roots: updated))
        guard data.count <= 1_048_576 else {
            throw NativeError("too_large", "The Drive bookmark store is full.", status: 413)
        }
        let temporary = ".drive-bookmarks-\(UUID().uuidString).tmp"
        let descriptor = openat(stateDescriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw DriveFS.error() }
        defer { close(descriptor); unlinkat(stateDescriptor, temporary, 0) }
        try DriveFS.writeAll(descriptor, data: data)
        guard fsync(descriptor) == 0,
              renameat(stateDescriptor, temporary, stateDescriptor, Self.storeName) == 0 else {
            throw NativeError("unavailable", "The Drive authorization could not be saved.", status: 503)
        }
        if fsync(stateDescriptor) != 0 && errno != EINVAL {
            throw NativeError("unavailable", "The Drive authorization could not be durably saved.", status: 503)
        }
    }
}

private enum DriveFS {
    static func error(_ value: Int32 = errno) -> NativeError {
        switch value {
        case EACCES, EPERM, ELOOP:
            return NativeError("permission_denied", "Access to this file or directory is not permitted.", status: 403)
        case ENOENT, ENOTDIR:
            return NativeError("not_found", "The file or parent directory is unavailable.", status: 404)
        case EEXIST:
            return NativeError("conflict", "The destination already exists; uploads never overwrite files.", status: 409)
        case ENAMETOOLONG:
            return NativeError("invalid_arguments", "The relative path is too long.")
        default:
            return NativeError("unavailable", "The filesystem operation is temporarily unavailable.", status: 503)
        }
    }

    static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    /// The argument must be an owner-selected root, a resolved bookmark, or a
    /// verified file-reference parent, never a remotely supplied relative path.
    /// Foundation standardization may turn /private/var back into /var, so use
    /// POSIX realpath on the existing directory and preserve its exact result.
    static func canonicalDirectoryURL(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.contains("\0") else {
            throw NativeError("invalid_arguments", "A local directory is required.")
        }
        guard let resolved = realpath(url.path, nil) else { throw error() }
        defer { free(resolved) }
        return URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: true, relativeTo: nil)
    }

    static func openAbsoluteDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw NativeError("permission_denied", "The selected directory is unavailable.", status: 403)
        }
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw error() }
        defer { close(root) }
        return try openDirectory(root: root, path: String(url.path.dropFirst()))
    }

    static func openDirectory(root: Int32, path: String) throws -> Int32 {
        var current = dup(root)
        guard current >= 0 else { throw error() }
        do {
            for component in path.split(separator: "/", omittingEmptySubsequences: true) {
                guard component != ".", component != ".." else {
                    throw NativeError("invalid_arguments", "A safe relative path is required.")
                }
                let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw error() }
                close(current)
                current = next
            }
            return current
        } catch { close(current); throw error }
    }

    static func openParent(root: Int32, path: String) throws -> (Int32, String) {
        try NativeValidation.relativePath(path)
        let parts = path.split(separator: "/")
        let parent = try openDirectory(root: root, path: parts.dropLast().joined(separator: "/"))
        return (parent, String(parts.last!))
    }

    static func readBounded(_ descriptor: Int32, maximum: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(65_536, maximum + 1))
        while true {
            let amount = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, maximum + 1 - result.count))
            }
            if amount < 0 {
                if errno == EINTR { continue }
                throw error()
            }
            if amount == 0 { return result }
            result.append(contentsOf: buffer.prefix(amount))
            guard result.count <= maximum else {
                throw NativeError("too_large", "The file exceeds the requested read limit.", status: 413)
            }
        }
    }

    static func writeAll(_ descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw error() }
                offset += amount
            }
        }
    }
}
