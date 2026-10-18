import XCTest
import Foundation
import Darwin
@testable import IBridgeCore

final class DriveAdapterTests: XCTestCase {
    private struct Fixture {
        let base: URL
        let root: URL
        let outside: URL
        let adapter: DriveAdapter
    }

    @MainActor
    private func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ibridge-drive-tests-" + UUID().uuidString)
        let root = base.appendingPathComponent("selected")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return Fixture(base: base, root: root, outside: outside,
                       adapter: try DriveAdapter(testRoots: ["allowed": root]))
    }

    @MainActor
    private func request(_ operation: String, _ arguments: JSONObject = [:],
                         policy: [String] = ["allowed"]) -> NativeRequest {
        var arguments = arguments
        if operation != "drive.roots", arguments["root_id"] == nil { arguments["root_id"] = "allowed" }
        return NativeRequest(id: UUID().uuidString, operation: operation, arguments: arguments,
                             resources: ResourcePolicy(["drive_root_ids": policy]),
                             requestID: operation == "drive.upload" ? UUID().uuidString : nil)
    }

    @MainActor
    private func rejects(_ adapter: DriveAdapter, _ request: NativeRequest,
                         statuses: Set<Int>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await adapter.execute(request)
            XCTFail("Expected the operation to be rejected", file: file, line: line)
        } catch let error as NativeError {
            XCTAssertTrue(statuses.contains(error.status), "Unexpected status \(error.status): \(error.code)", file: file, line: line)
            XCTAssertEqual(error.outcome, "none", file: file, line: line)
        } catch {
            XCTFail("Unexpected error type", file: file, line: line)
        }
    }

    @MainActor
    func testRootPoliciesAreEnforcedForDiscoveryAndOperations() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let hidden = try await f.adapter.execute(request("drive.roots", policy: []))
        XCTAssertEqual((hidden["items"] as? [JSONObject])?.count, 0)
        let visible = try await f.adapter.execute(request("drive.roots"))
        XCTAssertEqual((visible["items"] as? [JSONObject])?.first?["id"] as? String, "allowed")
        XCTAssertEqual(f.adapter.capabilities(ResourcePolicy())["drive.read"], false)
        XCTAssertEqual(f.adapter.capabilities(ResourcePolicy(["drive_root_ids": ["*"]]))["drive.read"], true)
        await rejects(f.adapter, request("drive.list", policy: []), statuses: [403])
        await rejects(f.adapter, request("drive.upload", ["path": "forbidden.txt", "content_base64": ""], policy: []), statuses: [403])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("forbidden.txt").path))
        await rejects(f.adapter, request("drive.list", ["root_id": "missing"], policy: ["missing"]), statuses: [404])
    }

    @MainActor
    func testUploadCreatesPrivateFileAndReadReturnsExactBytes() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let bytes = Data([0, 1, 2, 128, 255])
        let uploaded = try await f.adapter.execute(request("drive.upload", ["path": "sample.ibridgebinaryfixture", "content_base64": bytes.base64EncodedString()]))
        XCTAssertEqual(uploaded["state"] as? String, "saved")
        XCTAssertFalse((uploaded["id"] as? String ?? "").isEmpty)
        let file = f.root.appendingPathComponent("sample.ibridgebinaryfixture")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let read = try await f.adapter.execute(request("drive.read", ["path": "sample.ibridgebinaryfixture", "max_bytes": bytes.count]))
        XCTAssertEqual(read["state"] as? String, "ready")
        XCTAssertEqual(read["content_base64"] as? String, bytes.base64EncodedString())
        XCTAssertEqual(read["size_bytes"] as? Int, bytes.count)
        XCTAssertEqual(read["media_type"] as? String, "application/octet-stream")
    }

    @MainActor
    func testExistingDestinationCannotBeOverwritten() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let original = Data("preserve this".utf8)
        let file = f.root.appendingPathComponent("existing.txt")
        try original.write(to: file)
        await rejects(f.adapter, request("drive.upload", ["path": "existing.txt", "content_base64": Data("replace".utf8).base64EncodedString()]), statuses: [409])
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testUploadsAllowEmptyFilesButRejectOversizeAndNoncanonicalContent() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let saved = try await f.adapter.execute(request("drive.upload", ["path": "empty", "content_base64": ""]))
        XCTAssertEqual(saved["state"] as? String, "saved")
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("empty")).count, 0)
        for encoded in ["Zh==", "!!!!", Data(repeating: 1, count: 262_145).base64EncodedString()] {
            await rejects(f.adapter, request("drive.upload", ["path": "invalid", "content_base64": encoded]), statuses: [400])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("invalid").path))
    }

    @MainActor
    func testReadRejectsOversizeInsteadOfTruncating() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let data = Data(repeating: 7, count: 262_144)
        try data.write(to: f.root.appendingPathComponent("limit.bin"))
        let result = try await f.adapter.execute(request("drive.read", ["path": "limit.bin"]))
        XCTAssertEqual(result["size_bytes"] as? Int, 262_144)
        await rejects(f.adapter, request("drive.read", ["path": "limit.bin", "max_bytes": 262_143]), statuses: [413])
        try Data(repeating: 8, count: 262_145).write(to: f.root.appendingPathComponent("large.bin"))
        await rejects(f.adapter, request("drive.read", ["path": "large.bin"]), statuses: [413])
    }

    @MainActor
    func testUnsafePathsAreRejectedBeforeFileCreation() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        for path in ["../outside/escape", "/tmp/escape", "folder//name", "folder/../name", "folder/", "folder\\name", ".", ""] {
            await rejects(f.adapter, request("drive.upload", ["path": path, "content_base64": ""]), statuses: [400])
            await rejects(f.adapter, request("drive.read", ["path": path]), statuses: [400])
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.outside.path), [])
    }

    @MainActor
    func testSymlinkParentCannotEscapeForReadUploadOrListing() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try Data("outside".utf8).write(to: f.outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("escape"), withDestinationURL: f.outside)
        await rejects(f.adapter, request("drive.read", ["path": "escape/secret.txt"]), statuses: [403, 404])
        await rejects(f.adapter, request("drive.upload", ["path": "escape/new.txt", "content_base64": ""]), statuses: [403, 404])
        await rejects(f.adapter, request("drive.list", ["path": "escape"]), statuses: [403, 404])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.outside.appendingPathComponent("new.txt").path))
        let listing = try await f.adapter.execute(request("drive.list"))
        XCTAssertEqual((listing["items"] as? [JSONObject])?.count, 0)
    }

    @MainActor
    func testSymlinkFileCannotBeReadOrOverwritten() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let file = f.outside.appendingPathComponent("secret.txt")
        let original = Data("outside content".utf8)
        try original.write(to: file)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("link"), withDestinationURL: file)
        await rejects(f.adapter, request("drive.read", ["path": "link"]), statuses: [400, 403])
        await rejects(f.adapter, request("drive.upload", ["path": "link", "content_base64": ""]), statuses: [409])
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testDirectoryAndFIFOAreNotReadableFiles() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        XCTAssertEqual(mkfifo(f.root.appendingPathComponent("pipe").path, 0o600), 0)
        await rejects(f.adapter, request("drive.read", ["path": "folder"]), statuses: [400])
        await rejects(f.adapter, request("drive.read", ["path": "pipe"]), statuses: [400])
    }

    @MainActor
    func testListingPaginationIsStableAndBoundToDirectoryContents() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        for name in ["c.txt", "a.txt", "b.txt"] { try Data().write(to: f.root.appendingPathComponent(name)) }
        let first = try await f.adapter.execute(request("drive.list", ["limit": 2]))
        XCTAssertEqual((first["items"] as? [JSONObject])?.compactMap { $0["name"] as? String }, ["a.txt", "b.txt"])
        let cursor = try XCTUnwrap(first["next_cursor"] as? String)
        let second = try await f.adapter.execute(request("drive.list", ["limit": 2, "cursor": cursor]))
        XCTAssertEqual((second["items"] as? [JSONObject])?.compactMap { $0["name"] as? String }, ["c.txt"])
        XCTAssertNil(second["next_cursor"])
        try Data().write(to: f.root.appendingPathComponent("d.txt"))
        await rejects(f.adapter, request("drive.list", ["limit": 2, "cursor": cursor]), statuses: [400])
    }

    @MainActor
    func testSearchFindsNestedNamesWithoutFollowingSymlinks() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let folder = f.root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data().write(to: folder.appendingPathComponent("Report.txt"))
        try Data().write(to: f.outside.appendingPathComponent("Report-secret.txt"))
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("linked"), withDestinationURL: f.outside)
        let result = try await f.adapter.execute(request("drive.search", ["query": "report"]))
        XCTAssertEqual((result["items"] as? [JSONObject])?.compactMap { $0["path"] as? String }, ["reports", "reports/Report.txt"])
        XCTAssertEqual(result["scan_truncated"] as? Bool, false)
        XCTAssertEqual(result["search_scope"] as? String, "file_names")
    }

    @MainActor
    func testSearchExplicitlyReportsItsDepthBound() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        var nested = f.root
        for _ in 0..<20 { nested.appendPathComponent("nested") }
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("beyond-search-bound.txt"))
        let result = try await f.adapter.execute(request("drive.search", ["query": "beyond-search-bound"]))
        XCTAssertEqual(result["scan_truncated"] as? Bool, true)
        XCTAssertEqual((result["items"] as? [JSONObject])?.count, 0)
    }

    @MainActor
    func testBookmarkStorePersistsSelectionPrivatelyAndSupportsRemoval() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let state = f.base.appendingPathComponent("state")
        let original = try DriveAdapter(stateDirectory: state)
        try original.addRoot(f.root)
        let identifier = try XCTUnwrap(original.selectedRoots.first?["id"] as? String)
        let attributes = try FileManager.default.attributesOfItem(atPath: state.appendingPathComponent("drive-bookmarks.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let restored = try DriveAdapter(stateDirectory: state)
        XCTAssertEqual(restored.selectedRoots.first?["id"] as? String, identifier)
        let listing = try await restored.execute(request("drive.list", ["root_id": identifier], policy: [identifier]))
        XCTAssertEqual((listing["items"] as? [JSONObject])?.count, 0)
        try restored.removeRoot(id: identifier)
        XCTAssertEqual(try DriveAdapter(stateDirectory: state).selectedRoots.count, 0)
    }

    @MainActor
    func testBookmarkStoreRejectsSymlinkAndInsecurePermissions() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let state = f.base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let outside = f.outside.appendingPathComponent("untrusted.json")
        try Data("{}".utf8).write(to: outside)
        let store = state.appendingPathComponent("drive-bookmarks.json")
        try FileManager.default.createSymbolicLink(at: store, withDestinationURL: outside)
        XCTAssertThrowsError(try DriveAdapter(stateDirectory: state))
        try FileManager.default.removeItem(at: store)
        XCTAssertEqual(chmod(state.path, 0o755), 0)
        XCTAssertThrowsError(try DriveAdapter(stateDirectory: state))
    }

    @MainActor
    func testSystemTemporaryDirectoryAliasCanBeSelectedWithoutFollowingRemoteSymlinks() async throws {
        // /tmp -> /private/tmp on macOS. Exercise the actual alias after its
        // target directory exists, rather than normalizing a nonexistent URL.
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ibridge-system-alias-" + UUID().uuidString)
        let selected = base.appendingPathComponent("selected")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let adapter = try DriveAdapter(testRoots: ["allowed": selected])
        _ = try await adapter.execute(request("drive.upload", ["path": "safe.txt", "content_base64": "c2FmZQ=="]))
        let read = try await adapter.execute(request("drive.read", ["path": "safe.txt"]))
        XCTAssertEqual(read["content_base64"] as? String, "c2FmZQ==")
        try FileManager.default.createSymbolicLink(at: selected.appendingPathComponent("escape"), withDestinationURL: outside)
        await rejects(adapter, request("drive.upload", ["path": "escape/no.txt", "content_base64": ""]), statuses: [403, 404])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
}
