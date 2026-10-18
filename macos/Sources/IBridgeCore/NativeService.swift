import Foundation

@MainActor
public final class NativeService {
    public let apple: AppleAdapters
    public let drive: DriveAdapter
    public let settings: AdapterSettings
    public lazy var notes = NotesAdapter()
    public lazy var messages = MessagesAdapter()
    public let stateDirectory: URL

    public init(stateDirectory: URL = NativePaths.stateDirectory) throws {
        try NativePaths.prepareDirectory(stateDirectory)
        self.stateDirectory = stateDirectory
        settings = try AdapterSettings(stateDirectory: stateDirectory)
        apple = AppleAdapters()
        drive = try DriveAdapter(stateDirectory: stateDirectory)
        guard NativeValidation.operationNames.count == 20 else {
            throw NativeError("configuration_error", "The native operation catalog is missing or incompatible.", status: 503)
        }
    }

    public func execute(_ request: NativeRequest) async -> JSONObject {
        do {
            try NativeValidation.validate(request)
            let result: JSONObject
            if request.operation == "system.capabilities" {
                result = capabilities(request.resources)
            } else if request.operation.hasPrefix("drive.") {
                result = try await drive.execute(request)
            } else if request.operation.hasPrefix("notes.") {
                guard settings.notesEnabled else {
                    throw NativeError("permission_required", "Enable Notes in the local iBridge app first.", status: 403)
                }
                result = try await notes.execute(request)
            } else if request.operation.hasPrefix("messages.") {
                guard settings.messagesEnabled else {
                    throw NativeError("permission_required", "Enable Messages history in the local iBridge app first.", status: 403)
                }
                result = try await messages.execute(request)
            } else if request.operation.hasPrefix("calendar.") || request.operation.hasPrefix("reminders.") || request.operation == "contacts.search" {
                result = try await apple.execute(request)
            } else {
                throw NativeError("unavailable", "This service is not implemented by the native MVP.", status: 503)
            }
            return ["id": request.id, "result": result]
        } catch let error as NativeError {
            return ["id": request.id, "error": error.json]
        } catch {
            return ["id": request.id, "error": NativeError("adapter_unavailable", "The native operation could not be completed.", status: 503, outcome: request.isWrite ? "unknown" : "none").json]
        }
    }

    public func capabilities(_ policy: ResourcePolicy) -> JSONObject {
        var availability = apple.capabilities(policy)
        availability.merge(drive.capabilities(policy), uniquingKeysWith: { _, new in new })
        if settings.notesEnabled {
            availability.merge(notes.capabilities(policy), uniquingKeysWith: { _, new in new })
        }
        if settings.messagesEnabled {
            availability.merge(messages.capabilities(policy), uniquingKeysWith: { _, new in new })
        }
        var operations: JSONObject = [:]
        for name in NativeValidation.operationNames {
            let available = availability[name] ?? false
            operations[name] = available ? ["available": true] : ["available": false, "reason": "permission_required"]
        }
        return ["api_version": "1", "operations": operations]
    }

    public var status: JSONObject {
        ["api_version": "1", "host": "iBridgeHost", "minimum_macos": "14.0",
         "architecture": Self.architecture, "permissions": permissionSummary,
         "local_adapters": ["notes_enabled": settings.notesEnabled, "messages_enabled": settings.messagesEnabled],
         "selected_roots": drive.selectedRoots, "catalog_operations": NativeValidation.operationNames.count]
    }

    public var permissionSummary: [String: String] {
        var permissions = apple.permissionSummary
        permissions["notes"] = settings.notesEnabled ? notes.permissionStatus : "disabled"
        permissions["messages"] = settings.messagesEnabled ? messages.permissionStatus : "disabled"
        return permissions
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }
}
