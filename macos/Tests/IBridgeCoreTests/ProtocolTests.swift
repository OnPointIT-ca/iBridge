import Foundation
import XCTest
@testable import IBridgeCore

final class ProtocolTests: XCTestCase {
    func testSharedCatalogLoaded() { XCTAssertEqual(NativeValidation.operationNames.count, 20) }

    func testDecodeDenyByDefaultPolicy() throws {
        let request = try decode(["id": "rpc", "operation": "calendar.list", "arguments": [:], "resources": [:]])
        XCTAssertFalse(request.resources.allows(.calendars, id: "personal"))
        XCTAssertFalse(request.resources.hasAny(.driveRoots))
        XCTAssertFalse(request.isWrite)
    }

    func testExplicitWildcardIsServiceSpecific() {
        let policy = ResourcePolicy(["calendar_ids": ["*"], "drive_root_ids": ["root"]])
        XCTAssertTrue(policy.allows(.calendars, id: "personal"))
        XCTAssertFalse(policy.allows(.reminderLists, id: "personal"))
        XCTAssertTrue(policy.allows(.driveRoots, id: "root"))
        XCTAssertFalse(policy.allows(.driveRoots, id: "other"))
    }

    func testUnknownKeysAndInvalidPolicyRejected() {
        let objects: [JSONObject] = [
            ["id": "rpc", "operation": "calendar.list", "arguments": ["shell": "ignored"], "resources": [:]],
            ["id": "rpc", "operation": "calendar.list", "arguments": [:], "resources": ["calendar_ids": "*"]],
            ["id": "rpc", "operation": "calendar.list", "arguments": [:], "resources": ["anything": []]],
            ["id": "rpc", "operation": "calendar.list", "arguments": [:], "resources": [:], "secret": "ignored"],
            ["id": "rpc", "operation": "system.capabilities", "arguments": ["limit": 1], "resources": [:]]
        ]
        for object in objects { XCTAssertThrowsError(try decode(object)) }
    }

    func testStrictIntegerBooleanAndBounds() {
        let integers: [Any] = [true, 0, 101, 1.5, "2"]
        for value in integers {
            XCTAssertThrowsError(try NativeValidation.validate(NativeRequest(id: "rpc", operation: "calendar.list", arguments: ["limit": value])))
        }
        let booleans: [Any] = ["true", 1, 0]
        for value in booleans {
            XCTAssertThrowsError(try NativeValidation.validate(NativeRequest(id: "rpc", operation: "reminders.list", arguments: ["list_id": "l", "completed": value])))
        }
        XCTAssertNoThrow(try NativeValidation.validate(NativeRequest(id: "rpc", operation: "reminders.list", arguments: ["list_id": "l", "completed": true, "limit": 100])))
    }

    func testWriteIdentifierIsMetadataAndMayBeNamespaced() {
        let args: JSONObject = ["list_id": "l", "title": "A reminder"]
        XCTAssertThrowsError(try NativeValidation.validate(NativeRequest(id: "rpc", operation: "reminders.create", arguments: args)))
        XCTAssertNoThrow(try NativeValidation.validate(NativeRequest(id: "rpc", operation: "reminders.create", arguments: args, requestID: "client:" + String(repeating: "x", count: 128))))
        XCTAssertThrowsError(try NativeValidation.validate(NativeRequest(id: "rpc", operation: "reminders.create", arguments: args, requestID: "short")))
        var wrong = args; wrong["request_id"] = "12345678"
        XCTAssertThrowsError(try NativeValidation.validate(NativeRequest(id: "rpc", operation: "reminders.create", arguments: wrong, requestID: "12345678")))
    }

    func testInvalidDateValuesNeverNormalizeSilently() {
        for value in ["2026-02-30T12:00:00Z", "2026-13-01T12:00:00Z", "2026-10-17T24:00:00Z", "2026-10-17T12:60:00Z", "2026-10-17T12:00:60Z", "2026-10-17T12:00:00+24:00", "2026-10-17T12:00:00+00:60", "2026-10-17T12:00:00", "2026-10-17T12:00:00Z\n"] {
            XCTAssertThrowsError(try NativeValidation.date(value), value)
        }
        XCTAssertNoThrow(try NativeValidation.date("2024-02-29T12:00:00.125-07:00"))
    }

