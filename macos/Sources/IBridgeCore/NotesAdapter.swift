import AppKit
import Carbon
import Foundation

/// Notes automation runs inside the signed host, so macOS grants access to iBridge,
/// rather than to an unrelated shell interpreter. All inputs are AppleEvent data.
@MainActor
internal protocol NotesAutomationTransport {
    var permissionStatus: String { get }
    func requestPermission() async throws
    func perform(operation: String, folderIDs: [String], arguments: JSONObject) throws -> JSONObject
}

@MainActor
public final class NotesAdapter {
    private let transport: NotesAutomationTransport

    public convenience init() { self.init(transport: NotesAppleScriptTransport()) }
    internal init(transport: NotesAutomationTransport) { self.transport = transport }

    public var permissionStatus: String { transport.permissionStatus }

    /// Only the local app's explicit permission button may invoke this method.
    public func requestPermission() async throws { try await transport.requestPermission() }

    public func capabilities(_ policy: ResourcePolicy) -> [String: Bool] {
        let enabled = permissionStatus == "authorized" && policy.hasAny(.notesFolders)
        return Dictionary(uniqueKeysWithValues: ["notes.folders", "notes.search", "notes.read", "notes.create"].map { ($0, enabled) })
    }

    public func execute(_ request: NativeRequest) async throws -> JSONObject {
        guard permissionStatus == "authorized" else {
            throw NativeError("permission_denied", "Notes Automation access is unavailable. Enable it in the Mac app.", status: 403)
        }
        guard request.resources.hasAny(.notesFolders) else {
            throw NativeError("permission_denied", "No Notes folders are authorized for this client.", status: 403)
        }
        guard ["notes.folders", "notes.search", "notes.read", "notes.create"].contains(request.operation) else {
            throw NativeError("unsupported_arguments", "This Notes operation is unavailable.", status: 422)
        }
        if let folder = request.arguments["folder_id"] as? String,
           !request.resources.allows(.notesFolders, id: folder) {
            throw NativeError("permission_denied", "The selected Notes folder is not authorized.", status: 403)
        }
        try NativeValidation.validate(request)
        // The script receives the policy before it enumerates notes or reads text.
        let result = try transport.perform(operation: request.operation,
                                           folderIDs: request.resources.identifiers(for: .notesFolders),
                                           arguments: request.arguments)
        switch request.operation {
        case "notes.folders", "notes.search":
            guard let items = result["items"] as? [JSONObject], items.count <= 2_000 else { throw invalidResult(request) }
            let field = request.operation == "notes.folders" ? "id" : "folder_id"
            // Recheck every returned item, including any independently supplied folder.
            guard items.allSatisfy({ item in
                guard let id = item[field] as? String, request.resources.allows(.notesFolders, id: id) else { return false }
                return request.arguments["folder_id"] == nil || request.arguments["folder_id"] as? String == id
            }) else { throw invalidResult(request) }
            let sorted = items.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
            return try Pagination.page(sorted, arguments: request.arguments, context: request.operation)
        case "notes.read":
            guard let folder = result["folder_id"] as? String,
                  request.resources.allows(.notesFolders, id: folder),
                  result["id"] as? String == request.arguments["note_id"] as? String else { throw invalidResult(request) }
            return result
        case "notes.create":
            guard let id = result["id"] as? String, !id.isEmpty, id.count <= 512,
                  result["state"] as? String == "saved" else { throw invalidResult(request) }
            return result
        default: throw invalidResult(request)
        }
    }

    private func invalidResult(_ request: NativeRequest) -> NativeError {
        NativeError("adapter_unavailable", "Notes did not return a valid scoped result.", status: 503,
                    outcome: request.isWrite ? "unknown" : "none")
    }
}

@MainActor
internal final class NotesAppleScriptTransport: NotesAutomationTransport {
    private static let bundleID = "com.apple.Notes"

    var permissionStatus: String {
        // This does not launch Notes or request consent. A stopped Notes app may
        // report unavailable until the user opens it or presses the local button.
        Self.permissionName(checkPermission(ask: false))
    }

