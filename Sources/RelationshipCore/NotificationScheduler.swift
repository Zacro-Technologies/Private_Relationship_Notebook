import CryptoKit
import Foundation
import UserNotifications

/// Stable, privacy-minimized metadata shared by scheduled reminders and the
/// app's notification-response router. Notification payloads contain only an
/// opaque record identifier; names, notes, and relationship facts are never
/// required to open the corresponding in-app screen.
public enum ConnectionNotificationRoute: Equatable, Sendable {
    case today
    case person(UUID)
}

public enum ConnectionNotificationMetadata {
    public static let categoryIdentifier = "relationship-notebook.connection-reminder"
    public static let destinationUserInfoKey = "relationship-notebook.destination"
    public static let personIDUserInfoKey = "relationship-notebook.person-id"
    private static let todayDestination = "today"
    private static let personDestination = "person"

    public static func userInfo(for route: ConnectionNotificationRoute) -> [AnyHashable: Any] {
        switch route {
        case .today:
            [destinationUserInfoKey: todayDestination]
        case let .person(personID):
            [
                destinationUserInfoKey: personDestination,
                personIDUserInfoKey: personID.uuidString,
            ]
        }
    }

    public static func route(
        from userInfo: [AnyHashable: Any],
        categoryIdentifier: String
    ) -> ConnectionNotificationRoute? {
        guard categoryIdentifier == self.categoryIdentifier else { return nil }
        switch userInfo[destinationUserInfoKey] as? String {
        case todayDestination:
            return .today
        case personDestination:
            guard let value = userInfo[personIDUserInfoKey] as? String,
                  let personID = UUID(uuidString: value) else { return nil }
            return .person(personID)
        case nil:
            // Preserve taps from explicit reminders scheduled by an older app
            // version before the destination discriminator was introduced.
            guard let value = userInfo[personIDUserInfoKey] as? String,
                  let personID = UUID(uuidString: value) else { return nil }
            return .person(personID)
        default:
            return nil
        }
    }

    public static func personID(
        from userInfo: [AnyHashable: Any],
        categoryIdentifier: String
    ) -> UUID? {
        guard case let .person(personID) = route(
            from: userInfo,
            categoryIdentifier: categoryIdentifier
        ) else { return nil }
        return personID
    }
}

public struct NotificationPrivacy: Codable, Equatable, Sendable {
    public var showPersonNames: Bool
    public var showContext: Bool

    public init(showPersonNames: Bool = false, showContext: Bool = false) {
        self.showPersonNames = showPersonNames
        self.showContext = showContext
    }
}

public struct ScheduledConnectionReminder: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case explicitReminder
        case proactiveNudge
    }

    public var id: UUID
    public var fireDate: Date
    public var personID: UUID?
    public var personName: String?
    public var context: String?
    public var allowsPersonName: Bool
    public var allowsContext: Bool
    public var recurrence: RecurrenceRule
    public var kind: Kind

    public init(
        id: UUID = UUID(),
        fireDate: Date,
        personID: UUID? = nil,
        personName: String? = nil,
        context: String? = nil,
        allowsPersonName: Bool = false,
        allowsContext: Bool = false,
        recurrence: RecurrenceRule = .none,
        kind: Kind = .explicitReminder
    ) {
        self.id = id
        self.fireDate = fireDate
        self.personID = personID
        self.personName = personName
        self.context = context
        self.allowsPersonName = allowsPersonName
        self.allowsContext = allowsContext
        self.recurrence = recurrence
        self.kind = kind
    }
}

public enum ConnectionNotificationUnscheduledReason: Equatable, Sendable {
    /// A non-repeating notification whose delivery date has already elapsed.
    case pastDue
    /// The reminder needs more pending requests than the app's current budget.
    case capacity
    /// The recurrence rule did not produce any deliverable notification request.
    case invalidSchedule
}

public enum ConnectionNotificationSchedulingOutcome: Equatable, Sendable {
    case scheduled(requestCount: Int)
    case unscheduled(ConnectionNotificationUnscheduledReason)
}