    func testUnsafePathsRejected() {
        for value in ["/etc/passwd", "../file", "x/../file", "x/./file", "x//file", "x/", "x\\file", "x\0file", ""] {
            XCTAssertThrowsError(try NativeValidation.relativePath(value))
        }
        XCTAssertNoThrow(try NativeValidation.relativePath("", allowEmpty: true))
        XCTAssertNoThrow(try NativeValidation.relativePath("nested/hello world.txt"))
    }

    func testBase64RequiresCanonicalBoundedBytes() {
        func upload(_ encoded: String) -> NativeRequest {
            NativeRequest(id: "rpc", operation: "drive.upload", arguments: ["root_id": "r", "path": "file", "content_base64": encoded], requestID: "request-123")
        }
        XCTAssertNoThrow(try NativeValidation.validate(upload("")))
        XCTAssertNoThrow(try NativeValidation.validate(upload(Data("hello".utf8).base64EncodedString())))
        XCTAssertThrowsError(try NativeValidation.validate(upload("aGVsbG8=\n")))
        XCTAssertThrowsError(try NativeValidation.validate(upload("Zh==")))
        XCTAssertThrowsError(try NativeValidation.validate(upload(Data(repeating: 65, count: 262_145).base64EncodedString())))
    }

    func testPaginationRejectsChangedDataAndQuery() throws {
        let items: [JSONObject] = [["id": "a"], ["id": "b"], ["id": "c"]]
        let first = try Pagination.page(items, arguments: ["limit": 2], context: "query")
        let cursor = try XCTUnwrap(first["next_cursor"] as? String)
        let second = try Pagination.page(items, arguments: ["limit": 2, "cursor": cursor], context: "query")
        XCTAssertEqual((second["items"] as? [JSONObject])?.first?["id"] as? String, "c")
        XCTAssertNil(second["next_cursor"])
        XCTAssertThrowsError(try Pagination.page(items, arguments: ["cursor": cursor], context: "other"))
        XCTAssertThrowsError(try Pagination.page(Array(items.dropLast()), arguments: ["cursor": cursor], context: "query"))
        XCTAssertThrowsError(try Pagination.page(items, arguments: ["cursor": "not-base64"], context: "query"))
    }

    func testPaginationBindsNativeQueryArgumentsEvenWhenResultsMatch() throws {
        let items: [JSONObject] = [["id": "a"], ["id": "b"]]
        let first = try Pagination.page(items, arguments: ["query": "first", "limit": 1], context: "contacts.search")
        let cursor = try XCTUnwrap(first["next_cursor"] as? String)
        XCTAssertThrowsError(try Pagination.page(items, arguments: ["query": "different", "cursor": cursor], context: "contacts.search"))
        XCTAssertNoThrow(try Pagination.page(items, arguments: ["query": "first", "cursor": cursor, "limit": 50], context: "contacts.search"))
    }

    @MainActor
    func testArgumentRejectionPreservesRequestIdentityAndKnownNoEffect() async throws {
        let object: JSONObject = [
            "id": "correlated-write", "operation": "calendar.events.create", "request_id": "request-123",
            "arguments": ["calendar_id": "denied", "title": "Test", "start": "2026-01-01T00:00:00Z", "end": "2028-01-01T00:00:00Z"],
            "resources": [:]
        ]
        let request = try NativeRequest.decode(JSONSerialization.data(withJSONObject: object))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try NativeService(stateDirectory: directory)
        let response = await service.execute(request)
        XCTAssertEqual(response["id"] as? String, "correlated-write")
        let error = try XCTUnwrap(response["error"] as? JSONObject)
        XCTAssertEqual(error["status"] as? Int, 400)
        XCTAssertEqual(error["outcome"] as? String, "none")
    }

    private func decode(_ object: JSONObject) throws -> NativeRequest {
        let request = try NativeRequest.decode(JSONSerialization.data(withJSONObject: object))
        try NativeValidation.validate(request)
        return request
    }
}
