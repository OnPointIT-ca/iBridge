import XCTest
import Foundation
import SQLite3
@testable import IBridgeCore

final class MessagesAdapterTests: XCTestCase {
    private final class Fixture {
        let directory: URL
        let url: URL
        var writer: OpaquePointer?

        init(schema: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("ibridge-messages-fixture-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("chat.db")
            guard sqlite3_open_v2(url.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                throw NSError(domain: "Fixture", code: 1)
            }
            if schema {
                try sql("""
                    CREATE TABLE chat (guid TEXT, display_name TEXT, service_name TEXT);
                    CREATE TABLE handle (id TEXT);
                    CREATE TABLE message (guid TEXT, text TEXT, date INTEGER, is_from_me INTEGER, handle_id INTEGER, attributedBody BLOB, cache_has_attachments INTEGER);
                    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
                    INSERT INTO chat VALUES ('chat-allowed', 'Project', 'iMessage'), ('chat-hidden', 'Private', 'SMS');
                    INSERT INTO handle VALUES ('fixture@example.invalid');
                    INSERT INTO message VALUES ('message-one', 'First Project plan', 700000001000000000, 0, 1, NULL, 0),
                                               ('message-two', 'Second project update', 700000002000000000, 1, 1, NULL, 0),
                                               ('message-hidden', 'Private project content', 700000003000000000, 0, 1, NULL, 0);
                    INSERT INTO chat_message_join VALUES (1, 1), (1, 2), (2, 3);
                    """)
            }
        }

        deinit {
            if let writer { sqlite3_close(writer) }
            try? FileManager.default.removeItem(at: directory)
        }

        func sql(_ sql: String) throws {
            guard sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "Fixture", code: 2) }
        }

