import Contacts
import EventKit
import Foundation

/// Accesses only the current user's Apple stores. Permission prompts are reserved
/// for explicit actions in the local app, never an incoming RPC.
@MainActor
public final class AppleAdapters {
    private let eventStore: EKEventStore
    private let contactStore: CNContactStore
    private let eventAuthorization: (EKEntityType) -> EKAuthorizationStatus
    private let contactAuthorization: () -> CNAuthorizationStatus

    public convenience init() {
        self.init(
            eventAuthorization: { EKEventStore.authorizationStatus(for: $0) },
            contactAuthorization: { CNContactStore.authorizationStatus(for: .contacts) }
        )
    }

    // Authorization injection lets tests verify denial before any store lookup.
    internal init(
        eventAuthorization: @escaping (EKEntityType) -> EKAuthorizationStatus,
        contactAuthorization: @escaping () -> CNAuthorizationStatus
    ) {
        self.eventStore = EKEventStore()
        self.contactStore = CNContactStore()
        self.eventAuthorization = eventAuthorization
        self.contactAuthorization = contactAuthorization
    }

    public var permissionSummary: [String: String] {
        [
            "calendar": Self.eventPermissionName(eventAuthorization(.event)),
            "reminders": Self.eventPermissionName(eventAuthorization(.reminder)),
            "contacts": Self.contactPermissionName(contactAuthorization())
        ]
    }

    public func capabilities(_ policy: ResourcePolicy) -> [String: Bool] {
        let calendar = eventAuthorization(.event) == .fullAccess && policy.hasAny(.calendars)
        let reminders = eventAuthorization(.reminder) == .fullAccess && policy.hasAny(.reminderLists)
        return [
            "calendar.list": calendar,
            "calendar.events.list": calendar,
            "calendar.events.create": calendar,
            "reminders.lists": reminders,
            "reminders.list": reminders,
            "reminders.create": reminders,
            "reminders.complete": reminders,
            "contacts.search": contactAuthorization() == .authorized
        ]
    }

    /// Called by the local menu bar application's permission buttons only.
    public func requestPermission(_ service: String) async throws {
        let granted: Bool
        do {
            switch service {
            case "calendar": granted = try await eventStore.requestFullAccessToEvents()
            case "reminders": granted = try await eventStore.requestFullAccessToReminders()
            case "contacts": granted = try await contactStore.requestAccess(for: .contacts)
            default: throw NativeError("invalid_arguments", "Unknown permission service.")
            }
        } catch let error as NativeError {
            throw error
        } catch {
            throw NativeError("adapter_unavailable", "The system permission request failed.", status: 503)
        }
        guard granted else {
            throw NativeError("permission_denied", "Access was not granted. Check macOS Privacy & Security settings.", status: 403)
        }
    }

    public func execute(_ request: NativeRequest) async throws -> JSONObject {
        switch request.operation {
        case "calendar.list":
            try requireEventPermission(.event)
            try requireResources(request.resources, .calendars)
            let items = eventStore.calendars(for: .event)
                .filter { request.resources.allows(.calendars, id: $0.calendarIdentifier) }
                .map(calendarRecord)
            return try page(items, request)
        case "calendar.events.list": return try listEvents(request)
        case "calendar.events.create": return try createEvent(request)
        case "reminders.lists":
            try requireEventPermission(.reminder)
            try requireResources(request.resources, .reminderLists)
            let items = eventStore.calendars(for: .reminder)
                .filter { request.resources.allows(.reminderLists, id: $0.calendarIdentifier) }
                .map(calendarRecord)
            return try page(items, request)
        case "reminders.list": return try await listReminders(request)
        case "reminders.create": return try createReminder(request)
        case "reminders.complete": return try completeReminder(request)
        case "contacts.search": return try searchContacts(request)
        default:
            throw NativeError("unsupported_operation", "This Apple operation is not implemented.", status: 422)
        }
    }