/// Truthful result of one reconciliation pass. The budget is measured in OS
/// notification requests rather than reminder records because (for example) a
/// weekly reminder can require one request per selected weekday.
public struct ConnectionNotificationReconciliationReport: Equatable, Sendable {
    public var requestBudget: Int
    public var scheduledRequestCount: Int
    public var outcomes: [UUID: ConnectionNotificationSchedulingOutcome]

    public init(
        requestBudget: Int,
        scheduledRequestCount: Int,
        outcomes: [UUID: ConnectionNotificationSchedulingOutcome]
    ) {
        self.requestBudget = requestBudget
        self.scheduledRequestCount = scheduledRequestCount
        self.outcomes = outcomes
    }

    public static let empty = ConnectionNotificationReconciliationReport(
        requestBudget: 0,
        scheduledRequestCount: 0,
        outcomes: [:]
    )

    public var capacityLimitedReminderCount: Int {
        outcomes.values.reduce(into: 0) { count, outcome in
            if outcome == .unscheduled(.capacity) { count += 1 }
        }
    }
}

public struct PlannedConnectionNotificationAllocation: Equatable, Sendable {
    public var reminder: ScheduledConnectionReminder
    public var patterns: [NotificationRecurrencePattern]

    public init(
        reminder: ScheduledConnectionReminder,
        patterns: [NotificationRecurrencePattern]
    ) {
        self.reminder = reminder
        self.patterns = patterns
    }
}

public struct ConnectionNotificationRequestPlan: Equatable, Sendable {
    public var allocations: [PlannedConnectionNotificationAllocation]
    public var report: ConnectionNotificationReconciliationReport

    public init(
        allocations: [PlannedConnectionNotificationAllocation],
        report: ConnectionNotificationReconciliationReport
    ) {
        self.allocations = allocations
        self.report = report
    }
}

/// Allocates pending requests deterministically and atomically per reminder.
/// A recurrence is never presented as scheduled when only some of its native
/// notification patterns fit in the remaining capacity.
public enum ConnectionNotificationRequestPlanner {
    public static func plan(
        _ reminders: [ScheduledConnectionReminder],
        requestBudget: Int,
        after date: Date = .now,
        calendar: Calendar = .current
    ) -> ConnectionNotificationRequestPlan {
        let budget = max(0, requestBudget)
        var remaining = budget
        var allocations: [PlannedConnectionNotificationAllocation] = []
        var outcomes: [UUID: ConnectionNotificationSchedulingOutcome] = [:]

        for reminder in prioritized(reminders) {
            let patterns = NotificationRecurrencePlanner.patterns(
                fireDate: reminder.fireDate,
                recurrence: reminder.recurrence,
                calendar: calendar
            )
            guard !patterns.isEmpty else {
                outcomes[reminder.id] = .unscheduled(.invalidSchedule)
                continue
            }
            guard patterns.contains(where: { $0.repeats || reminder.fireDate > date }) else {
                outcomes[reminder.id] = .unscheduled(.pastDue)
                continue
            }
            guard patterns.count <= remaining else {
                outcomes[reminder.id] = .unscheduled(.capacity)
                continue
            }
            remaining -= patterns.count
            allocations.append(.init(reminder: reminder, patterns: patterns))
            outcomes[reminder.id] = .scheduled(requestCount: patterns.count)
        }

        return ConnectionNotificationRequestPlan(
            allocations: allocations,
            report: .init(
                requestBudget: budget,
                scheduledRequestCount: budget - remaining,
                outcomes: outcomes
            )
        )
    }

    private static func prioritized(
        _ reminders: [ScheduledConnectionReminder]
    ) -> [ScheduledConnectionReminder] {
        reminders.sorted { left, right in
            if left.kind != right.kind {
                return left.kind == .explicitReminder
            }
            if left.fireDate != right.fireDate {
                return left.fireDate < right.fireDate
            }
            return left.id.uuidString < right.id.uuidString
        }
    }
}

