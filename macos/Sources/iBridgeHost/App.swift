import AppKit
import SwiftUI
import IBridgeCore

@MainActor
final class HostModel: ObservableObject {
    @Published var running = false
    @Published var message = "Starting native host…"
    @Published var permissions: [String: String] = [:]
    @Published var notesEnabled = false
    @Published var messagesEnabled = false
    @Published var roots: [RootRow] = []
    private var service: NativeService?
    private var server: UnixSocketServer?

    struct RootRow: Identifiable {
        let id: String
        let name: String
    }

    init() {
        do {
            let service = try NativeService()
            let server = UnixSocketServer(stateDirectory: service.stateDirectory)
            self.service = service; self.server = server
            try server.start { request in await service.execute(request) }
            running = true
            message = "Native host is ready"
            refresh()
        } catch {
            message = (error as? NativeError)?.message ?? "The native host could not start. Check the application state directory."
        }
    }

    func refresh() {
        guard let service else { return }
        permissions = service.permissionSummary
        notesEnabled = service.settings.notesEnabled
        messagesEnabled = service.settings.messagesEnabled
        roots = service.drive.selectedRoots.compactMap {
            guard let id = $0["id"] as? String, let name = $0["name"] as? String else { return nil }
            return RootRow(id: id, name: name)
        }
    }

    func grant(_ name: String) {
        Task {
            do {
                try await service?.apple.requestPermission(name)
                message = "Permission request finished"
            } catch {
                message = "Permission is unavailable. Review iBridge in System Settings → Privacy & Security."
            }
            refresh()
        }
    }

    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow Folder"
        panel.message = "Choose an iCloud Drive folder or local folder to make available to explicitly authorized iBridge clients."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try service?.drive.addRoot(url)
            message = "Folder added. Grant its root ID in the client policy to enable remote access."
        } catch {
            message = "The selected folder could not be authorized."
        }
        refresh()
    }

    func toggleNotes() {
        guard let service else { return }
        Task {
            do {
                if service.settings.notesEnabled {
                    try service.settings.setNotesEnabled(false)
                    message = "Notes access disabled"
                } else {
                    try await service.notes.requestPermission()
                    try service.settings.setNotesEnabled(true)
                    message = "Notes enabled. Grant folder IDs to the clients that should have access."
                }
            } catch {
                message = "Notes could not be enabled. Review iBridge → Notes in System Settings → Privacy & Security → Automation."
            }
            refresh()
        }
    }

    func toggleMessages() {
        guard let service else { return }
        do {
            try service.settings.setMessagesEnabled(!service.settings.messagesEnabled)
            message = service.settings.messagesEnabled
                ? "Messages history enabled. Grant Full Disk Access to iBridge in System Settings, then restart iBridge if requested."
                : "Messages history access disabled"
        } catch { message = "Messages access settings could not be saved." }
        refresh()
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func removeFolder(_ id: String) {
        do {
            try service?.drive.removeRoot(id: id)
            message = "Folder access removed"
        } catch { message = "Folder access could not be updated." }
        refresh()
    }

    func quit() {
        server?.stop()
        NSApp.terminate(nil)
    }
}

@MainActor
struct HostApplication: App {
    @StateObject private var model = HostModel()

    var body: some Scene {
        MenuBarExtra("iBridge", systemImage: model.running ? "link.circle.fill" : "exclamationmark.circle") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("iBridge").font(.headline)
                    Text(model.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    ForEach(["calendar", "reminders", "contacts"], id: \.self) { name in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(name.capitalized)
                                Text(model.permissions[name] ?? "unknown").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Request Access") { model.grant(name) }
                        }
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Notes")
                            Text(model.permissions["notes"] ?? "disabled").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.notesEnabled ? "Disable Notes" : "Enable Notes…") { model.toggleNotes() }
                    }
                    Text("Reads ordinary unlocked notes and creates new notes in client-authorized folders.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Messages history")
                            Text(model.permissions["messages"] ?? "disabled").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.messagesEnabled ? "Disable History" : "Enable History") { model.toggleMessages() }
                    }
                    Text("Reads local conversations. Requires Full Disk Access for iBridge and conversation grants for each client.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
                    Divider()
                    Text("Authorized folders").font(.subheadline)
                    if model.roots.isEmpty { Text("No folders selected").font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.roots) { root in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(root.name).lineLimit(1)
                                Text(root.id).font(.caption2).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Remove") { model.removeFolder(root.id) }
                        }
                    }
                    Button("Add Folder…") { model.selectFolder() }
                    Text("Remote requests never show permission prompts. Messages access is read-only.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    HStack {
                        Button("Refresh Status") { model.refresh() }
                        Spacer()
                        Button("Quit") { model.quit() }
                    }
                }
                .padding().frame(width: 390)
                .onAppear { model.refresh() }
            }.frame(maxHeight: 660)
        }
        .menuBarExtraStyle(.window)
    }
}

@main
enum HostMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--check") {
            do {
                let service = try NativeService()
                let data = try JSONSerialization.data(withJSONObject: service.status, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data + Data([10]))
            } catch {
                let data = Data("{\"error\":\"Native host configuration could not be loaded.\"}\n".utf8)
                FileHandle.standardError.write(data)
                exit(1)
            }
            return
        }
        guard CommandLine.arguments.dropFirst().allSatisfy({ $0 == "--serve" || $0.hasPrefix("-psn_") }) else {
            FileHandle.standardError.write(Data("Usage: iBridgeHost [--serve | --check]\n".utf8))
            exit(64)
        }
        HostApplication.main()
    }
}