    private func requireEventPermission(_ entity: EKEntityType) throws {
        guard eventAuthorization(entity) == .fullAccess else {
            let service = entity == .event ? "Calendar" : "Reminders"
            throw NativeError("permission_denied", "\(service) full access is unavailable. Enable it in the Mac app.", status: 403)
        }
    }

    private func requireResources(_ policy: ResourcePolicy, _ collection: ResourceCollection) throws {
        guard policy.hasAny(collection) else {
            throw NativeError("permission_denied", "No collections are authorized for this client.", status: 403)
        }
    }

    private func selectedCalendar(_ request: NativeRequest, entity: EKEntityType, write: Bool = false) throws -> EKCalendar {
        try requireEventPermission(entity)
        let collection: ResourceCollection = entity == .event ? .calendars : .reminderLists
        let id = NativeValidation.string(request.arguments, entity == .event ? "calendar_id" : "list_id")
        guard !id.isEmpty, id.count <= 512, !id.contains("\0") else {
            throw NativeError("invalid_arguments", "A valid collection identifier is required.")
        }
        guard request.resources.allows(collection, id: id) else {
            throw NativeError("permission_denied", "The selected collection is not authorized.", status: 403)
        }
        guard let calendar = eventStore.calendars(for: entity).first(where: { $0.calendarIdentifier == id }) else {
            throw NativeError("not_found", "The selected collection is no longer available.", status: 404)
        }
        if write && !calendar.allowsContentModifications {
            throw NativeError("permission_denied", "The selected collection is read-only.", status: 403)
        }
        return calendar
    }

    private func calendarRecord(_ calendar: EKCalendar) -> JSONObject {
        ["id": calendar.calendarIdentifier, "name": calendar.title, "writable": calendar.allowsContentModifications]
    }

    nonisolated internal static func eventRange(_ arguments: JSONObject) throws -> (Date, Date) {
        let start = try NativeValidation.date(NativeValidation.string(arguments, "start"))
        let end = try NativeValidation.date(NativeValidation.string(arguments, "end"))
        guard end > start, end.timeIntervalSince(start) <= 366 * 24 * 60 * 60 else {
            throw NativeError("invalid_arguments", "The event range must be positive and no longer than 366 days.")
        }
        return (start, end)
    }

    private func listEvents(_ request: NativeRequest) throws -> JSONObject {
        let calendar = try selectedCalendar(request, entity: .event)
        let (start, end) = try Self.eventRange(request.arguments)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        let events = eventStore.events(matching: predicate)
            .filter { $0.calendar.calendarIdentifier == calendar.calendarIdentifier }
            .sorted {
                if $0.startDate == $1.startDate { return $0.calendarItemIdentifier < $1.calendarItemIdentifier }
                return $0.startDate < $1.startDate
            }
        let items: [JSONObject] = events.map { event in
            var item: JSONObject = [
                "id": event.eventIdentifier ?? event.calendarItemIdentifier,
                "calendar_id": calendar.calendarIdentifier,
                "title": event.title ?? "",
                "start": Self.timestamp(event.startDate),
                "end": Self.timestamp(event.endDate),
                "all_day": event.isAllDay
            ]
            if let notes = event.notes { item["notes"] = notes }
            if let location = event.location { item["location"] = location }
            return item
        }
        return try Pagination.page(items, arguments: request.arguments, context: request.operation)
    }