public func makeScheduledConnectionReminders(
    reminders: [Reminder],
    people: [Person],
    quietHoursStart: Double,
    quietHoursEnd: Double,
    calendar: Calendar = .current
) -> [ScheduledConnectionReminder] {
    reminders.compactMap { reminder in
        guard reminder.isActionable, case let .person(personID) = reminder.subject else { return nil }
        guard let person = people.first(where: {
            $0.id == personID && $0.deletedAt == nil
        }) else { return nil }
        let rawDate: Date
        switch reminder.effectiveDue {
        case let .instant(date, _): rawDate = date
        case let .partialDate(date): rawDate = date.earliestInstant
        }
        return ScheduledConnectionReminder(
            id: reminder.id,
            fireDate: connectionReminderDateOutsideQuietHours(
                rawDate,
                startHour: Int(quietHoursStart),
                endHour: Int(quietHoursEnd),
                calendar: calendar
            ),
            personID: personID,
            personName: person.displayName,
            // A context string can originate from a sensitive assertion. The
            // system notification projection is deny-by-default until it can
            // prove an effective notification allow policy for that value.
            context: nil,
            allowsPersonName: reminder.notificationPrivacy != .generic,
            allowsContext: false,
            recurrence: reminder.recurrence,
            kind: .explicitReminder
        )
    }
}

public enum NudgePoolSelection: Codable, Hashable, Sendable {
    case everyone
    case savedView(UUID)
    case circle(RelationshipCircle)
    case context(String)

    private enum StoredSelection: Codable {
        case everyone
        case savedView(UUID)
        case circle(RelationshipCircle)
        case contextDigest(String)
    }

    public init(storageValue: String?, availableContexts: [String] = []) {
        guard let storageValue,
              let data = Data(base64Encoded: storageValue),
              let value = try? JSONDecoder().decode(StoredSelection.self, from: data) else {
            self = .everyone
            return
        }
        switch value {
        case .everyone:
            self = .everyone
        case let .savedView(id):
            self = .savedView(id)
        case let .circle(circle):
            self = .circle(circle)
        case let .contextDigest(digest):
            self = availableContexts.first(where: {
                Self.contextDigest($0) == digest
            }).map(Self.context) ?? .everyone
        }
    }

    public var storageValue: String {
        let stored: StoredSelection = switch self {
        case .everyone: .everyone
        case let .savedView(id): .savedView(id)
        case let .circle(circle): .circle(circle)
        case let .context(context): .contextDigest(Self.contextDigest(context))
        }
        return (try? JSONEncoder().encode(stored).base64EncodedString()) ?? ""
    }

