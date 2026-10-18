import Foundation
import Darwin

public enum NativePaths {
    public static var stateDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["IBRIDGE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iBridge", isDirectory: true)
    }

    public static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), chmod(url.path, 0o700) == 0 else {
            throw NativeError("configuration_error", "The application state directory must be a private directory owned by this user.", status: 503)
        }
    }
}

/// One request per connection. Work is bounded independently from socket clients;
/// a disconnected client never causes an automatic retry of a native operation.
public final class UnixSocketServer {
    public typealias Handler = (NativeRequest) async -> JSONObject
    private let directory: URL
    private let mutex = NSLock()
    private let slots = DispatchSemaphore(value: 8)
    private var listener: Int32 = -1
    private var lockFile: Int32 = -1
    private var socketInode: ino_t = 0
    private var stopped = true
    private let queue = DispatchQueue(label: "ca.onpointit.ibridge.socket", qos: .userInitiated)

    public init(stateDirectory: URL) { directory = stateDirectory }
    deinit { stop() }

    public func start(handler: @escaping Handler) throws {
        try NativePaths.prepareDirectory(directory)
        let path = directory.appendingPathComponent("host.sock").path
        guard path.utf8.count < 104 else {
            throw NativeError("configuration_error", "The application state path is too long for a Unix socket.", status: 503)
        }
        let lockPath = directory.appendingPathComponent("host.lock").path
        lockFile = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var lockInfo = stat()
        guard lockFile >= 0, fstat(lockFile, &lockInfo) == 0,
              lockInfo.st_uid == geteuid(), (lockInfo.st_mode & S_IFMT) == S_IFREG,
              fchmod(lockFile, 0o600) == 0, flock(lockFile, LOCK_EX | LOCK_NB) == 0 else {
            if lockFile >= 0 { close(lockFile); lockFile = -1 }
            throw NativeError("already_running", "The native host is already running or its lock is unavailable.", status: 503)
        }
        do {
            var previous = stat()
            if lstat(path, &previous) == 0 {
                guard (previous.st_mode & S_IFMT) == S_IFSOCK, previous.st_uid == geteuid() else {
                    throw NativeError("configuration_error", "The native socket location is occupied by an unexpected file.", status: 503)
                }
                // An active listener that predates this lock must also be preserved.
                let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                if probe >= 0 {
                    _ = fcntl(probe, F_SETFL, O_NONBLOCK)
                    let connected = Self.withAddress(path) { connect(probe, $0, $1) } == 0
                    let pending = errno == EINPROGRESS || errno == EAGAIN
                    close(probe)
                    if connected || pending { throw NativeError("already_running", "The native host is already running.", status: 503) }
                }
                guard unlink(path) == 0 else {
                    throw NativeError("configuration_error", "A stale native socket could not be removed.", status: 503)
                }
            } else if errno != ENOENT {
                throw NativeError("configuration_error", "The native socket location cannot be inspected.", status: 503)
            }
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw Self.socketError() }
            _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
            guard Self.withAddress(path, { bind(listener, $0, $1) }) == 0 else { throw Self.socketError() }
            var created = stat()
            guard lstat(path, &created) == 0 else { throw Self.socketError() }
            socketInode = created.st_ino
            guard chmod(path, 0o600) == 0, listen(listener, 16) == 0 else { throw Self.socketError() }
            mutex.lock(); stopped = false; mutex.unlock()
            let fd = listener
            queue.async { [weak self] in self?.acceptConnections(fd, handler: handler) }
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        mutex.lock()
        stopped = true
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
        let path = directory.appendingPathComponent("host.sock").path
        var info = stat()
        if socketInode != 0, lstat(path, &info) == 0, info.st_ino == socketInode,
           info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFSOCK { _ = unlink(path) }
        socketInode = 0
        if lockFile >= 0 { _ = flock(lockFile, LOCK_UN); close(lockFile); lockFile = -1 }
        mutex.unlock()
    }

    private func acceptConnections(_ fd: Int32, handler: @escaping Handler) {
        while true {
            mutex.lock(); let shouldStop = stopped; mutex.unlock()
            if shouldStop { return }
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
                close(client)
                continue
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let response = ResponseChannel(client)
            guard slots.wait(timeout: .now()) == .success else {
                response.finish(["id": NSNull(), "error": NativeError("busy", "The native host is busy.", status: 503).json])
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    let request = try NativeRequest.decode(Self.readFrame(client))
                    DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                        response.finish(["id": request.id, "error": NativeError("timeout", "The native operation deadline was exceeded.", status: 503, outcome: request.isWrite ? "unknown" : "none").json])
                    }
                    Task {
                        let result = await handler(request)
                        response.finish(result)
                        slots.signal()
                    }
                } catch {
                    let native = error as? NativeError ?? NativeError("invalid_request", "The native request is invalid.")
                    response.finish(["id": NSNull(), "error": native.json])
                    slots.signal()
                }
            }
        }
    }

    private static func readFrame(_ fd: Int32) throws -> Data {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8_192)
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw NativeError("timeout", "The request receive deadline was exceeded.", status: 503) }
            var timeout = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1_000_000))
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let count = recv(fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw NativeError("invalid_request", "A complete native request was not received.") }
            if let newline = bytes[..<count].firstIndex(of: 10) {
                guard newline == count - 1, data.count + newline <= 1_048_576 else {
                    throw NativeError("invalid_request", "Exactly one bounded JSON request is required.")
                }
                data.append(contentsOf: bytes[..<newline])
                return data
            }
            data.append(contentsOf: bytes[..<count])
            guard data.count <= 1_048_576 else { throw NativeError("too_large", "The native request exceeds its size limit.", status: 413) }
        }
    }

    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { target in
                _ = path.withCString { source in strlcpy(target, source, 104) }
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private static func socketError() -> NativeError {
        NativeError("configuration_error", "The native listener could not be started.", status: 503)
    }
}

private final class ResponseChannel {
    private let mutex = NSLock()
    private var fd: Int32
    init(_ fd: Int32) { self.fd = fd }

    func finish(_ object: JSONObject) {
        mutex.lock(); defer { mutex.unlock() }
        guard fd >= 0 else { return }
        defer { shutdown(fd, SHUT_RDWR); close(fd); fd = -1 }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        if data.isEmpty || data.count > 2_097_151 {
            let failure: JSONObject = ["id": object["id"] ?? NSNull(), "error": NativeError("response_too_large", "The operation response could not be represented within its size limit.", status: 503, outcome: "unknown").json]
            data = (try? JSONSerialization.data(withJSONObject: failure)) ?? Data()
        }
        data.append(10)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while offset < raw.count {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { break }
                var timeout = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1_000_000))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                let count = send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                offset += count
            }
        }
    }
}
