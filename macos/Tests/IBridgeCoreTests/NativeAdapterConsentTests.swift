import Foundation
import XCTest
@testable import IBridgeCore

final class NativeAdapterConsentTests: XCTestCase {
    @MainActor
    func testDefaultConsentBlocksAllNewOperationsBeforeAccessingAppsOrDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try NativeService(stateDirectory: directory)
        let policy = ResourcePolicy(["note_folder_ids": ["*"], "message_chat_ids": ["*"]])
        let reads: [(String, JSONObject)] = [
            ("notes.folders", [:]), ("notes.search", ["query": "test"]),
            ("notes.read", ["note_id": "note-1"]), ("messages.chats", [:]),
            ("messages.search", ["query": "test"]), ("messages.read", ["chat_id": "chat-1"])
        ]
        for (operation, arguments) in reads {
            let response = await service.execute(NativeRequest(id: operation, operation: operation, arguments: arguments, resources: policy))
            let error = try XCTUnwrap(response["error"] as? JSONObject)
            XCTAssertEqual(response["id"] as? String, operation)
            XCTAssertEqual(error["status"] as? Int, 403)
            XCTAssertEqual(error["outcome"] as? String, "none")
        }
        let write = await service.execute(NativeRequest(id: "create", operation: "notes.create",
            arguments: ["folder_id": "folder-1", "title": "Example", "body": "Text"], resources: policy, requestID: "request-123"))
        let error = try XCTUnwrap(write["error"] as? JSONObject)
        XCTAssertEqual(error["status"] as? Int, 403)
        XCTAssertEqual(error["outcome"] as? String, "none")
        let operations = try XCTUnwrap(service.capabilities(policy)["operations"] as? JSONObject)
        for name in reads.map(\.0) + ["notes.create"] {
            XCTAssertEqual((operations[name] as? JSONObject)?["available"] as? Bool, false)
        }
        XCTAssertEqual(service.permissionSummary["notes"], "disabled")
        XCTAssertEqual(service.permissionSummary["messages"], "disabled")
    }
}