    private static func contextDigest(_ context: String) -> String {
        SHA256.hash(data: Data(context.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum NudgeNotificationStorage {
    public static func suggestionHistoryKey(scopeIdentifier: String) -> String {
        "nudgeSuggestionHistory.v2.\(encodedScope(scopeIdentifier))"
    }

    public static func poolSelectionKey(scopeIdentifier: String) -> String {
        "nudgePoolSelection.v1.\(encodedScope(scopeIdentifier))"
    }

    public static func planningStateKey(scopeIdentifier: String) -> String {
        "nudgeNotificationPlanningState.v1.\(encodedScope(scopeIdentifier))"
    }

    private static func encodedScope(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct PlannedProactiveNudge: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var fireDate: Date

    public init(id: UUID = UUID(), fireDate: Date) {
        self.id = id
        self.fireDate = fireDate
    }
}

public struct ProactiveNudgeNotificationPlanningState: Codable, Hashable, Sendable {
    public var items: [PlannedProactiveNudge]
    public var anchorDate: Date?
    public var timeZoneIdentifier: String?
    public var policySignature: String?

    public init(
        items: [PlannedProactiveNudge] = [],
        anchorDate: Date? = nil,
        timeZoneIdentifier: String? = nil,
        policySignature: String? = nil
    ) {
        self.items = items
        self.anchorDate = anchorDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.policySignature = policySignature
    }

    public func scheduledReminders(after date: Date = .now) -> [ScheduledConnectionReminder] {
        items.compactMap { item in
            guard item.fireDate > date else { return nil }
            return ScheduledConnectionReminder(
                id: item.id,
                fireDate: item.fireDate,
                personID: nil,
                personName: nil,
                context: nil,
                allowsPersonName: false,
                allowsContext: false,
                recurrence: .none,
                kind: .proactiveNudge
            )
        }
    }
}

/// Builds a short, one-shot proactive schedule locally. Slots never contain a
/// person identifier: the app selects from current data only after an unlocked
/// tap. Past planned slots conservatively count against the rolling budget even
/// if the OS suppressed delivery, preventing relaunches from over-notifying.
public struct ProactiveNudgeNotificationPlanner: Sendable {
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.calendar = calendar
        self.now = now
    }

    public func plan(
        policy: NudgePolicy,
        scopeIdentifier: String,
        suggestionHistory: NudgeSuggestionHistory = .init(),
        existingState: ProactiveNudgeNotificationPlanningState = .init()
    ) -> ProactiveNudgeNotificationPlanningState {
        let referenceDate = now()
        let weeklyLimit = policy.proactiveSuggestionsPerWeek
        let retentionDays = max(7, policy.cooldownDays)
        let retentionStart = calendar.date(
            byAdding: .day,
            value: -retentionDays,
            to: referenceDate
        ) ?? referenceDate.addingTimeInterval(Double(-retentionDays) * 86_400)

        let retainedPast = existingState.items
            .filter { $0.fireDate <= referenceDate && $0.fireDate >= retentionStart }
            .sorted { $0.fireDate < $1.fireDate }
        let signature = "\(weeklyLimit)|\(policy.quietStartHour)|\(policy.quietEndHour)"
        guard weeklyLimit > 0 else {
            return .init(
                items: retainedPast,
                anchorDate: existingState.anchorDate,
                timeZoneIdentifier: calendar.timeZone.identifier,
                policySignature: signature
            )
        }

        var budgetDates = suggestionHistory.proactiveShownDates
            .filter { $0 >= retentionStart && $0 <= referenceDate }
            + retainedPast.map(\.fireDate)
        let timeZoneMatches = existingState.timeZoneIdentifier == calendar.timeZone.identifier
        let policyMatches = existingState.policySignature == signature
        let anchor = if timeZoneMatches, policyMatches, let existingAnchor = existingState.anchorDate {
            existingAnchor
        } else {
            preferredFirstSlot(after: referenceDate, policy: policy)
        }
        let horizonEnd = calendar.date(byAdding: .day, value: 7, to: referenceDate)
            ?? referenceDate.addingTimeInterval(7 * 86_400)
        var planned = retainedPast

        if timeZoneMatches, policyMatches {
            for item in existingState.items
            .filter({ $0.fireDate > referenceDate && $0.fireDate < horizonEnd })
            .sorted(by: { $0.fireDate < $1.fireDate }) {
                guard policy.allowsProactiveSuggestion(
                    at: item.fireDate,
                    shownDates: budgetDates,
                    calendar: calendar
                  ) else { continue }
                planned.append(item)
                budgetDates.append(item.fireDate)
            }
        }

        let spacing = (7 * 86_400) / Double(weeklyLimit)
        let elapsed = max(0, referenceDate.timeIntervalSince(anchor))
        let firstIndex = anchor > referenceDate ? 0 : Int(floor(elapsed / spacing)) + 1
        let maximumSlotAttempts = max(weeklyLimit * 2, weeklyLimit + 2)
        for offset in 0..<maximumSlotAttempts {
            let rawDate = anchor.addingTimeInterval(Double(firstIndex + offset) * spacing)
            guard rawDate < horizonEnd else { break }
            let fireDate = connectionReminderDateOutsideQuietHours(
                rawDate,
                startHour: policy.quietStartHour,
                endHour: policy.quietEndHour,
                calendar: calendar
            )
            guard fireDate > referenceDate,
                  fireDate < horizonEnd,
                  !planned.contains(where: { abs($0.fireDate.timeIntervalSince(fireDate)) < 60 }),
                  policy.allowsProactiveSuggestion(
                    at: fireDate,
                    shownDates: budgetDates,
                    calendar: calendar
                  ) else { continue }
            let item = PlannedProactiveNudge(
                id: stableSlotID(scopeIdentifier: scopeIdentifier, fireDate: fireDate),
                fireDate: fireDate
            )
            planned.append(item)
            budgetDates.append(fireDate)
        }

        return .init(
            items: planned.sorted { $0.fireDate < $1.fireDate },
            anchorDate: anchor,
            timeZoneIdentifier: calendar.timeZone.identifier,
            policySignature: signature
        )
    }

    private func preferredFirstSlot(after date: Date, policy: NudgePolicy) -> Date {
        let preferredHour = policy.quietStartHour == policy.quietEndHour
            ? 9
            : (policy.quietEndHour + 1) % 24
        var components = DateComponents()
        components.hour = preferredHour
        components.minute = 0
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) ?? date.addingTimeInterval(3_600)
    }

    private func stableSlotID(scopeIdentifier: String, fireDate: Date) -> UUID {
        let epochMinute = Int64(floor(fireDate.timeIntervalSince1970 / 60))
        let digest = SHA256.hash(data: Data(
            "nudge-slot:v1|\(scopeIdentifier)|\(epochMinute)".utf8
        ))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private func connectionReminderDateOutsideQuietHours(
    _ date: Date,
    startHour: Int,
    endHour: Int,
    calendar: Calendar
) -> Date {
    guard startHour != endHour else { return date }
    let hour = calendar.component(.hour, from: date)
    let isQuiet = startHour < endHour
        ? (hour >= startHour && hour < endHour)
        : (hour >= startHour || hour < endHour)
    guard isQuiet else { return date }
    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = endHour
    components.minute = 0
    let sameDayEnd = calendar.date(from: components) ?? date
    if startHour > endHour, hour >= startHour {
        return calendar.date(byAdding: .day, value: 1, to: sameDayEnd) ?? sameDayEnd
    }
    return sameDayEnd
}

public protocol ConnectionNotificationScheduling: Sendable {
    func requestAuthorization() async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    @discardableResult
    func reconcile(
        _ reminders: [ScheduledConnectionReminder],
        privacy: NotificationPrivacy
    ) async throws -> ConnectionNotificationReconciliationReport
    func cancelAll() async
}

public actor ConnectionNotificationScheduler: ConnectionNotificationScheduling {
    public static let shared = ConnectionNotificationScheduler()

    private let center: UNUserNotificationCenter
    private let identifierPrefix = "relationship-notebook.connection."
    /// Leaves headroom below UserNotifications' per-app pending-request limit
    /// while also preserving requests owned by other app features.
    private let maximumOwnedPendingRequests = 60
    private let systemPendingRequestLimit = 64
    private var activeScopeIdentifier: String?
    private var reconciliationTail: Task<Void, Never>?

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    public func reconcile(
        _ reminders: [ScheduledConnectionReminder],
        privacy: NotificationPrivacy
    ) async throws -> ConnectionNotificationReconciliationReport {
        try await enqueueReconciliation(reminders, privacy: privacy, scopeIdentifier: nil)
    }

    /// Activates one account/local-vault scope and removes reminders belonging
    /// to the previously visible notebook before any new account is exposed.
    public func activateScope(_ scopeIdentifier: String) async {
        activeScopeIdentifier = scopeIdentifier
        await cancelAll()
    }

    /// Invalidates in-flight scheduling work during an Apple Account or vault
    /// transition. Scoped reconcile calls recheck this value after every await.
    public func deactivateScope() async {
        activeScopeIdentifier = nil
        await cancelAll()
    }

    @discardableResult
    public func reconcile(
        _ reminders: [ScheduledConnectionReminder],
        privacy: NotificationPrivacy,
        scopeIdentifier: String
    ) async throws -> ConnectionNotificationReconciliationReport {
        try await enqueueReconciliation(
            reminders,
            privacy: privacy,
            scopeIdentifier: scopeIdentifier
        )
    }

    private func enqueueReconciliation(
        _ reminders: [ScheduledConnectionReminder],
        privacy: NotificationPrivacy,
        scopeIdentifier: String?
    ) async throws -> ConnectionNotificationReconciliationReport {
        let predecessor = reconciliationTail
        let operation = Task<Result<ConnectionNotificationReconciliationReport, any Error>, Never> { [weak self] in
            await predecessor?.value
            guard let self else { return .success(.empty) }
            do {
                let report = if let scopeIdentifier {
                    try await self.replaceScopedRequests(
                        with: reminders,
                        privacy: privacy,
                        scopeIdentifier: scopeIdentifier
                    )
                } else {
                    try await self.replaceRequests(with: reminders, privacy: privacy)
                }
                return .success(report)
            } catch {
                return .failure(error)
            }
        }
        reconciliationTail = Task { _ = await operation.value }
        return try await operation.value.get()
    }

    private func replaceScopedRequests(
        with reminders: [ScheduledConnectionReminder],
        privacy: NotificationPrivacy,
        scopeIdentifier: String
    ) async throws -> ConnectionNotificationReconciliationReport {
        guard activeScopeIdentifier == scopeIdentifier else { return .empty }
        let pending = await center.pendingNotificationRequests()
        guard activeScopeIdentifier == scopeIdentifier else { return .empty }
        let previous = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        let foreignCount = pending.count - previous.count
        let requestBudget = min(
            maximumOwnedPendingRequests,
            max(0, systemPendingRequestLimit - foreignCount)
        )

        let plan = ConnectionNotificationRequestPlanner.plan(
            reminders,
            requestBudget: requestBudget
        )
        let scheduledIdentifiers = Set(plan.allocations.flatMap { allocation in
            allocation.patterns.map { pattern in
                identifierPrefix + allocation.reminder.id.uuidString + pattern.identifierSuffix
            }
        })
        // Cancel obsolete/deleted/capacity-deferred requests before adding.
        // This both frees system capacity and guarantees a later add failure
        // cannot leave an invalid person's old notification pending.
        center.removePendingNotificationRequests(withIdentifiers: previous.filter {
            !scheduledIdentifiers.contains($0)
        })
        for allocation in plan.allocations {
            guard activeScopeIdentifier == scopeIdentifier else { return .empty }
            let content = notificationContent(for: allocation.reminder, privacy: privacy)
            for pattern in allocation.patterns {
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: pattern.components,
                    repeats: pattern.repeats
                )
                let identifier = identifierPrefix
                    + allocation.reminder.id.uuidString
                    + pattern.identifierSuffix
                try await center.add(UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: trigger
                ))
                guard activeScopeIdentifier == scopeIdentifier else {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    return .empty
                }
            }
        }
        guard activeScopeIdentifier == scopeIdentifier else { return .empty }
        return plan.report
    }

    private func replaceRequests(
        with reminders: [ScheduledConnectionReminder],
        privacy: NotificationPrivacy
    ) async throws -> ConnectionNotificationReconciliationReport {
        let pending = await center.pendingNotificationRequests()
        let previous = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        let foreignCount = pending.count - previous.count
        let requestBudget = min(
            maximumOwnedPendingRequests,
            max(0, systemPendingRequestLimit - foreignCount)
        )

        let plan = ConnectionNotificationRequestPlanner.plan(
            reminders,
            requestBudget: requestBudget
        )
        let scheduledIdentifiers = Set(plan.allocations.flatMap { allocation in
            allocation.patterns.map { pattern in
                identifierPrefix + allocation.reminder.id.uuidString + pattern.identifierSuffix
            }
        })
        center.removePendingNotificationRequests(withIdentifiers: previous.filter {
            !scheduledIdentifiers.contains($0)
        })
        for allocation in plan.allocations {
            let content = notificationContent(for: allocation.reminder, privacy: privacy)
            for pattern in allocation.patterns {
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: pattern.components,
                    repeats: pattern.repeats
                )
                let identifier = identifierPrefix
                    + allocation.reminder.id.uuidString
                    + pattern.identifierSuffix
                try await center.add(UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: trigger
                ))
            }
        }
        return plan.report
    }

    private func notificationContent(
        for reminder: ScheduledConnectionReminder,
        privacy: NotificationPrivacy
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Connection reminder")
        if privacy.showPersonNames, reminder.allowsPersonName, let name = reminder.personName {
            if privacy.showContext, reminder.allowsContext, let context = reminder.context {
                content.body = String(localized: "A gentle reminder about \(name) · \(context)")
            } else {
                content.body = String(localized: "A gentle reminder about \(name)")
            }
        } else {
            content.body = String(localized: "You have a connection suggestion")
        }
        content.sound = .default
        content.categoryIdentifier = ConnectionNotificationMetadata.categoryIdentifier
        content.threadIdentifier = ConnectionNotificationMetadata.categoryIdentifier
        switch reminder.kind {
        case .proactiveNudge:
            content.userInfo = ConnectionNotificationMetadata.userInfo(for: .today)
        case .explicitReminder:
            content.userInfo = reminder.personID.map {
                ConnectionNotificationMetadata.userInfo(for: .person($0))
            } ?? [:]
        }
        return content
    }

    public func cancelAll() async {
        let predecessor = reconciliationTail
        let operation = Task { [weak self] in
            await predecessor?.value
            await self?.removeAllOwnedRequests()
        }
        reconciliationTail = operation
        await operation.value
    }

    private func removeAllOwnedRequests() async {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        )
        center.removeDeliveredNotifications(
            withIdentifiers: delivered
                .map(\.request.identifier)
                .filter { $0.hasPrefix(identifierPrefix) }
        )
    }
}

