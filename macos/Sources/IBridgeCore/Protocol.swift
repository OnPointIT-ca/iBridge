import Foundation
import CoreFoundation
import CryptoKit

public typealias JSONObject = [String: Any]

public struct NativeError: Error {
    public let code: String
    public let message: String
    public let status: Int
    public let outcome: String

    public init(_ code: String, _ message: String, status: Int = 400, outcome: String = "none") {
        self.code = code; self.message = message; self.status = status; self.outcome = outcome
    }

    public var json: JSONObject {
        ["code": code, "message": message, "status": status, "outcome": outcome]
    }
}

public enum ResourceCollection: String {
    case calendars = "calendar_ids"
    case reminderLists = "reminder_list_ids"
    case driveRoots = "drive_root_ids"
}

public struct ResourcePolicy {
    private let values: [String: [String]]

    public init(_ values: [String: [String]] = [:]) { self.values = values }

    public func allows(_ collection: ResourceCollection, id: String) -> Bool {
        let ids = values[collection.rawValue] ?? []
        return ids.contains("*") || ids.contains(id)
    }

    public func hasAny(_ collection: ResourceCollection) -> Bool {
        !(values[collection.rawValue] ?? []).isEmpty
    }
}

public struct NativeRequest {
    public let id: String
    public let operation: String
    public let arguments: JSONObject
    public let resources: ResourcePolicy
    public let requestID: String?

    public init(id: String, operation: String, arguments: JSONObject = [:], resources: ResourcePolicy = ResourcePolicy(), requestID: String? = nil) {
        self.id = id; self.operation = operation; self.arguments = arguments
        self.resources = resources; self.requestID = requestID
    }

    public var isWrite: Bool { NativeValidation.writeOperations.contains(operation) }

    public static func decode(_ data: Data) throws -> NativeRequest {
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              Set(object.keys).isSubset(of: ["id", "operation", "arguments", "resources", "request_id"]),
              let id = object["id"] as? String, !id.isEmpty, id.count <= 128,
              let operation = object["operation"] as? String,
              let arguments = object["arguments"] as? JSONObject,
              let resources = object["resources"] as? JSONObject else {
            throw NativeError("invalid_request", "The native request is invalid.")
        }
        var policy: [String: [String]] = [:]
        let keys = Set(["calendar_ids", "reminder_list_ids", "drive_root_ids"])
        guard Set(resources.keys).isSubset(of: keys) else {
            throw NativeError("invalid_request", "The resource policy is invalid.")
        }
        for (key, raw) in resources {
            guard let ids = raw as? [String], ids.count <= 1_000,
                  ids.allSatisfy({ !$0.isEmpty && $0.count <= 512 && !$0.contains("\0") }) else {
                throw NativeError("invalid_request", "The resource policy is invalid.")
            }
            policy[key] = ids
        }
        if object["request_id"] != nil && !(object["request_id"] is String) {
            throw NativeError("invalid_request", "The write request identifier is invalid.")
        }
        let request = NativeRequest(id: id, operation: operation, arguments: arguments,
                                    resources: ResourcePolicy(policy), requestID: object["request_id"] as? String)
        // Preserve the exchange ID for schema failures. NativeService validates
        // arguments and returns a correlated rejection before invoking adapters.
        return request
    }
}

public enum NativeValidation {
    public static let writeOperations: Set<String> = ["calendar.events.create", "reminders.create", "reminders.complete", "drive.upload", "notes.create"]

