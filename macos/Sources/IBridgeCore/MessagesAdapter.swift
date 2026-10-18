import Foundation
import SQLite3
import Darwin

/// Optional, read-only access to the current Mac user's locally synchronized
/// Messages history. The host must gate this adapter behind its local opt-in.
/// No method requests Full Disk Access, launches Messages, or sends messages.
@MainActor
public final class MessagesAdapter {
    private let databaseURL: URL
    private let maximumScan: Int

    public init() {
        databaseURL = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
            .appendingPathComponent("Library/Messages/chat.db")
        maximumScan = 5_000
    }

    // Not exposed through native RPC or environment variables. Fixtures never
    // inspect the runner's real Messages database or require Apple permissions.
    internal init(testDatabaseURL: URL, maximumScan: Int = 5_000) {
        databaseURL = testDatabaseURL
        self.maximumScan = min(max(maximumScan, 1), 5_000)
    }

    public var permissionStatus: String {
        do {
            let database = try MessagesDatabase(url: databaseURL)
            try database.validateSchema()
            return "available"
        } catch let error as NativeError {
            switch error.code {
            case "permission_denied": return "full_disk_access_required"
            case "not_found": return "messages_database_missing"
            case "unsupported_operation": return "unsupported_schema"
            default: return "unavailable"
            }
        } catch { return "unavailable" }
    }

    public func capabilities(_ policy: ResourcePolicy) -> [String: Bool] {
        let available = policy.hasAny(.messageChats) && permissionStatus == "available"
        return ["messages.chats": available, "messages.search": available, "messages.read": available]
    }

    public func execute(_ request: NativeRequest) async throws -> JSONObject {
        guard ["messages.chats", "messages.search", "messages.read"].contains(request.operation) else {
            throw NativeError("unsupported_operation", "This Messages operation is unavailable.", status: 422)
        }
        try NativeValidation.validate(request)
        guard request.resources.hasAny(.messageChats) else {
            throw NativeError("permission_denied", "No Messages conversations are authorized for this client.", status: 403)
        }
        let chatID = request.arguments["chat_id"] as? String
        if let chatID, !request.resources.allows(.messageChats, id: chatID) {
            throw NativeError("permission_denied", "The Messages conversation is not authorized.", status: 403)
        }

        let database = try MessagesDatabase(url: databaseURL)
        try database.validateSchema()
        let scopedIDs = chatID.map { [$0] } ?? request.resources.identifiers(for: .messageChats)
        // Wildcards are policy syntax only; an explicit resource ID always
        // remains a bound value, including a literal "*".
        let allChats = chatID == nil && scopedIDs.contains("*")
        let predicate = allChats ? "1" : "c.guid IN (\(Array(repeating: "?", count: scopedIDs.count).joined(separator: ",")))"
        let bindings = allChats ? [] : scopedIDs
        if let chatID {
            let exists = try database.rows("SELECT c.guid FROM chat c WHERE c.guid = ? LIMIT 1", bindings: [chatID])
            guard !exists.isEmpty else {
                throw NativeError("not_found", "The Messages conversation is no longer available.", status: 404)
            }
        }
        let result: JSONObject
        if request.operation == "messages.chats" {
            result = try chats(database, request: request, predicate: predicate, bindings: bindings)
        } else {
            result = try messages(database, request: request, predicate: predicate, bindings: bindings)
        }
        guard try JSONSerialization.data(withJSONObject: result).count <= 1_500_000 else {
            throw NativeError("payload_too_large", "The Messages page is too large. Request a smaller limit.", status: 413)
        }
        return result
    }