    private func createEvent(_ request: NativeRequest) throws -> JSONObject {
        let calendar = try selectedCalendar(request, entity: .event, write: true)
        let (start, end) = try Self.eventRange(request.arguments)
        let title = NativeValidation.string(request.arguments, "title")
        let notes = NativeValidation.optionalString(request.arguments, "notes")
        let location = NativeValidation.optionalString(request.arguments, "location")
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.location = location
        event.isAllDay = false
        // No attendees, alarms, recurrence, or invitation settings are supplied.
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
        } catch {
            throw NativeError("adapter_unavailable", "The calendar save could not be confirmed. Reconcile before retrying.", status: 503, outcome: "unknown")
        }
        return try saved(event.eventIdentifier ?? event.calendarItemIdentifier)
    }

    private func listReminders(_ request: NativeRequest) async throws -> JSONObject {
        let calendar = try selectedCalendar(request, entity: .reminder)
        let predicate = eventStore.predicateForReminders(in: [calendar])
        let reminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            let gate = ReminderFetchGate(continuation)
            let fetch = eventStore.fetchReminders(matching: predicate) { values in
                if let values {
                    gate.finish(.success(values))
                } else {
                    gate.finish(.failure(NativeError("adapter_unavailable", "Reminders could not be read.", status: 503)))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [eventStore] in
                if gate.finish(.failure(NativeError("adapter_unavailable", "The reminders query timed out.", status: 503))) {
                    eventStore.cancelFetchRequest(fetch)
                }
            }
        }
        // Permission can be revoked while the asynchronous query is in flight.
        try requireEventPermission(.reminder)
        let completed = request.arguments["completed"] as? Bool
        let items = reminders.filter {
            $0.calendar.calendarIdentifier == calendar.calendarIdentifier && (completed == nil || $0.isCompleted == completed)
        }.map { reminder -> JSONObject in
            var item: JSONObject = [
                "id": reminder.calendarItemIdentifier,
                "list_id": calendar.calendarIdentifier,
                "title": reminder.title ?? "",
                "completed": reminder.isCompleted
            ]
            if let notes = reminder.notes { item["notes"] = notes }
            if let components = reminder.dueDateComponents {
                var gregorian = Calendar(identifier: .gregorian)
                gregorian.timeZone = components.timeZone ?? .current
                if let date = (components.calendar ?? gregorian).date(from: components) {
                    item["due"] = Self.timestamp(date)
                    item["due_has_time"] = components.hour != nil
                }
            }
            if let completedAt = reminder.completionDate { item["completed_at"] = Self.timestamp(completedAt) }
            return item
        }
        return try page(items, request)
    }

    private func createReminder(_ request: NativeRequest) throws -> JSONObject {
        let calendar = try selectedCalendar(request, entity: .reminder, write: true)
        let title = NativeValidation.string(request.arguments, "title")
        let notes = NativeValidation.optionalString(request.arguments, "notes")
        let dueText = NativeValidation.optionalString(request.arguments, "due")
        let due = try dueText.map(NativeValidation.date)
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes
        if let due {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            reminder.dueDateComponents = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: due)
        }
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw NativeError("adapter_unavailable", "The reminder save could not be confirmed. Reconcile before retrying.", status: 503, outcome: "unknown")
        }
        return try saved(reminder.calendarItemIdentifier)
    }

    private func completeReminder(_ request: NativeRequest) throws -> JSONObject {
        let calendar = try selectedCalendar(request, entity: .reminder, write: true)
        let id = NativeValidation.string(request.arguments, "reminder_id")
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder,
              reminder.calendar.calendarIdentifier == calendar.calendarIdentifier else {
            // Do not disclose a reminder belonging to a different list.
            throw NativeError("not_found", "The reminder is not available in the selected list.", status: 404)
        }
        if reminder.isCompleted { return try saved(reminder.calendarItemIdentifier) }
        // Completing a recurring reminder may create its next occurrence. That
        // behavior is deliberately excluded from this single-resource MVP.
        guard !reminder.hasRecurrenceRules else {
            throw NativeError("unsupported_arguments", "Completing recurring reminders is not supported.", status: 422)
        }
        reminder.isCompleted = true
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw NativeError("adapter_unavailable", "Reminder completion could not be confirmed. Reconcile before retrying.", status: 503, outcome: "unknown")
        }
        return try saved(reminder.calendarItemIdentifier)
    }

    private func searchContacts(_ request: NativeRequest) throws -> JSONObject {
        guard contactAuthorization() == .authorized else {
            throw NativeError("permission_denied", "Contacts access is unavailable. Enable it in the Mac app.", status: 403)
        }
        let query = NativeValidation.string(request.arguments, "query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw NativeError("invalid_arguments", "A nonblank contact query is required.")
        }
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey, CNContactGivenNameKey, CNContactMiddleNameKey,
            CNContactFamilyNameKey, CNContactNamePrefixKey, CNContactNameSuffixKey,
            CNContactNicknameKey, CNContactOrganizationNameKey,
            CNContactEmailAddressesKey, CNContactPhoneNumbersKey
        ].map { $0 as CNKeyDescriptor }
        let fetch = CNContactFetchRequest(keysToFetch: keys)
        fetch.unifyResults = true
        var items: [JSONObject] = []
        var scanned = 0
        var tooBroad = false
        do {
            try contactStore.enumerateContacts(with: fetch) { contact, stop in
                scanned += 1
                if scanned > 50_000 || items.count >= 10_000 {
                    tooBroad = true
                    stop.pointee = true
                    return
                }
                let name = [contact.namePrefix, contact.givenName, contact.middleName, contact.familyName, contact.nameSuffix]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                let displayName = name.isEmpty ? contact.organizationName : name
                let emails = contact.emailAddresses.map { $0.value as String }
                let phones = contact.phoneNumbers.map { $0.value.stringValue }
                let searchableName = [displayName, contact.nickname, contact.organizationName].joined(separator: " ")
                guard Self.contactMatches(name: searchableName, emails: emails, phones: phones, query: query) else { return }
                items.append([
                    "id": contact.identifier, "name": displayName,
                    "emails": emails, "phones": phones, "organization": contact.organizationName
                ])
            }
        } catch {
            if contactAuthorization() != .authorized {
                throw NativeError("permission_denied", "Contacts access is unavailable.", status: 403)
            }
            throw NativeError("adapter_unavailable", "Contacts could not be read.", status: 503)
        }
        guard !tooBroad else {
            throw NativeError("query_too_broad", "The contact query exceeded the local search limit.", status: 422)
        }
        return try page(items, request)
    }

    nonisolated internal static func contactMatches(name: String, emails: [String], phones: [String], query: String) -> Bool {
        func fold(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let needle = fold(query)
        if ([name] + emails + phones).contains(where: { fold($0).contains(needle) }) { return true }
        // Permit a phone query without matching digits stripped out of a name.
        let phoneCharacters = CharacterSet(charactersIn: "+()-. ").union(.decimalDigits)
        guard query.unicodeScalars.allSatisfy({ phoneCharacters.contains($0) }) else { return false }
        let digits = query.filter { $0.isNumber }
        guard digits.count >= 3 else { return false }
        return phones.contains { $0.filter { $0.isNumber }.contains(digits) }
    }

    private func page(_ items: [JSONObject], _ request: NativeRequest) throws -> JSONObject {
        let sorted = items.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        return try Pagination.page(sorted, arguments: request.arguments, context: request.operation)
    }

    private func saved(_ id: String) throws -> JSONObject {
        guard !id.isEmpty else {
            throw NativeError("adapter_unavailable", "The saved resource identifier is unavailable. Reconcile before retrying.", status: 503, outcome: "unknown")
        }
        return ["id": id, "state": "saved"]
    }

    nonisolated internal static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    nonisolated private static func eventPermissionName(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "authorized"
        case .writeOnly: return "write_only"
        @unknown default: return "unavailable"
        }
    }

    nonisolated private static func contactPermissionName(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unavailable"
        }
    }
}

/// EventKit invokes fetch callbacks on its own queue. A timeout and callback
/// must never resume a continuation twice, including a late cancelled callback.
private final class ReminderFetchGate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[EKReminder], Error>?

    init(_ continuation: CheckedContinuation<[EKReminder], Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ result: Result<[EKReminder], Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}
