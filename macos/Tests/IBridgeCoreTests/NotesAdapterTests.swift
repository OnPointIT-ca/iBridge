import Carbon
import Foundation
import XCTest
@testable import IBridgeCore

@MainActor
private final class FakeNotesAutomation: NotesAutomationTransport {
    var permissionStatus = "authorized"
    var calls: [(String, [String], JSONObject)] = []
    var permissionRequests = 0
    var result: JSONObject = ["items": []]
    var failure: NativeError?
    func requestPermission() async throws { permissionRequests += 1 }
    func perform(operation: String, folderIDs: [String], arguments: JSONObject) throws -> JSONObject {
        calls.append((operation, folderIDs, arguments))
        if let failure { throw failure }
        return result
    }
}

final class NotesAdapterTests: XCTestCase {
    private let allowed = ResourcePolicy(["note_folder_ids": ["folder-1"]])

    @MainActor
    func testRemoteDenialNeverInvokesAutomationOrPrompts() async {
        let transport = FakeNotesAutomation()
        transport.permissionStatus = "not_determined"
        let adapter = NotesAdapter(transport: transport)
        for operation in ["notes.folders", "notes.search", "notes.read", "notes.create"] {
            do {
                _ = try await adapter.execute(NativeRequest(id: "test", operation: operation, resources: allowed))
                XCTFail("Denied Notes operation succeeded")
            } catch let error as NativeError {
                XCTAssertEqual(error.code, "permission_denied")
                XCTAssertEqual(error.outcome, "none")
            } catch { XCTFail("Unexpected error") }
        }
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertEqual(transport.permissionRequests, 0)
    }

    @MainActor
    func testExplicitLocalPermissionActionInvokesTransport() async throws {
        let transport = FakeNotesAutomation()
        try await NotesAdapter(transport: transport).requestPermission()
        XCTAssertEqual(transport.permissionRequests, 1)
    }

    @MainActor
    func testCapabilitiesRequirePermissionAndNonemptyFolders() {
        let transport = FakeNotesAutomation()
        let adapter = NotesAdapter(transport: transport)
        XCTAssertTrue(adapter.capabilities(ResourcePolicy()).values.allSatisfy { !$0 })
        XCTAssertTrue(adapter.capabilities(allowed).values.allSatisfy { $0 })
        transport.permissionStatus = "denied"
        XCTAssertTrue(adapter.capabilities(allowed).values.allSatisfy { !$0 })
        XCTAssertEqual(adapter.permissionStatus, "denied")
    }