    private func chats(_ database: MessagesDatabase, request: NativeRequest,
                       predicate: String, bindings: [String]) throws -> JSONObject {
        let name = database.chatColumns.contains("display_name") ? "c.display_name" : "NULL"
        let service = database.chatColumns.contains("service_name") ? "c.service_name" : "NULL"
        let rows = try database.rows("SELECT c.guid, \(name), \(service) FROM chat c WHERE \(predicate) ORDER BY c.guid LIMIT 5001", bindings: bindings)
        var records: [JSONObject] = []
        for row in rows.prefix(5_000) {
            let identifier = try requiredID(row[0])
            var record: JSONObject = ["id": identifier]
            if let name = row[1] as? String, !name.isEmpty { record["name"] = name }
            if let service = row[2] as? String, !service.isEmpty { record["service"] = service }
            records.append(record)
        }
        var result = try Pagination.page(records, arguments: request.arguments, context: request.operation)
        result["scan_truncated"] = rows.count > 5_000 || database.rowsTruncated
        result["source"] = "local_messages_database"
        return result
    }

    private func messages(_ database: MessagesDatabase, request: NativeRequest,
                          predicate: String, bindings: [String]) throws -> JSONObject {
        // Only a bounded format parser may inspect archived text. Never unarchive
        // arbitrary Foundation/Apple classes from the database.
        let attributed = database.messageColumns.contains("attributedBody") ? "length(m.attributedBody)" : "0"
        let archivedBody = database.messageColumns.contains("attributedBody") ? "CASE WHEN length(m.attributedBody) <= 262144 THEN m.attributedBody ELSE NULL END" : "NULL"
        let attachments = database.messageColumns.contains("cache_has_attachments") ? "m.cache_has_attachments" : "0"
        let sql = """
            SELECT m.guid, c.guid, m.text, m.date, m.is_from_me, h.id, \(attributed), \(attachments), \(archivedBody)
            FROM message m
            JOIN chat_message_join j ON j.message_id = m.ROWID
            JOIN chat c ON c.ROWID = j.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE \(predicate)
            ORDER BY m.date DESC, m.ROWID DESC, c.guid
            LIMIT \(maximumScan + 1)
            """
        let rows = try database.rows(sql, bindings: bindings)
        let search = request.operation == "messages.search"
        let query = request.arguments["query"] as? String ?? ""
        var records: [JSONObject] = []
        var unsupported = 0
        var truncatedText = 0
        for row in rows.prefix(maximumScan) {
            let identifier = try requiredID(row[0])
            let conversation = try requiredID(row[1])
            let plainText = row[2] as? String
            let decoded = plainText?.isEmpty == false ? nil : (row[8] as? Data).flatMap { MessagesBodyDecoder.decode($0) }
            let rawText = plainText.flatMap { $0.isEmpty ? nil : $0 } ?? decoded
            let hasArchivedBody = (row[6] as? Int64 ?? 0) > 0
            let hasAttachments = (row[7] as? Int64 ?? 0) != 0
            let bodyStatus: String
            if let text = rawText, !text.isEmpty {
                bodyStatus = text.utf8.count > 16_384 ? "truncated" : (plainText?.isEmpty == false ? "plain_text" : "supported_archived_text")
            } else if hasArchivedBody { bodyStatus = "unsupported_attributed_body" }
            else if hasAttachments { bodyStatus = "attachment_only" }
            else { bodyStatus = "unavailable" }
            if bodyStatus == "unsupported_attributed_body" || bodyStatus == "unavailable" { unsupported += 1 }
            if bodyStatus == "truncated" { truncatedText += 1 }
            if search {
                guard let rawText, rawText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil else { continue }
            }
            var record: JSONObject = ["id": identifier, "chat_id": conversation,
                                      "is_from_me": (row[4] as? Int64 ?? 0) != 0,
                                      "body_status": bodyStatus, "has_attachments": hasAttachments]
            if let rawText, !rawText.isEmpty {
                // Swift's prefix counts Characters; enforce bytes after slicing
                // UTF-8 while preserving valid Unicode at the cut boundary.
                record["text"] = boundedText(rawText, maximumBytes: 16_384)
            }
            // For outgoing rows handle_id can identify the recipient, not the
            // sender. is_from_me already identifies the local sender accurately.
            if (row[4] as? Int64 ?? 0) == 0, let sender = row[5] as? String, !sender.isEmpty { record["sender"] = sender }
            if let timestamp = row[3] as? Int64, let date = Self.timestamp(timestamp) { record["date"] = date }
            records.append(record)
        }
        var result = try Pagination.page(records, arguments: request.arguments, context: request.operation)
        result["source"] = "local_messages_database"
        result["order"] = "newest_first"
        result["scanned_messages"] = min(rows.count, maximumScan)
        let truncatedScan = rows.count > maximumScan || database.rowsTruncated
        result["scan_truncated"] = truncatedScan
        result["history_limit"] = maximumScan
        result["unsupported_body_count"] = unsupported
        result["truncated_body_count"] = truncatedText
        if search {
            result["search_scope"] = "plain_and_supported_archived_text"
            result["search_complete"] = !truncatedScan && unsupported == 0
        }
        return result
    }

