import Contacts
import EventKit
import Foundation
import XCTest
@testable import IBridgeCore

@MainActor
final class AppleAdapterTests: XCTestCase {
    private let allCollections = ResourcePolicy([
        "calendar_ids": ["*"], "reminder_list_ids": ["*"]
    ])

    func testDeniedPermissionsDisableEveryAppleCapability() {
        let adapters = AppleAdapters(eventAuthorization: { _ in .denied }, contactAuthorization: { .denied })
        XCTAssertTrue(adapters.capabilities(allCollections).values.allSatisfy { !$0 })
        XCTAssertEqual(adapters.permissionSummary, ["calendar": "denied", "reminders": "denied", "contacts": "denied"])
    }

    func testWriteOnlyCalendarAccessDoesNotEnableReadsOrWrites() {
        let adapters = AppleAdapters(eventAuthorization: { _ in .writeOnly }, contactAuthorization: { .restricted })
        XCTAssertFalse(adapters.capabilities(allCollections)["calendar.events.create"]!)
        XCTAssertFalse(adapters.capabilities(allCollections)["calendar.events.list"]!)
        XCTAssertEqual(adapters.permissionSummary["calendar"], "write_only")
    }

    func testEmptyPolicyDisablesCollectionsDespiteFullPermission() {
        let adapters = AppleAdapters(eventAuthorization: { _ in .fullAccess }, contactAuthorization: { .authorized })
        let capabilities = adapters.capabilities(ResourcePolicy())
        XCTAssertEqual(capabilities["calendar.list"], false)
        XCTAssertEqual(capabilities["reminders.create"], false)
        XCTAssertEqual(capabilities["contacts.search"], true)
    }

    func testPolicyDoesNotEnableAnotherService() {
        let adapters = AppleAdapters(eventAuthorization: { _ in .fullAccess }, contactAuthorization: { .notDetermined })
        let capabilities = adapters.capabilities(ResourcePolicy(["calendar_ids": ["test-calendar"]]))
        XCTAssertEqual(capabilities["calendar.list"], true)
        XCTAssertEqual(capabilities["reminders.lists"], false)
        XCTAssertEqual(capabilities["contacts.search"], false)
    }

    func testRemoteOperationsFailBeforeAccessingDeniedStores() async {
        let adapters = AppleAdapters(eventAuthorization: { _ in .denied }, contactAuthorization: { .denied })
        let operations = [
            "calendar.list", "calendar.events.list", "calendar.events.create",
            "reminders.lists", "reminders.list", "reminders.create", "reminders.complete", "contacts.search"
        ]
        for operation in operations {
            do {
                _ = try await adapters.execute(NativeRequest(id: "test", operation: operation, resources: allCollections))
                XCTFail("Denied operation unexpectedly succeeded: \(operation)")
            } catch let error as NativeError {
                XCTAssertEqual(error.status, 403)
                XCTAssertEqual(error.code, "permission_denied")
                XCTAssertEqual(error.outcome, "none")
            } catch { XCTFail("Unexpected error type") }
        }
    }

    func testPermissionStatusIsRecheckedOnEveryRequest() async {
        var status: EKAuthorizationStatus = .fullAccess
        let adapters = AppleAdapters(eventAuthorization: { _ in status }, contactAuthorization: { .denied })
        XCTAssertEqual(adapters.capabilities(allCollections)["calendar.events.create"], true)
        status = .denied
        XCTAssertEqual(adapters.capabilities(allCollections)["calendar.events.create"], false)
        do {
            _ = try await adapters.execute(NativeRequest(id: "test", operation: "calendar.events.create", resources: allCollections))
            XCTFail("A revoked permission must prevent execution")
        } catch let error as NativeError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.outcome, "none")
        } catch { XCTFail("Unexpected error type") }
    }

    func testUnapprovedCollectionRejectedBeforeLookingUpStore() async {
        let adapters = AppleAdapters(eventAuthorization: { _ in .fullAccess }, contactAuthorization: { .denied })
        for (operation, key) in [("calendar.events.list", "calendar_id"), ("reminders.list", "list_id"), ("reminders.complete", "list_id")] {
            do {
                _ = try await adapters.execute(NativeRequest(id: "test", operation: operation, arguments: [key: "not-authorized"], resources: ResourcePolicy()))
                XCTFail("Unauthorized resource unexpectedly succeeded")
            } catch let error as NativeError {
                XCTAssertEqual(error.status, 403)
                XCTAssertEqual(error.code, "permission_denied")
                XCTAssertEqual(error.outcome, "none")
            } catch { XCTFail("Unexpected error type") }
        }
    }

    func testInvalidCollectionRejectedBeforeLookingUpStore() async {
        let adapters = AppleAdapters(eventAuthorization: { _ in .fullAccess }, contactAuthorization: { .denied })
        do {
            _ = try await adapters.execute(NativeRequest(id: "test", operation: "calendar.events.list", arguments: ["calendar_id": ""], resources: allCollections))
            XCTFail("An empty collection must fail")
        } catch let error as NativeError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.outcome, "none")
        } catch { XCTFail("Unexpected error type") }
    }

    func testEventIntervalAccountsForOffsets() throws {
        let range = try AppleAdapters.eventRange(["start": "2026-10-17T10:00:00-07:00", "end": "2026-10-17T18:30:00Z"])
        XCTAssertEqual(range.1.timeIntervalSince(range.0), 90 * 60)
    }

    func testEventRangeRejectsReversedUnboundedAndInvalidDates() {
        let invalidRanges: [JSONObject] = [
            ["start": "2026-10-17T10:00:00Z", "end": "2026-10-17T10:00:00Z"],
            ["start": "2026-10-17T10:00:00-07:00", "end": "2026-10-17T16:59:59Z"],
            ["start": "2026-01-01T00:00:00Z", "end": "2027-01-03T00:00:00Z"],
            ["start": "2026-02-30T10:00:00Z", "end": "2026-03-03T10:00:00Z"],
            ["start": "2026-10-17T10:00:00", "end": "2026-10-17T11:00:00Z"]
        ]
        for arguments in invalidRanges {
            XCTAssertThrowsError(try AppleAdapters.eventRange(arguments))
        }
    }

    func testMaximumEventRangeIsAccepted() throws {
        let range = try AppleAdapters.eventRange(["start": "2024-01-01T00:00:00Z", "end": "2025-01-01T00:00:00Z"])
        XCTAssertEqual(range.1.timeIntervalSince(range.0), 366 * 86_400)
    }

    func testContactSearchMatchesNamesEmailAndNormalizedPhones() {
        let matches: (String) -> Bool = { query in
            AppleAdapters.contactMatches(name: "Jos\u{00e9} Example", emails: ["hello@example.test"], phones: ["+1 (604) 555-0199"], query: query)
        }
        XCTAssertTrue(matches("JOSE"))
        XCTAssertTrue(matches("HELLO@EXAMPLE"))
        XCTAssertTrue(matches("6045550199"))
        XCTAssertTrue(matches("(604) 555"))
        XCTAssertFalse(matches("another@example.test"))
        XCTAssertFalse(matches("person555"))
    }

    func testTimestampRoundTripsWithExplicitUTCOffset() throws {
        let date = try NativeValidation.date("2026-10-17T10:00:00.125-07:00")
        let serialized = AppleAdapters.timestamp(date)
        XCTAssertTrue(serialized.hasSuffix("Z"))
        XCTAssertEqual(try NativeValidation.date(serialized).timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }
}