    func requestPermission() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            throw NativeError("adapter_unavailable", "Notes is not installed on this Mac.", status: 503)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration) }
        catch { throw NativeError("adapter_unavailable", "Notes could not be opened.", status: 503) }
        guard checkPermission(ask: true) == noErr else {
            throw NativeError("permission_denied", "Notes Automation access was not granted. Check macOS Privacy & Security.", status: 403)
        }
    }

    private func checkPermission(ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    }

    internal static func permissionName(_ status: OSStatus) -> String {
        switch status {
        case noErr: return "authorized"
        case -1744: return "not_determined"
        case -1743: return "denied"
        case -600: return "not_running"
        default: return "unavailable"
        }
    }

    internal static func scriptSource() throws -> String {
        let appResource = Bundle.main.resourceURL?.appendingPathComponent("iBridge_IBridgeCore.bundle/Notes.applescript")
        let url = appResource.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: "Notes", withExtension: "applescript")
        guard let url, let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw NativeError("adapter_unavailable", "The Notes automation resource is unavailable.", status: 503)
        }
        return source
    }

    /// Compile without sending events or accessing an Apple account; exercised in Mac CI.
    internal static func compileScript() throws -> NSAppleScript {
        guard let script = NSAppleScript(source: try scriptSource()) else {
            throw NativeError("adapter_unavailable", "The Notes automation could not be loaded.", status: 503)
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            // Compiler diagnostics contain source snippets; never relay them to clients.
            throw NativeError("adapter_unavailable", "The Notes automation could not be compiled.", status: 503)
        }
        return script
    }

    internal static func noteHTML(title: String, body: String) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        return "<div><b>\(escape(title))</b></div><div>\(escape(body))</div>"
    }

    func perform(operation: String, folderIDs: [String], arguments: JSONObject) throws -> JSONObject {
        // Recheck immediately before sending any event; never prompt remotely.
        guard permissionStatus == "authorized" else {
            throw NativeError("permission_denied", "Notes Automation permission is unavailable.", status: 403)
        }
        let script = try Self.compileScript()
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                          eventID: AEEventID(kASSubroutineEvent),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "bridge_operation"), forKeyword: AEKeyword(keyASSubroutineName))
        let params = NSAppleEventDescriptor.list()
        let folders = NSAppleEventDescriptor.list()
        for (offset, id) in folderIDs.enumerated() { folders.insert(NSAppleEventDescriptor(string: id), at: offset + 1) }
        let values: [NSAppleEventDescriptor] = [
            NSAppleEventDescriptor(string: operation), folders,
            NSAppleEventDescriptor(string: arguments["folder_id"] as? String ?? ""),
            NSAppleEventDescriptor(string: arguments["note_id"] as? String ?? ""),
            NSAppleEventDescriptor(string: arguments["query"] as? String ?? ""),
            NSAppleEventDescriptor(string: Self.noteHTML(title: arguments["title"] as? String ?? "", body: arguments["body"] as? String ?? ""))
        ]
        for (offset, value) in values.enumerated() { params.insert(value, at: offset + 1) }
        event.setParam(params, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let response = script.executeAppleEvent(event, error: &error)
        guard error == nil else {
            throw NativeError("adapter_unavailable", "Notes did not confirm the operation.", status: 503,
                              outcome: operation == "notes.create" ? "unknown" : "none")
        }
        return try Self.decode(response, operation: operation)
    }

    internal static func decode(_ descriptor: NSAppleEventDescriptor, operation: String) throws -> JSONObject {
        func invalid() -> NativeError {
            NativeError("adapter_unavailable", "Notes returned an invalid response.", status: 503,
                        outcome: operation == "notes.create" ? "unknown" : "none")
        }
        guard descriptor.descriptorType == typeAEList, let kind = descriptor.atIndex(1)?.stringValue else { throw invalid() }
        if kind == "error" {
            switch descriptor.atIndex(2)?.stringValue {
            case "not_found": throw NativeError("not_found", "The note or folder is unavailable within the authorized folders.", status: 404)
            case "locked": throw NativeError("permission_denied", "Locked notes are not supported.", status: 403)
            case "permission_denied": throw NativeError("permission_denied", "The Notes folder is not authorized.", status: 403)
            case "too_large": throw NativeError("request_too_large", "The Notes result exceeds the bounded scan or text limit. Narrow the selected folders.", status: 413)
            case "timeout": throw NativeError("adapter_unavailable", "The Notes scan exceeded its time limit. Narrow the selected folders.", status: 503)
            case "unknown": throw NativeError("outcome_unknown", "The Notes save could not be confirmed. Reconcile before retrying.", status: 503, outcome: "unknown")
            default: throw invalid()
            }
        }
        var bytes = 0
        func text(_ value: NSAppleEventDescriptor?, _ index: Int, maximum: Int = 262_144) throws -> String {
            guard let string = value?.atIndex(index)?.stringValue, string.utf8.count <= maximum else { throw invalid() }
            bytes += string.utf8.count
            guard bytes <= 1_048_576 else { throw invalid() }
            return string
        }
        func note(_ row: NSAppleEventDescriptor, read: Bool) throws -> JSONObject {
            let id = try text(row, 1, maximum: 512), folder = try text(row, 2, maximum: 512)
            let title = try text(row, 3, maximum: 4_096), content = try text(row, 4)
            return ["id": id, "folder_id": folder, "title": title, read ? "body" : "snippet": content,
                    "content_format": "plain_text", "body_includes_title": true,
                    "rich_content_preserved": false, "attachments_included": false,
                    "has_attachments": row.atIndex(5)?.booleanValue ?? false]
        }
        switch (operation, kind) {
        case ("notes.folders", "folders"), ("notes.search", "search"):
            guard let rows = descriptor.atIndex(2), rows.descriptorType == typeAEList, rows.numberOfItems <= 2_000 else { throw invalid() }
            var items: [JSONObject] = []
            if rows.numberOfItems > 0 {
                for index in 1...rows.numberOfItems {
                    guard let row = rows.atIndex(index), row.descriptorType == typeAEList else { throw invalid() }
                    if operation == "notes.folders" {
                        items.append(["id": try text(row, 1, maximum: 512), "name": try text(row, 2, maximum: 4_096)])
                    } else { items.append(try note(row, read: false)) }
                }
            }
            return ["items": items]
        case ("notes.read", "read"):
            guard let row = descriptor.atIndex(2), row.descriptorType == typeAEList else { throw invalid() }
            return try note(row, read: true)
        case ("notes.create", "created"):
            let id = try text(descriptor, 2, maximum: 512)
            guard !id.isEmpty else { throw invalid() }
            return ["id": id, "state": "saved"]
        default: throw invalid()
        }
    }
}