    private func requiredID(_ value: Any) throws -> String {
        guard let identifier = value as? String, !identifier.isEmpty,
              identifier.utf8.count <= 512, !identifier.contains("\0") else {
            throw NativeError("unsupported_operation", "The Messages database contains unsupported identifiers.", status: 422)
        }
        return identifier
    }

    private func boundedText(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var bytes = Array(text.utf8.prefix(maximumBytes))
        while !bytes.isEmpty {
            if let result = String(bytes: bytes, encoding: .utf8) { return result }
            bytes.removeLast()
        }
        return ""
    }

    internal static func timestamp(_ raw: Int64) -> String? {
        // Messages changed from seconds to nanoseconds since 2001-01-01.
        let seconds = abs(Double(raw)) > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        guard seconds.isFinite, abs(seconds) < 30_000_000_000 else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSinceReferenceDate: seconds))
    }
}

/// A short-lived read snapshot. No SQL is accepted from a remote caller.
private final class MessagesDatabase {
    private var handle: OpaquePointer?
    private let budget = MessagesQueryBudget()
    private(set) var chatColumns: Set<String> = []
    private(set) var messageColumns: Set<String> = []
    private(set) var rowsTruncated = false

    init(url: URL) throws {
        try Self.validatePath(url)
        // NOFOLLOW also guards replacement of the final path between lstat/open.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }; handle = nil
            throw NativeError("adapter_unavailable", "Messages history cannot be opened. Check Full Disk Access and the local Messages account.", status: 503)
        }
        do {
            guard sqlite3_db_readonly(handle, "main") == 1 else {
                throw NativeError("adapter_unavailable", "Messages history could not be opened read-only.", status: 503)
            }
            sqlite3_busy_timeout(handle, 200)
            sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 1_048_576)
            sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 32_768)
            sqlite3_limit(handle, SQLITE_LIMIT_VARIABLE_NUMBER, 1_024)
            sqlite3_enable_load_extension(handle, 0)
            sqlite3_progress_handler(handle, 1_000, { pointer in
                guard let pointer else { return 1 }
                let budget = Unmanaged<MessagesQueryBudget>.fromOpaque(pointer).takeUnretainedValue()
                budget.steps += 1_000
                return budget.steps > 10_000_000 || ProcessInfo.processInfo.systemUptime > budget.deadline ? 1 : 0
            }, Unmanaged.passUnretained(budget).toOpaque())
            try execute("PRAGMA query_only=ON")
            try execute("PRAGMA trusted_schema=OFF")
            try execute("PRAGMA temp_store=MEMORY")
            try execute("BEGIN")
        } catch {
            sqlite3_close(handle); handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func validateSchema() throws {
        let requirements: [String: Set<String>] = [
            "chat": ["guid"], "message": ["guid", "text", "date", "is_from_me", "handle_id"],
            "chat_message_join": ["chat_id", "message_id"], "handle": ["id"]
        ]
        for (table, required) in requirements {
            let definitions = try rows("SELECT type, sql FROM sqlite_master WHERE name = ?", bindings: [table])
            guard definitions.count == 1, definitions[0][0] as? String == "table",
                  let definition = definitions[0][1] as? String,
                  !definition.uppercased().contains("VIRTUAL TABLE") else { throw unsupportedSchema() }
            let columns = try rows("PRAGMA table_info(\(table))", bindings: [])
            let names = Set(columns.compactMap { $0[1] as? String })
            guard required.isSubset(of: names) else { throw unsupportedSchema() }
            if table == "chat" { chatColumns = names }
            if table == "message" { messageColumns = names }
        }
        // Defense in depth: even accidental new code cannot ATTACH, update,
        // invoke arbitrary functions, or change pragmas after schema inspection.
        sqlite3_set_authorizer(handle, { _, action, _, second, _, _ in
            switch action {
            case SQLITE_SELECT, SQLITE_READ: return SQLITE_OK
            case SQLITE_FUNCTION:
                return second.map { String(cString: $0).lowercased() == "length" } == true ? SQLITE_OK : SQLITE_DENY
            default: return SQLITE_DENY
            }
        }, nil)
    }

    func rows(_ sql: String, bindings: [String]) throws -> [[Any]] {
        rowsTruncated = false
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else { throw databaseError() }
        for (index, value) in bindings.enumerated() {
            let status = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard status == SQLITE_OK else { throw databaseError() }
        }
        var result: [[Any]] = []
        var totalBytes = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw databaseError() }
            var values: [Any] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    totalBytes += count
                    if totalBytes > 8_388_608 { rowsTruncated = true; return result }
                    guard count <= 262_144,
                          let pointer = sqlite3_column_text(statement, index),
                          let value = String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8) else {
                        throw NativeError("payload_too_large", "Messages history exceeds the supported text limit.", status: 413)
                    }
                    values.append(value)
                case SQLITE_INTEGER: values.append(sqlite3_column_int64(statement, index))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    totalBytes += count
                    if totalBytes > 8_388_608 { rowsTruncated = true; return result }
                    guard count <= 262_144 else {
                        throw NativeError("payload_too_large", "Messages history exceeds the supported body limit.", status: 413)
                    }
                    if count == 0 { values.append(Data()) }
                    else if let pointer = sqlite3_column_blob(statement, index) { values.append(Data(bytes: pointer, count: count)) }
                    else { throw databaseError() }
                case SQLITE_NULL: values.append(NSNull())
                default: throw unsupportedSchema()
                }
            }
            result.append(values)
            guard result.count <= 5_001 else { throw databaseError() }
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }

    private func unsupportedSchema() -> NativeError {
        NativeError("unsupported_operation", "This Messages database schema is unsupported.", status: 422)
    }

    private func databaseError() -> NativeError {
        NativeError("adapter_unavailable", "Messages history is busy, unsupported, or could not be read within the query limit.", status: 503)
    }

    private static func validatePath(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        guard url.isFileURL, parent.standardizedFileURL == parent.resolvingSymlinksInPath().standardizedFileURL else {
            throw NativeError("permission_denied", "The Messages database path must not contain symbolic links.", status: 403)
        }
        for (path, required) in [(url.path, true), (url.path + "-wal", false), (url.path + "-shm", false)] {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno == ENOENT && !required { continue }
                if errno == ENOENT { throw NativeError("not_found", "No local Messages history is available.", status: 404) }
                throw NativeError("permission_denied", "Messages history needs Full Disk Access in macOS Privacy & Security settings.", status: 403)
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                throw NativeError("permission_denied", "Messages history must be a regular file owned by the current user.", status: 403)
            }
        }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw NativeError("permission_denied", "Messages history needs Full Disk Access in macOS Privacy & Security settings.", status: 403)
        }
        close(descriptor)
    }
}

private final class MessagesQueryBudget {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var steps = 0
}