    // The same generated schemas are used by the Hermes client and HTTP gateway.
    private static let schemas: [String: JSONObject] = {
        let appResource = Bundle.main.resourceURL?.appendingPathComponent("iBridge_IBridgeCore.bundle/operations.json")
        let url = appResource.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: "operations", withExtension: "json")
        guard let url,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              let operations = root["operations"] as? [JSONObject] else { return [:] }
        return Dictionary(uniqueKeysWithValues: operations.compactMap { item in
            guard let name = item["capability"] as? String,
                  let schema = item["schema"] as? JSONObject,
                  let parameters = schema["parameters"] as? JSONObject else { return nil }
            return (name, parameters)
        })
    }()

    public static var operationNames: [String] { schemas.keys.sorted() }

    public static func validate(_ request: NativeRequest) throws {
        if request.operation == "system.capabilities" {
            guard request.arguments.isEmpty, request.requestID == nil else {
                throw NativeError("invalid_arguments", "Capabilities accepts no arguments.")
            }
            return
        }
        guard let schema = schemas[request.operation],
              let properties = schema["properties"] as? [String: JSONObject] else {
            throw NativeError("unavailable", "This native operation is unavailable.", status: 503)
        }
        let allowed = Set(properties.keys).subtracting(["request_id"])
        let required = Set(schema["required"] as? [String] ?? []).subtracting(["request_id"])
        guard Set(request.arguments.keys).isSubset(of: allowed), required.isSubset(of: Set(request.arguments.keys)) else {
            throw NativeError("invalid_arguments", "Required arguments are missing or unknown arguments were supplied.")
        }
        if request.isWrite {
            guard let key = request.requestID,
                  matches(key, "^[A-Za-z0-9][A-Za-z0-9._:-]{7,255}$") else {
                throw NativeError("invalid_arguments", "A stable write request identifier is required.")
            }
        } else if request.requestID != nil {
            throw NativeError("invalid_arguments", "Read operations do not accept write identifiers.")
        }
        for (key, value) in request.arguments {
            guard let property = properties[key] else { continue }
            switch property["type"] as? String {
            case "string":
                guard let text = value as? String, !text.contains("\0"),
                      text.unicodeScalars.count >= (property["minLength"] as? Int ?? 0),
                      text.unicodeScalars.count <= (property["maxLength"] as? Int ?? Int.max) else {
                    throw NativeError("invalid_arguments", "An argument has invalid text or length.")
                }
                switch property["format"] as? String {
                case "date-time": _ = try date(text)
                case "relative-path": try relativePath(text, allowEmpty: key == "path" && request.operation == "drive.list")
                case "base64":
                    guard let bytes = Data(base64Encoded: text), bytes.count <= 262_144,
                          bytes.base64EncodedString() == text else {
                        throw NativeError("invalid_arguments", "File content must be canonical base64 of at most 256 KiB.")
                    }
                default: break
                }
            case "integer":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= Double(property["minimum"] as? Int ?? Int.min),
                      number.doubleValue <= Double(property["maximum"] as? Int ?? Int.max) else {
                    throw NativeError("invalid_arguments", "A numeric argument is outside its permitted range.")
                }
            case "boolean":
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw NativeError("invalid_arguments", "A boolean argument is invalid.")
                }
            default: throw NativeError("unavailable", "The operation schema is unavailable.", status: 503)
            }
        }
        if let start = request.arguments["start"] as? String, let end = request.arguments["end"] as? String {
            let interval = try date(end).timeIntervalSince(date(start))
            guard interval > 0, interval <= 366 * 86_400 else {
                throw NativeError("invalid_arguments", "The event interval must be positive and at most 366 days.")
            }
        }
    }

    public static func string(_ arguments: JSONObject, _ key: String) -> String { arguments[key] as? String ?? "" }
    public static func optionalString(_ arguments: JSONObject, _ key: String) -> String? { arguments[key] as? String }

    public static func date(_ value: String) throws -> Date {
        let pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
        guard matches(value, pattern) else {
            throw NativeError("invalid_arguments", "Dates require RFC 3339 timestamps with an explicit offset.")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let parsed = formatter.date(from: value) else {
            throw NativeError("invalid_arguments", "A timestamp is invalid.")
        }
        // Foundation may normalize invalid calendar dates; reject those explicitly.
        let datePart = String(value.prefix(10))
        let parts = datePart.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard parts.count == 3, (1...12).contains(parts[1]),
              let month = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let days = calendar.range(of: .day, in: .month, for: month), days.contains(parts[2]),
              let hour = Int(value.dropFirst(11).prefix(2)), hour < 24,
              let minute = Int(value.dropFirst(14).prefix(2)), minute < 60 else {
            throw NativeError("invalid_arguments", "A timestamp is invalid.")
        }
        return parsed
    }

    public static func relativePath(_ value: String, allowEmpty: Bool = false) throws {
        if value.isEmpty && allowEmpty { return }
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0"),
              value.utf8.count <= 2_048,
              value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NativeError("invalid_arguments", "A safe relative path is required.")
        }
    }

    private static func matches(_ string: String, _ pattern: String) -> Bool {
        guard let range = string.range(of: pattern, options: .regularExpression) else { return false }
        return range.lowerBound == string.startIndex && range.upperBound == string.endIndex
    }
}

public enum Pagination {
    public static func page(_ items: [JSONObject], arguments: JSONObject, context: String) throws -> JSONObject {
        let limit = arguments["limit"] as? Int ?? 50
        guard (1...100).contains(limit) else { throw NativeError("invalid_arguments", "The page limit is invalid.") }
        // Bind cursors to query and current result set. Changed data requires restarting
        // the query rather than silently skipping records between requests.
        let query = arguments.filter { $0.key != "cursor" && $0.key != "limit" }
        let fingerprint: JSONObject = ["context": context, "query": query, "items": items]
        let encoded = try JSONSerialization.data(withJSONObject: fingerprint, options: [.sortedKeys])
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        var offset = 0
        if let cursor = arguments["cursor"] as? String {
            guard let bytes = Data(base64Encoded: cursor), let text = String(data: bytes, encoding: .utf8) else {
                throw NativeError("invalid_cursor", "The page cursor is invalid.")
            }
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == Substring(digest), let value = Int(parts[1]), value >= 0, value <= items.count else {
                throw NativeError("invalid_cursor", "The results changed or the cursor is invalid; restart this query.")
            }
            offset = value
        }
        let end = min(offset + limit, items.count)
        var result: JSONObject = ["items": Array(items[offset..<end])]
        if end < items.count { result["next_cursor"] = Data("\(digest):\(end)".utf8).base64EncodedString() }
        return result
    }
}