    @MainActor
    func testExplicitFolderMustMatchExactlyBeforeAnyAutomation() async {
        let transport = FakeNotesAutomation()
        let adapter = NotesAdapter(transport: transport)
        for operation in ["notes.search", "notes.create"] {
            do {
                _ = try await adapter.execute(NativeRequest(id: "test", operation: operation,
                    arguments: ["folder_id": "folder-1/child"], resources: allowed))
                XCTFail("A child folder must not inherit authorization")
            } catch let error as NativeError {
                XCTAssertEqual(error.status, 403)
                XCTAssertEqual(error.outcome, "none")
            } catch { XCTFail("Unexpected error") }
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    @MainActor
    func testReadPassesFolderPolicyAndRejectsOutOfScopeContent() async {
        let transport = FakeNotesAutomation()
        transport.result = ["id": "note-1", "folder_id": "folder-2", "body": "fixture"]
        do {
            _ = try await NotesAdapter(transport: transport).execute(NativeRequest(id: "test", operation: "notes.read",
                arguments: ["note_id": "note-1"], resources: allowed))
            XCTFail("A note from another folder must not be returned")
        } catch let error as NativeError { XCTAssertEqual(error.status, 503) }
        catch { XCTFail("Unexpected error") }
        XCTAssertEqual(transport.calls.first?.1, ["folder-1"])
    }

    @MainActor
    func testReadRequiresExactRequestedNote() async {
        let transport = FakeNotesAutomation()
        transport.result = ["id": "other-note", "folder_id": "folder-1", "body": "fixture"]
        do {
            _ = try await NotesAdapter(transport: transport).execute(NativeRequest(id: "test", operation: "notes.read",
                arguments: ["note_id": "note-1"], resources: allowed))
            XCTFail("A different note must not be returned")
        } catch let error as NativeError { XCTAssertEqual(error.status, 503) }
        catch { XCTFail("Unexpected error") }
    }

    @MainActor
    func testSearchRejectsOutOfScopeItemsAndSelectedFolderMismatch() async {
        for policy in [allowed, ResourcePolicy(["note_folder_ids": ["*"]])] {
            let transport = FakeNotesAutomation()
            transport.result = ["items": [["id": "note-1", "folder_id": "folder-2", "title": "fixture"]]]
            do {
                _ = try await NotesAdapter(transport: transport).execute(NativeRequest(id: "test", operation: "notes.search",
                    arguments: ["query": "fixture", "folder_id": "folder-1"], resources: policy))
                XCTFail("A search must enforce the selected folder even with wildcard grants")
            } catch let error as NativeError { XCTAssertEqual(error.status, 503) }
            catch { XCTFail("Unexpected error") }
        }
    }

    @MainActor
    func testFolderPaginationUsesStableIDsAndRejectsChangedResults() async throws {
        let transport = FakeNotesAutomation()
        transport.result = ["items": [["id": "b", "name": "B"], ["id": "a", "name": "A"]]]
        let adapter = NotesAdapter(transport: transport)
        let all = ResourcePolicy(["note_folder_ids": ["*"]])
        let first = try await adapter.execute(NativeRequest(id: "test", operation: "notes.folders", arguments: ["limit": 1], resources: all))
        XCTAssertEqual((first["items"] as? [JSONObject])?.first?["id"] as? String, "a")
        let cursor = try XCTUnwrap(first["next_cursor"] as? String)
        let next = try await adapter.execute(NativeRequest(id: "test", operation: "notes.folders", arguments: ["limit": 1, "cursor": cursor], resources: all))
        XCTAssertEqual((next["items"] as? [JSONObject])?.first?["id"] as? String, "b")
        transport.result = ["items": [["id": "c", "name": "C"]]]
        do {
            _ = try await adapter.execute(NativeRequest(id: "test", operation: "notes.folders", arguments: ["cursor": cursor], resources: all))
            XCTFail("Changed folder results must invalidate the cursor")
        } catch let error as NativeError { XCTAssertEqual(error.code, "invalid_cursor") }
    }

    @MainActor
    func testCreateValidatesBeforeDispatchAndRequiresSavedReceipt() async throws {
        let transport = FakeNotesAutomation()
        let adapter = NotesAdapter(transport: transport)
        let arguments: JSONObject = ["folder_id": "folder-1", "title": "Fixture", "body": "Data"]
        do {
            _ = try await adapter.execute(NativeRequest(id: "test", operation: "notes.create", arguments: arguments, resources: allowed))
            XCTFail("A stable write identifier is required")
        } catch let error as NativeError { XCTAssertEqual(error.outcome, "none") }
        XCTAssertTrue(transport.calls.isEmpty)
        do {
            _ = try await adapter.execute(NativeRequest(id: "test", operation: "notes.create", arguments: arguments,
                resources: allowed, requestID: "client:notes-write-1"))
            XCTFail("An invalid save receipt must be uncertain")
        } catch let error as NativeError {
            XCTAssertEqual(error.status, 503)
            XCTAssertEqual(error.outcome, "unknown")
        }
        transport.result = ["id": "note-created", "state": "saved"]
        let saved = try await adapter.execute(NativeRequest(id: "test", operation: "notes.create", arguments: arguments,
            resources: allowed, requestID: "client:notes-write-2"))
        XCTAssertEqual(saved["state"] as? String, "saved")
    }

    @MainActor
    func testPlaintextIsEscapedForNotesHTMLWithoutExecutingInput() {
        let html = NotesAppleScriptTransport.noteHTML(title: "<script>&\"'", body: "one\r\ntwo\n</div><img src=x>")
        XCTAssertEqual(html, "<div><b>&lt;script&gt;&amp;&quot;&#39;</b></div><div>one<br>two<br>&lt;/div&gt;&lt;img src=x&gt;</div>")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<img"))
    }

    @MainActor
    func testBundledScriptCompilesWithoutExecutingAppleEvents() throws {
        let script = try XCTUnwrap(NSAppleScript(source: NotesAppleScriptTransport.scriptSource()))
        var diagnostic: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&diagnostic), "Static script compiler diagnostic: \(String(describing: diagnostic))")
    }

    @MainActor
    func testScriptRejectsEmptyPolicyBeforeAnyAppleEvent() throws {
        let script = try NotesAppleScriptTransport.compileScript()
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "bridge_operation"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: "notes.create"), at: 1)
        arguments.insert(NSAppleEventDescriptor.list(), at: 2)
        for index in 3...6 { arguments.insert(NSAppleEventDescriptor(string: "\" & do shell script \"never\""), at: index) }
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let response = script.executeAppleEvent(event, error: &error)
        XCTAssertNil(error)
        XCTAssertThrowsError(try NotesAppleScriptTransport.decode(response, operation: "notes.create")) { error in
            XCTAssertEqual((error as? NativeError)?.status, 403)
            XCTAssertEqual((error as? NativeError)?.outcome, "none")
        }
    }

    @MainActor
    func testLockedNotesAndUnknownWritesAreDistinct() {
        for (marker, outcome, status) in [("locked", "none", 403), ("unknown", "unknown", 503)] {
            let response = NSAppleEventDescriptor.list()
            response.insert(NSAppleEventDescriptor(string: "error"), at: 1)
            response.insert(NSAppleEventDescriptor(string: marker), at: 2)
            XCTAssertThrowsError(try NotesAppleScriptTransport.decode(response, operation: "notes.create")) { error in
                XCTAssertEqual((error as? NativeError)?.outcome, outcome)
                XCTAssertEqual((error as? NativeError)?.status, status)
            }
        }
    }

    @MainActor
    func testPermissionStatusMapping() {
        XCTAssertEqual(NotesAppleScriptTransport.permissionName(0), "authorized")
        XCTAssertEqual(NotesAppleScriptTransport.permissionName(-1744), "not_determined")
        XCTAssertEqual(NotesAppleScriptTransport.permissionName(-1743), "denied")
        XCTAssertEqual(NotesAppleScriptTransport.permissionName(-600), "not_running")
    }
}
