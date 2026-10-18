import Foundation
import XCTest
@testable import IBridgeCore

final class AdapterSettingsTests: XCTestCase {
    private func state() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NativePaths.prepareDirectory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    func testNewInstallationDoesNotGrantEitherAdapter() throws {
        let url = try state()
        let settings = try AdapterSettings(stateDirectory: url)
        XCTAssertFalse(settings.notesEnabled)
        XCTAssertFalse(settings.messagesEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("adapter-settings.json").path))
    }

    @MainActor
    func testLocalGrantsAndRevocationsSurviveRestartIndependently() throws {
        let url = try state()
        let settings = try AdapterSettings(stateDirectory: url)
        try settings.setNotesEnabled(true)
        let afterNotes = try AdapterSettings(stateDirectory: url)
        XCTAssertTrue(afterNotes.notesEnabled)
        XCTAssertFalse(afterNotes.messagesEnabled)
        try afterNotes.setMessagesEnabled(true)
        try afterNotes.setNotesEnabled(false)
        let afterRevocation = try AdapterSettings(stateDirectory: url)
        XCTAssertFalse(afterRevocation.notesEnabled)
        XCTAssertTrue(afterRevocation.messagesEnabled)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("adapter-settings.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testSymlinkCannotSupplyConsent() throws {
        let url = try state()
        let target = url.appendingPathComponent("other.json")
        try Data("{\"version\":1,\"notesEnabled\":true,\"messagesEnabled\":true}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("adapter-settings.json"), withDestinationURL: target)
        XCTAssertThrowsError(try AdapterSettings(stateDirectory: url))
    }

    @MainActor
    func testMalformedUnsupportedAndPublicSettingsFailClosed() throws {
        let url = try state()
        let path = url.appendingPathComponent("adapter-settings.json")
        for content in ["{}", "{\"version\":2,\"notesEnabled\":true,\"messagesEnabled\":true}", "{\"version\":1,\"notesEnabled\":\"yes\",\"messagesEnabled\":true}", String(repeating: "x", count: 4_097)] {
            try Data(content.utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            XCTAssertThrowsError(try AdapterSettings(stateDirectory: url))
        }
        try Data("{\"version\":1,\"notesEnabled\":true,\"messagesEnabled\":true}".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        XCTAssertThrowsError(try AdapterSettings(stateDirectory: url))
    }
}