        func add(text: String?, blob: Data? = nil, date: Int64 = 700000004000000000, attachment: Bool = false) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(writer, "INSERT INTO message VALUES (?, ?, ?, 0, 1, ?, ?)", -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "Fixture", code: 3)
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let guid = "fixture-" + UUID().uuidString
            _ = guid.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
            if let text { _ = text.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) } }
            else { sqlite3_bind_null(statement, 2) }
            sqlite3_bind_int64(statement, 3, date)
            if let blob { _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient) } }
            else { sqlite3_bind_null(statement, 4) }
            sqlite3_bind_int(statement, 5, attachment ? 1 : 0)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "Fixture", code: 4) }
            try sql("INSERT INTO chat_message_join VALUES (1, \(sqlite3_last_insert_rowid(writer)))")
        }
    }

    @MainActor
    private func request(_ operation: String, _ arguments: JSONObject = [:], allowed: [String] = ["chat-allowed"]) -> NativeRequest {
        NativeRequest(id: "fixture-request", operation: operation, arguments: arguments,
                      resources: ResourcePolicy(["message_chat_ids": allowed]))
    }

    @MainActor
    private func reject(_ adapter: MessagesAdapter, _ request: NativeRequest, status: Int,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await adapter.execute(request)
            XCTFail("Expected rejection", file: file, line: line)
        } catch let error as NativeError {
            XCTAssertEqual(error.status, status, file: file, line: line)
            XCTAssertEqual(error.outcome, "none", file: file, line: line)
        } catch { XCTFail("Unexpected error", file: file, line: line) }
    }

    @MainActor
    func testDiscoveryAndReadsStayWithinGrantedChats() async throws {
        let fixture = try Fixture()
        let adapter = MessagesAdapter(testDatabaseURL: fixture.url)
        XCTAssertEqual(adapter.permissionStatus, "available")
        XCTAssertEqual(adapter.capabilities(ResourcePolicy())["messages.read"], false)
        XCTAssertEqual(adapter.capabilities(ResourcePolicy(["message_chat_ids": ["chat-allowed"]]))["messages.read"], true)
        let discovery = try await adapter.execute(request("messages.chats"))
        XCTAssertEqual((discovery["items"] as? [JSONObject])?.compactMap { $0["id"] as? String }, ["chat-allowed"])
        let read = try await adapter.execute(request("messages.read", ["chat_id": "chat-allowed"]))
        let items = try XCTUnwrap(read["items"] as? [JSONObject])
        XCTAssertEqual(items.compactMap { $0["id"] as? String }, ["message-two", "message-one"])
        XCTAssertEqual(items.first?["body_status"] as? String, "plain_text")
        XCTAssertEqual(items.first?["is_from_me"] as? Bool, true)
        XCTAssertNil(items.first?["sender"])
        XCTAssertEqual(items.last?["sender"] as? String, "fixture@example.invalid")
        XCTAssertEqual(read["scan_truncated"] as? Bool, false)
        await reject(adapter, request("messages.read", ["chat_id": "chat-hidden"]), status: 403)
        await reject(adapter, request("messages.search", ["query": "Private", "chat_id": "chat-hidden"]), status: 403)
    }

    @MainActor
    func testSearchFiltersEveryChatAndTreatsQueryAsLiteralText() async throws {
        let fixture = try Fixture()
        let adapter = MessagesAdapter(testDatabaseURL: fixture.url)
        let result = try await adapter.execute(request("messages.search", ["query": "PROJECT"]))
        XCTAssertEqual((result["items"] as? [JSONObject])?.count, 2)
        XCTAssertEqual(result["search_complete"] as? Bool, true)
        let literal = try await adapter.execute(request("messages.search", ["query": "' OR 1=1 --"]))
        XCTAssertEqual((literal["items"] as? [JSONObject])?.count, 0)
        let all = try await adapter.execute(request("messages.chats", allowed: ["*"]))
        XCTAssertEqual((all["items"] as? [JSONObject])?.count, 2)
        let scoped = try await adapter.execute(request("messages.search", ["query": "project", "chat_id": "chat-allowed"], allowed: ["*"]))
        XCTAssertEqual((scoped["items"] as? [JSONObject])?.count, 2)
    }

    @MainActor
    func testDeniedPolicyDoesNotOpenOrProbeMissingDatabase() async throws {
        let fixture = try Fixture()
        let missing = fixture.directory.appendingPathComponent("absent.db")
        let adapter = MessagesAdapter(testDatabaseURL: missing)
        await reject(adapter, request("messages.chats", allowed: []), status: 403)
        await reject(adapter, request("messages.read", ["chat_id": "chat-hidden"]), status: 403)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(adapter.permissionStatus, "messages_database_missing")
        await reject(adapter, request("messages.chats"), status: 404)
    }

    @MainActor
    func testUnknownButGrantedChatReturnsNotFound() async throws {
        let fixture = try Fixture()
        let adapter = MessagesAdapter(testDatabaseURL: fixture.url)
        await reject(adapter, request("messages.read", ["chat_id": "missing"], allowed: ["*"]), status: 404)
        await reject(adapter, request("messages.read", ["chat_id": "' OR 1=1 --"], allowed: ["*"]), status: 404)
    }

    @MainActor
    func testArchiveAndAttachmentBodiesAreNotMisrepresentedAsEmptyText() async throws {
        let fixture = try Fixture()
        try fixture.add(text: nil, blob: Data("unsupported archive".utf8))
        try fixture.add(text: nil, attachment: true)
        try fixture.add(text: nil)
        let adapter = MessagesAdapter(testDatabaseURL: fixture.url)
        let result = try await adapter.execute(request("messages.read", ["chat_id": "chat-allowed"]))
        let items = try XCTUnwrap(result["items"] as? [JSONObject])
        XCTAssertEqual(Array(items.prefix(3)).compactMap { $0["body_status"] as? String }, ["unavailable", "attachment_only", "unsupported_attributed_body"])
        XCTAssertTrue(items.prefix(3).allSatisfy { $0["text"] == nil })
        XCTAssertEqual(result["unsupported_body_count"] as? Int, 2)
        let search = try await adapter.execute(request("messages.search", ["query": "not present"]))
        XCTAssertEqual((search["items"] as? [JSONObject])?.count, 0)
        XCTAssertEqual(search["search_complete"] as? Bool, false)
        XCTAssertEqual(search["unsupported_body_count"] as? Int, 2)
    }

    @MainActor
    func testSupportedArchivedTextParticipatesInReadAndSearch() async throws {
        let fixture = try Fixture()
        let text = "Fixture archived message 🐈"
        let archive = NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
        try fixture.add(text: nil, blob: archive)
        let adapter = MessagesAdapter(testDatabaseURL: fixture.url)
        let read = try await adapter.execute(request("messages.read", ["chat_id": "chat-allowed"]))
        let item = try XCTUnwrap((read["items"] as? [JSONObject])?.first)
        XCTAssertEqual(item["text"] as? String, text)
        XCTAssertEqual(item["body_status"] as? String, "supported_archived_text")
        let search = try await adapter.execute(request("messages.search", ["query": "ARCHIVED"]))
        XCTAssertEqual((search["items"] as? [JSONObject])?.count, 1)
        XCTAssertEqual(search["search_complete"] as? Bool, true)
    }

    @MainActor
    func testSearchReportsLimitedRecentWindowWithoutClaimingCompleteness() async throws {
        let fixture = try Fixture()
        let adapter = MessagesAdapter(testDatabaseURL: fixture.url, maximumScan: 1)
        let search = try await adapter.execute(request("messages.search", ["query": "First"]))
        XCTAssertEqual((search["items"] as? [JSONObject])?.count, 0)
        XCTAssertEqual(search["scan_truncated"] as? Bool, true)
        XCTAssertEqual(search["search_complete"] as? Bool, false)
        XCTAssertEqual(search["scanned_messages"] as? Int, 1)
    }

    @MainActor
    func testPaginationRejectsChangedHistoryAndDifferentQuery() async throws {
        let fixture = try Fixture()
        let adapter = MessagesAdapter(testDatabaseURL: fixture.url)
        let first = try await adapter.execute(request("messages.read", ["chat_id": "chat-allowed", "limit": 1]))
        let cursor = try XCTUnwrap(first["next_cursor"] as? String)
        let next = try await adapter.execute(request("messages.read", ["chat_id": "chat-allowed", "limit": 1, "cursor": cursor]))
        XCTAssertEqual((next["items"] as? [JSONObject])?.first?["id"] as? String, "message-one")
        await reject(adapter, request("messages.search", ["query": "project", "cursor": cursor]), status: 400)
        try fixture.add(text: "New message")
        await reject(adapter, request("messages.read", ["chat_id": "chat-allowed", "cursor": cursor]), status: 400)
    }

    @MainActor
    func testDatabaseAndWalContentRemainUnchanged() async throws {
        let fixture = try Fixture()
        try fixture.sql("PRAGMA journal_mode=WAL")
        try fixture.add(text: "Committed only to WAL")
        let databaseBefore = try Data(contentsOf: fixture.url)
        let walURL = URL(fileURLWithPath: fixture.url.path + "-wal")
        let walBefore = try Data(contentsOf: walURL)
        let adapter = MessagesAdapter(testDatabaseURL: fixture.url)
        let read = try await adapter.execute(request("messages.read", ["chat_id": "chat-allowed"]))
        XCTAssertEqual((read["items"] as? [JSONObject])?.first?["text"] as? String, "Committed only to WAL")
        _ = try await adapter.execute(request("messages.search", ["query": "WAL"]))
        _ = try await adapter.execute(request("messages.chats"))
        XCTAssertEqual(try Data(contentsOf: fixture.url), databaseBefore)
        XCTAssertEqual(try Data(contentsOf: walURL), walBefore)
    }

    @MainActor
    func testUnsupportedSchemaAndViewsFailClosed() async throws {
        let fixture = try Fixture(schema: false)
        let adapter = MessagesAdapter(testDatabaseURL: fixture.url)
        XCTAssertEqual(adapter.permissionStatus, "unsupported_schema")
        await reject(adapter, request("messages.chats"), status: 422)
        try fixture.sql("CREATE VIEW chat AS SELECT 'fake' AS guid")
        await reject(adapter, request("messages.chats"), status: 422)
    }

    @MainActor
    func testSymlinkDatabaseAndSidecarAreRejected() async throws {
        let fixture = try Fixture()
        let link = fixture.directory.appendingPathComponent("link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.url)
        await reject(MessagesAdapter(testDatabaseURL: link), request("messages.chats"), status: 403)
        let sidecar = URL(fileURLWithPath: fixture.url.path + "-wal")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: fixture.url)
        await reject(MessagesAdapter(testDatabaseURL: fixture.url), request("messages.chats"), status: 403)
    }

    @MainActor
    func testLongTextIsBoundedAndArchiveLimitIsExplicit() async throws {
        let fixture = try Fixture()
        try fixture.add(text: String(repeating: "🎉", count: 5_000))
        try fixture.add(text: nil, blob: Data(repeating: 65, count: 262_145))
        let adapter = MessagesAdapter(testDatabaseURL: fixture.url)
        let result = try await adapter.execute(request("messages.read", ["chat_id": "chat-allowed"]))
        let items = try XCTUnwrap(result["items"] as? [JSONObject])
        XCTAssertEqual(items[0]["body_status"] as? String, "unsupported_attributed_body")
        XCTAssertEqual(items[1]["body_status"] as? String, "truncated")
        XCTAssertEqual((items[1]["text"] as? String)?.utf8.count, 16_384)
        XCTAssertEqual(result["truncated_body_count"] as? Int, 1)
    }

    @MainActor
    func testTimestampsSupportSecondsAndNanoseconds() {
        XCTAssertEqual(MessagesAdapter.timestamp(700000001), MessagesAdapter.timestamp(700000001000000000))
        XCTAssertEqual(MessagesAdapter.timestamp(0), "2001-01-01T00:00:00Z")
    }
}
