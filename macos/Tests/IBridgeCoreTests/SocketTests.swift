import Darwin
import Foundation
import XCTest
@testable import IBridgeCore

final class SocketTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: "/tmp/ib-" + UUID().uuidString.prefix(8), isDirectory: true)
    }

    func testPrivateSocketRoundTripAndActiveListenerProtection() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(stateDirectory: directory)
        try server.start { request in ["id": request.id, "result": ["operations": [:]]] }
        defer { server.stop() }
        let other = UnixSocketServer(stateDirectory: directory)
        XCTAssertThrowsError(try other.start { _ in [:] })
        var info = stat()
        XCTAssertEqual(lstat(directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let path = directory.appendingPathComponent("host.sock").path
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let response = try exchange(path: path, data: Data("{\"id\":\"rpc-1\",\"operation\":\"system.capabilities\",\"arguments\":{},\"resources\":{}}\n".utf8))
        XCTAssertEqual(response["id"] as? String, "rpc-1")
        XCTAssertNotNil(response["result"])
    }

    func testInvalidFrameDoesNotInvokeHandler() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UnixSocketServer(stateDirectory: directory)
        try server.start { _ in XCTFail("Malformed requests must not reach adapters"); return [:] }
        defer { server.stop() }
        let response = try exchange(path: directory.appendingPathComponent("host.sock").path, data: Data("not-json\n".utf8))
        let error = try XCTUnwrap(response["error"] as? JSONObject)
        XCTAssertEqual(error["outcome"] as? String, "none")
        XCTAssertEqual(error["status"] as? Int, 400)
    }

    func testNeverDeletesUnexpectedSocketPathOrDirectorySymlink() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try NativePaths.prepareDirectory(directory)
        let occupied = directory.appendingPathComponent("host.sock")
        let original = Data("keep me".utf8)
        try original.write(to: occupied)
        let server = UnixSocketServer(stateDirectory: directory)
        XCTAssertThrowsError(try server.start { _ in [:] })
        XCTAssertEqual(try Data(contentsOf: occupied), original)
        let linked = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: linked) }
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: directory)
        XCTAssertThrowsError(try NativePaths.prepareDirectory(linked))
    }

    private func exchange(path: String, data: Data) throws -> JSONObject {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket-test", code: 1) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { target in
                _ = path.withCString { strlcpy(target, $0, 104) }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw NSError(domain: "socket-test", code: 2) }
        let sent = data.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == data.count else { throw NSError(domain: "socket-test", code: 3) }
        var response = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { throw NSError(domain: "socket-test", code: 4) }
            response.append(contentsOf: bytes[..<count])
            if response.last == 10 { break }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? JSONObject)
    }
}