public struct NotificationRecurrencePattern: Equatable, Sendable {
    public var identifierSuffix: String
    public var components: DateComponents
    public var repeats: Bool

    public init(identifierSuffix: String, components: DateComponents, repeats: Bool) {
        self.identifierSuffix = identifierSuffix
        self.components = components
        self.repeats = repeats
    }
}

/// Produces the calendar triggers supported natively by UserNotifications. The reminder editor
/// creates interval-one rules. Imported interval rules greater than one retain their canonical
/// meaning and receive the next single notification until the app reconciles them again.
public enum NotificationRecurrencePlanner {
    public static func patterns(
        fireDate: Date,
        recurrence: RecurrenceRule,
        calendar: Calendar = .current
    ) -> [NotificationRecurrencePattern] {
        let clock = calendar.dateComponents([.hour, .minute], from: fireDate)
        switch recurrence {
        case .none:
            return [.init(
                identifierSuffix: "",
                components: calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: fireDate
                ),
                repeats: false
            )]
        case .daily(let interval) where interval == 1:
            return [.init(identifierSuffix: ".daily", components: clock, repeats: true)]
        case .weekly(let interval, let weekdays) where interval == 1:
            return weekdays.sorted { $0.rawValue < $1.rawValue }.map { weekday in
                var components = clock
                components.weekday = weekday.rawValue
                return .init(
                    identifierSuffix: ".weekday-\(weekday.rawValue)",
                    components: components,
                    repeats: true
                )
            }
        case .monthly(let interval) where interval == 1:
            var components = clock
            components.day = calendar.component(.day, from: fireDate)
            return [.init(identifierSuffix: ".monthly", components: components, repeats: true)]
        case .yearly(let interval) where interval == 1:
            var components = clock
            components.month = calendar.component(.month, from: fireDate)
            components.day = calendar.component(.day, from: fireDate)
            return [.init(identifierSuffix: ".yearly", components: components, repeats: true)]
        default:
            return [.init(
                identifierSuffix: ".next",
                components: calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: fireDate
                ),
                repeats: false
            )]
        }
    }
}
