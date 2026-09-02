import SwiftUI

struct RemindersView: View {
    @EnvironmentObject private var appSession: AppSessionController
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @AppStorage("remindersEnabled") private var remindersEnabled = false
    @State private var showingEditor = false
    @State private var showingCommitmentEditor = false
    @State private var selectedReminder: Reminder?
    @State private var selectedCommitment: Commitment?
    @State private var persistenceError: String?

    var body: some View {
        Group {
            if canonical.reminders.isEmpty && canonical.commitments.isEmpty {
                EmptyNotebookView(
                    icon: "checklist",
                    title: "No reminders or commitments",
                    message: "Keep next steps private, optional, and easy to dismiss.",
                    actionTitle: "Add reminder"
                ) { showingEditor = true }
            } else {
                List {
                    if !canonical.reminders.isEmpty {
                        Section {
                            ForEach(canonical.reminders.sorted(by: reminderSort)) { reminder in
                                let delivery = reminderDeliveryPresentation(reminder)
                                Button { selectedReminder = reminder } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: delivery.icon)
                                            .foregroundStyle(delivery.color)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(reminder.title).font(.headline)
                                            Text(reminderSubtitle(reminder)).font(.caption).foregroundStyle(AppTheme.secondaryText)
                                            if reminder.recurrence != .none {
                                                Text(recurrenceTitle(reminder.recurrence))
                                                    .font(.caption2)
                                                    .foregroundStyle(AppTheme.accent)
                                            }
                                            Text(delivery.title)
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(delivery.color)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundStyle(AppTheme.tertiaryText)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Complete") { update(reminder, event: .completed) }
                                    Button("Delete", role: .destructive) {
                                        delete(reminder)
                                    }
                                }
                            }
                        } header: {
                            Text("Reminders")
                        } footer: {
                            if capacityLimitedReminderCount > 0 {
                                Text(capacityGuidance)
                            }
                        }
                    }
                    if !canonical.commitments.isEmpty {
                        Section("Commitments") {
                            ForEach(canonical.commitments) { commitment in
                                Button { selectedCommitment = commitment } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(commitment.summary).font(.headline)
                                            let names = commitment.personIDs.compactMap { store.person(id: $0)?.displayName }
                                            if !names.isEmpty { Text(names.joined(separator: ", ")).font(.caption).foregroundStyle(AppTheme.secondaryText) }
                                            Text(commitmentStateTitle(commitment.lifecycleState))
                                                .font(.caption2).foregroundStyle(AppTheme.secondaryText)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundStyle(AppTheme.tertiaryText)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Reminders & Commitments")
        .toolbar {
            Menu {
                Button { showingEditor = true } label: { Label("Reminder", systemImage: "bell.badge") }
                Button { showingCommitmentEditor = true } label: { Label("Commitment", systemImage: "checklist") }
            } label: { Label("Add", systemImage: "plus") }
        }
        .sheet(isPresented: $showingEditor) { ReminderEditorView() }
        .sheet(isPresented: $showingCommitmentEditor) { CommitmentEditorView() }
        .sheet(item: $selectedReminder) { reminder in
            ReminderManagementView(reminder: reminder)
        }
        .sheet(item: $selectedCommitment) { commitment in
            CommitmentManagementView(commitment: commitment)
        }
        .alert("Planning change could not be saved", isPresented: Binding(
            get: { persistenceError != nil },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK") { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "")
        }
    }

    private func reminderSort(_ left: Reminder, _ right: Reminder) -> Bool {
        reminderDate(left) < reminderDate(right)
    }

    private func reminderDate(_ reminder: Reminder) -> Date {
        switch reminder.effectiveDue {
        case let .instant(date, _): date
        case let .partialDate(date): date.earliestInstant
        }
    }

    private func reminderSubtitle(_ reminder: Reminder) -> String {
        let personName: String
        if case let .person(personID) = reminder.subject {
            personName = store.person(id: personID)?.displayName ?? String(localized: "Unknown person")
        } else {
            personName = String(localized: "Notebook reminder")
        }
        return String(localized: "\(personName) · \(reminderDate(reminder).formatted(date: .abbreviated, time: .shortened))")
    }

    private struct ReminderDeliveryPresentation {
        var icon: String
        var color: Color
        var title: String
    }

    private var capacityLimitedReminderCount: Int {
        guard case let .ready(report) = appSession.reminderNotificationState else { return 0 }
        return canonical.reminders.reduce(into: 0) { count, reminder in
            if report.outcomes[reminder.id] == .unscheduled(.capacity) { count += 1 }
        }
    }

    private var capacityGuidance: String {
        if capacityLimitedReminderCount == 1 {
            return String(localized: "One reminder is not scheduled because the device notification limit is full. Earlier explicit reminders are prioritized by due date.")
        }
        return String(localized: "\(capacityLimitedReminderCount) reminders are not scheduled because the device notification limit is full. Earlier explicit reminders are prioritized by due date.")
    }

    private func reminderDeliveryPresentation(
        _ reminder: Reminder
    ) -> ReminderDeliveryPresentation {
        switch reminder.lifecycleState {
        case .completed:
            return .init(icon: "checkmark.circle.fill", color: .green, title: String(localized: "Completed"))
        case .dismissed:
            return .init(icon: "xmark.circle", color: AppTheme.secondaryText, title: String(localized: "Dismissed"))
        case .snoozed:
            break
        case let .deliveryError(message):
            return .init(icon: "exclamationmark.triangle.fill", color: .red, title: message)
        case .active:
            break
        }
        guard reminder.isEnabled else {
            return .init(
                icon: "bell.slash",
                color: AppTheme.secondaryText,
                title: String(localized: "Off")
            )
        }
        guard case let .person(personID) = reminder.subject else {
            return .init(
                icon: "bell.badge.slash",
                color: .orange,
                title: String(localized: "Not scheduled · unsupported reminder subject")
            )
        }
        guard let person = store.person(id: personID), person.deletedAt == nil else {
            return .init(
                icon: "person.crop.circle.badge.xmark",
                color: .orange,
                title: String(localized: "Not scheduled · person is in Recently Deleted")
            )
        }
        if reminder.recurrence == .none, reminderDate(reminder) <= .now {
            return .init(
                icon: "exclamationmark.circle.fill",
                color: .orange,
                title: String(localized: "Overdue · not scheduled")
            )
        }
        guard remindersEnabled else {
            return .init(
                icon: "bell.slash",
                color: AppTheme.secondaryText,
                title: String(localized: "Not scheduled · notifications are off")
            )
        }

        switch appSession.reminderNotificationState {
        case .inactive, .reconciling:
            return .init(
                icon: "clock",
                color: AppTheme.secondaryText,
                title: String(localized: "Checking notification schedule…")
            )
        case .notificationsDisabled:
            return .init(
                icon: "bell.slash",
                color: AppTheme.secondaryText,
                title: String(localized: "Not scheduled · notifications are off")
            )
        case .permissionRequired:
            return .init(
                icon: "bell.badge.slash",
                color: .orange,
                title: String(localized: "Not scheduled · notification permission required")
            )
        case .failed:
            return .init(
                icon: "exclamationmark.triangle.fill",
                color: .red,
                title: String(localized: "Not scheduled · scheduling failed")
            )
        case .ready(let report):
            switch report.outcomes[reminder.id] {
            case .scheduled:
                return .init(
                    icon: "bell.fill",
                    color: AppTheme.accent,
                    title: String(localized: "Scheduled")
                )
            case .unscheduled(.pastDue):
                return .init(
                    icon: "exclamationmark.circle.fill",
                    color: .orange,
                    title: String(localized: "Overdue · not scheduled")
                )
            case .unscheduled(.capacity):
                return .init(
                    icon: "bell.badge.slash",
                    color: .orange,
                    title: String(localized: "Not scheduled · notification limit reached")
                )
            case .unscheduled(.invalidSchedule):
                return .init(
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    title: String(localized: "Not scheduled · recurrence needs attention")
                )
            case nil:
                return .init(
                    icon: "bell.badge.slash",
                    color: .orange,
                    title: String(localized: "Not scheduled")
                )
            }
        }
    }

    private func recurrenceTitle(_ recurrence: RecurrenceRule) -> String {
        switch recurrence {
        case .none: String(localized: "Does not repeat")
        case .daily(let interval): interval == 1
            ? String(localized: "Repeats daily")
            : String(localized: "Repeats every \(interval) days")
        case .weekly(let interval, _): interval == 1
            ? String(localized: "Repeats weekly")
            : String(localized: "Repeats every \(interval) weeks")
        case .monthly(let interval): interval == 1
            ? String(localized: "Repeats monthly")
            : String(localized: "Repeats every \(interval) months")
        case .yearly(let interval): interval == 1
            ? String(localized: "Repeats yearly")
            : String(localized: "Repeats every \(interval) years")
        }
    }

    private func reconcileNotifications() {
        guard remindersEnabled else {
            Task { await appSession.reconcileNotificationsForCurrentSession() }
            return
        }
        Task {
            await appSession.reconcileNotificationsForCurrentSession()
        }
    }

    private func update(_ reminder: Reminder, event: ReminderEventKind) {
        var copy = reminder
        copy.record(event)
        do {
            try canonical.saveReminder(copy)
            reconcileNotifications()
        } catch {
            persistenceError = canonical.lastError
                ?? String(localized: "The reminder could not be saved. Try again.")
        }
    }

    private func delete(_ reminder: Reminder) {
        do {
            try canonical.deleteReminder(reminder)
            reconcileNotifications()
        } catch {
            persistenceError = canonical.lastError
                ?? String(localized: "The reminder could not be moved to Recently Deleted.")
        }
    }

    private func commitmentStateTitle(_ state: CommitmentLifecycleState) -> String {
        switch state {
        case .active: String(localized: "Active")
        case .completed: String(localized: "Completed")
        case .retracted: String(localized: "Retracted")
        }
    }
}

struct ReminderEditorView: View {
    @EnvironmentObject private var appSession: AppSessionController
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("remindersEnabled") private var remindersEnabled = false
    private let original: Reminder?

    @State private var personID: UUID?
    @State private var title = ""
    @State private var due = Date.now.addingTimeInterval(86_400)
    @State private var recurrence = "none"
    @State private var notificationPrivacy = ReminderNotificationPrivacy.generic.rawValue
    @State private var isEnabled = true
    @State private var showingPersonEditor = false
    @State private var persistenceError: String?

    init(reminder: Reminder? = nil) {
        original = reminder
        if case let .person(id) = reminder?.subject { _personID = State(initialValue: id) }
        else { _personID = State(initialValue: nil) }
        _title = State(initialValue: reminder?.title ?? "")
        _due = State(initialValue: reminder.map(Self.date(for:)) ?? Date.now.addingTimeInterval(86_400))
        _recurrence = State(initialValue: Self.recurrenceKey(reminder?.recurrence ?? .none))
        _notificationPrivacy = State(initialValue: (reminder?.notificationPrivacy ?? .generic).rawValue)
        _isEnabled = State(initialValue: reminder?.isEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                if activePeople.isEmpty {
                    Section("Person required") {
                        Text("Add a person, then return here to finish this reminder.")
                            .foregroundStyle(AppTheme.secondaryText)
                        Button("Add Person") { showingPersonEditor = true }
                    }
                } else {
                    Picker("Person", selection: $personID) {
                        Text("Choose a person").tag(nil as UUID?)
                        ForEach(activePeople) { person in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.displayName)
                                Text(PersonChoiceDescription.detail(for: person))
                                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                            .tag(person.id as UUID?)
                        }
                    }
                }
                TextField("Reminder", text: $title)
                DatePicker("Due", selection: $due)
                Picker("Repeat", selection: $recurrence) {
                    Text("Never").tag("none")
                    Text("Daily").tag("daily")
                    Text("Weekly").tag("weekly")
                    Text("Monthly").tag("monthly")
                    Text("Yearly").tag("yearly")
                }
                if hasPastOneTimeDueDate {
                    Label(
                        "Choose a future due date for a reminder that does not repeat.",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Picker("Notification preview", selection: $notificationPrivacy) {
                    Text("Generic").tag(ReminderNotificationPrivacy.generic.rawValue)
                    Text("Include person name").tag(ReminderNotificationPrivacy.includePersonName.rawValue)
                }
                Text("Generic notification text is the default. A reminder never includes private notes or facts.")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                Toggle("Enabled", isOn: $isEnabled)
                if !isEnabled {
                    Text("This reminder remains in Planning but will not create a device notification or appear as an active Today action.")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(original == nil ? String(localized: "New Reminder") : String(localized: "Edit Reminder"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            personID == nil
                                || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || hasPastOneTimeDueDate
                        )
                }
            }
        }
        .keepsakeSheetSize(minWidth: 480, minHeight: 430)
        .onChange(of: store.people.map(\.id)) { _, _ in
            if personID == nil, activePeople.count == 1 { personID = activePeople.first?.id }
        }
        .sheet(isPresented: $showingPersonEditor) { PersonEditorView() }
        .alert("Reminder could not be saved", isPresented: Binding(
            get: { persistenceError != nil },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK") { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "")
        }
    }

    private func save() {
        guard let personID, !hasPastOneTimeDueDate else { return }
        let recurrenceRule: RecurrenceRule = switch recurrence {
        case "daily": .daily(interval: 1)
        case "weekly": .weekly(interval: 1, weekdays: [weekday(for: due)])
        case "monthly": .monthly(interval: 1)
        case "yearly": .yearly(interval: 1)
        default: .none
        }
        let privacy = ReminderNotificationPrivacy(rawValue: notificationPrivacy) ?? .generic
        let reminder = Reminder(
            id: original?.id ?? UUID(),
            subject: .person(personID),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            due: .instant(due, timeZoneIdentifier: TimeZone.current.identifier),
            recurrence: recurrenceRule,
            notificationPrivacy: privacy,
            isEnabled: isEnabled,
            interactionID: original?.interactionID,
            events: original?.events,
            createdAt: original?.createdAt ?? .now,
            modifiedAt: .now,
            schemaRevision: original?.schemaRevision ?? 1
        )
        do {
            try canonical.saveReminder(reminder)
        } catch {
            persistenceError = canonical.lastError
                ?? String(localized: "The reminder could not be saved. Your changes are still open.")
            return
        }

        guard remindersEnabled else {
            Task { await appSession.reconcileNotificationsForCurrentSession() }
            dismiss()
            return
        }

        Task {
            await appSession.reconcileNotificationsForCurrentSession()
        }
        dismiss()
    }

    private func weekday(for date: Date) -> Weekday {
        Weekday(rawValue: Calendar.current.component(.weekday, from: date)) ?? .monday
    }

    private var hasPastOneTimeDueDate: Bool {
        isEnabled && recurrence == "none" && due <= .now
    }

    private var activePeople: [Person] {
        store.people.filter { $0.deletedAt == nil && !$0.isArchived }
    }

    private static func date(for reminder: Reminder) -> Date {
        switch reminder.effectiveDue {
        case let .instant(date, _): date
        case let .partialDate(date): date.earliestInstant
        }
    }

    private static func recurrenceKey(_ recurrence: RecurrenceRule) -> String {
        switch recurrence {
        case .none: "none"
        case .daily: "daily"
        case .weekly: "weekly"
        case .monthly: "monthly"
        case .yearly: "yearly"
        }
    }
}

struct ReminderManagementView: View {
    @EnvironmentObject private var appSession: AppSessionController
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("remindersEnabled") private var remindersEnabled = false
    let reminder: Reminder
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var persistenceError: String?

    private var current: Reminder {
        canonical.reminders.first { $0.id == reminder.id } ?? reminder
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminder") {
                    Text(current.title).font(.headline)
                    if case let .person(personID) = current.subject,
                       let person = store.person(id: personID) {
                        LabeledContent("Person", value: person.displayName)
                    }
                    LabeledContent("Due", value: dueDate.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("State", value: stateTitle)
                    LabeledContent("Device notifications", value: current.isEnabled ? String(localized: "Enabled") : String(localized: "Off"))
                    if current.interactionID != nil {
                        Label("Linked to an interaction", systemImage: "link")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                }

                Section("Actions") {
                    switch current.lifecycleState {
                    case .completed, .dismissed:
                        Button("Reopen") { record(.reopened) }
                    case .active, .snoozed, .deliveryError:
                        Button("Complete") { record(.completed) }
                        Button("Snooze until tomorrow") {
                            snooze(days: 1)
                        }
                        Button("Snooze one week") {
                            snooze(days: 7)
                        }
                        Button("Dismiss") { record(.dismissed) }
                    }
                    Button(current.isEnabled ? "Turn Off Notifications" : "Enable Notifications") {
                        var copy = current
                        copy.isEnabled.toggle()
                        copy.modifiedAt = .now
                        persist(copy)
                    }
                    Button("Edit or Reschedule") { editing = true }
                }

                if let events = current.events, !events.isEmpty {
                    Section("History") {
                        ForEach(events.sorted { $0.occurredAt > $1.occurredAt }) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(eventTitle(event.kind))
                                Text(event.occurredAt, format: .dateTime.month().day().year().hour().minute())
                                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                    }
                }

                Section {
                    Button("Move Reminder to Recently Deleted", role: .destructive) {
                        confirmingDelete = true
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Manage Reminder")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .keepsakeSheetSize(minWidth: 500, minHeight: 600)
        .sheet(isPresented: $editing) { ReminderEditorView(reminder: current) }
        .confirmationDialog("Move reminder to Recently Deleted?", isPresented: $confirmingDelete) {
            Button("Move to Recently Deleted", role: .destructive) {
                deleteCurrent()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Reminder change could not be saved", isPresented: Binding(
            get: { persistenceError != nil },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK") { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "")
        }
    }

    private var dueDate: Date {
        switch current.effectiveDue {
        case let .instant(date, _): date
        case let .partialDate(date): date.earliestInstant
        }
    }

    private var stateTitle: String {
        switch current.lifecycleState {
        case .active: String(localized: "Active")
        case .snoozed: String(localized: "Snoozed")
        case .completed: String(localized: "Completed")
        case .dismissed: String(localized: "Dismissed")
        case let .deliveryError(message): String(localized: "Delivery error: \(message)")
        }
    }

    private func eventTitle(_ kind: ReminderEventKind) -> String {
        switch kind {
        case .completed: String(localized: "Completed")
        case .snoozed: String(localized: "Snoozed")
        case .reopened: String(localized: "Reopened")
        case .dismissed: String(localized: "Dismissed")
        case let .deliveryFailed(message): String(localized: "Delivery failed: \(message)")
        }
    }

    private func snooze(days: Int) {
        let date = Calendar.current.date(byAdding: .day, value: days, to: .now)
            ?? Date.now.addingTimeInterval(Double(days) * 86_400)
        record(.snoozed(until: .instant(date, timeZoneIdentifier: TimeZone.current.identifier)))
    }

    private func record(_ event: ReminderEventKind) {
        var copy = current
        copy.record(event)
        persist(copy)
    }

    private func persist(_ reminder: Reminder) {
        do {
            try canonical.saveReminder(reminder)
            reconcileNotifications()
        } catch {
            persistenceError = canonical.lastError
                ?? String(localized: "The reminder change could not be saved. Try again.")
        }
    }

    private func deleteCurrent() {
        do {
            try canonical.deleteReminder(current)
            reconcileNotifications()
            dismiss()
        } catch {
            persistenceError = canonical.lastError
                ?? String(localized: "The reminder could not be moved to Recently Deleted.")
        }
    }

    private func reconcileNotifications() {
        Task { await appSession.reconcileNotificationsForCurrentSession() }
    }
}

struct CommitmentManagementView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss
    let commitment: Commitment
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var persistenceError: String?

    private var current: Commitment {
        canonical.commitments.first { $0.id == commitment.id } ?? commitment
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Commitment") {
                    Text(current.summary).font(.headline)
                    let names = current.personIDs.compactMap { store.person(id: $0)?.displayName }
                    if !names.isEmpty { LabeledContent("People", value: names.joined(separator: ", ")) }
                    if let due = current.due { LabeledContent("Due", value: date(due).formatted(date: .abbreviated, time: .shortened)) }
                    LabeledContent("State", value: stateTitle(current.lifecycleState))
                    if current.interactionID != nil {
                        Label("Linked to an interaction", systemImage: "link")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                Section("Actions") {
                    if current.lifecycleState == .active {
                        Button("Complete") { record(.completed) }
                        Button("Retract") { record(.retracted) }
                    } else {
                        Button("Reopen") { record(.reopened) }
                    }
                    Button("Edit or Reschedule") { editing = true }
                }
                if let events = current.events, !events.isEmpty {
                    Section("History") {
                        ForEach(events.sorted { $0.occurredAt > $1.occurredAt }) { event in
                            LabeledContent(event.kind.rawValue.capitalized) {
                                Text(event.occurredAt, format: .dateTime.month().day().year().hour().minute())
                            }
                        }
                    }
                }
                Section {
                    Button("Move Commitment to Recently Deleted", role: .destructive) { confirmingDelete = true }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Manage Commitment")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .keepsakeSheetSize(minWidth: 500, minHeight: 560)
        .sheet(isPresented: $editing) { CommitmentEditorView(commitment: current) }
        .confirmationDialog("Move commitment to Recently Deleted?", isPresented: $confirmingDelete) {
            Button("Move to Recently Deleted", role: .destructive) {
                deleteCurrent()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Commitment change could not be saved", isPresented: Binding(
            get: { persistenceError != nil },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK") { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "")
        }
    }

    private func record(_ event: CommitmentEventKind) {
        var copy = current
        copy.record(event)
        do {
            try canonical.saveCommitment(copy)
        } catch {
            persistenceError = canonical.lastError
                ?? String(localized: "The commitment change could not be saved. Try again.")
        }
    }

    private func deleteCurrent() {
        do {
            try canonical.deleteCommitment(current)
            dismiss()
        } catch {
            persistenceError = canonical.lastError
                ?? String(localized: "The commitment could not be moved to Recently Deleted.")
        }
    }

    private func date(_ due: ReminderDue) -> Date {
        switch due {
        case let .instant(date, _): date
        case let .partialDate(date): date.earliestInstant
        }
    }

    private func stateTitle(_ state: CommitmentLifecycleState) -> String {
        switch state {
        case .active: String(localized: "Active")
        case .completed: String(localized: "Completed")
        case .retracted: String(localized: "Retracted")
        }
    }
}

struct CommitmentEditorView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss
    private let original: Commitment?
    @State private var summary: String
    @State private var personIDs: Set<UUID>
    @State private var ownerKind: String
    @State private var ownerPersonID: UUID?
    @State private var hasDue: Bool
    @State private var due: Date
    @State private var showingPersonEditor = false
    @State private var persistenceError: String?

    init(commitment: Commitment? = nil) {
        original = commitment
        _summary = State(initialValue: commitment?.summary ?? "")
        _personIDs = State(initialValue: Set(commitment?.personIDs ?? []))
        switch commitment?.owner {
        case .notebookOwner: _ownerKind = State(initialValue: "owner"); _ownerPersonID = State(initialValue: nil)
        case let .person(id): _ownerKind = State(initialValue: "person"); _ownerPersonID = State(initialValue: id)
        case .shared: _ownerKind = State(initialValue: "shared"); _ownerPersonID = State(initialValue: nil)
        default: _ownerKind = State(initialValue: "unspecified"); _ownerPersonID = State(initialValue: nil)
        }
        _hasDue = State(initialValue: commitment?.due != nil)
        _due = State(initialValue: commitment?.due.map(Self.date) ?? Date.now.addingTimeInterval(7 * 86_400))
    }

    private var activePeople: [Person] {
        store.people.filter { $0.deletedAt == nil && !$0.isArchived }
    }

    var body: some View {
        NavigationStack {
            Form {
                if activePeople.isEmpty {
                    Section("Person required") {
                        Text("Add a person, then return here to finish the commitment.")
                            .foregroundStyle(AppTheme.secondaryText)
                        Button("Add Person") { showingPersonEditor = true }
                    }
                } else {
                    Section("People") {
                        ForEach(activePeople) { person in
                            Toggle(isOn: Binding(
                                get: { personIDs.contains(person.id) },
                                set: { selected in
                                    if selected { personIDs.insert(person.id) }
                                    else { personIDs.remove(person.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.displayName)
                                    Text(PersonChoiceDescription.detail(for: person))
                                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                                }
                            }
                        }
                    }
                }
                Section("Commitment") {
                    TextField("What is the next step?", text: $summary, axis: .vertical)
                        .lineLimit(2...5)
                    Picker("Owner", selection: $ownerKind) {
                        Text("Notebook owner").tag("owner")
                        Text("One person").tag("person")
                        Text("Shared").tag("shared")
                        Text("Unspecified").tag("unspecified")
                    }
                    if ownerKind == "person" {
                        Picker("Responsible person", selection: $ownerPersonID) {
                            Text("Choose a person").tag(nil as UUID?)
                            ForEach(activePeople) { person in
                                Text(person.displayName).tag(person.id as UUID?)
                            }
                        }
                    }
                    Toggle("Has due date", isOn: $hasDue)
                    if hasDue { DatePicker("Due", selection: $due) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(original == nil ? String(localized: "New Commitment") : String(localized: "Edit Commitment"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || personIDs.isEmpty
                                || (ownerKind == "person" && ownerPersonID == nil)
                        )
                }
            }
        }
        .keepsakeSheetSize(minWidth: 500, minHeight: 580)
        .sheet(isPresented: $showingPersonEditor) { PersonEditorView() }
        .alert("Commitment could not be saved", isPresented: Binding(
            get: { persistenceError != nil },
            set: { if !$0 { persistenceError = nil } }
        )) {
            Button("OK") { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "")
        }
    }

    private func save() {
        let owner: CommitmentOwner = switch ownerKind {
        case "owner": .notebookOwner
        case "person": ownerPersonID.map(CommitmentOwner.person) ?? .unspecified
        case "shared": .shared(Array(personIDs))
        default: .unspecified
        }
        let commitment = Commitment(
            id: original?.id ?? UUID(),
            interactionID: original?.interactionID,
            personIDs: Array(personIDs),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            owner: owner,
            due: hasDue ? .instant(due, timeZoneIdentifier: TimeZone.current.identifier) : nil,
            sourceAssertionID: original?.sourceAssertionID,
            events: original?.events,
            createdAt: original?.createdAt ?? .now,
            modifiedAt: .now,
            schemaRevision: original?.schemaRevision ?? 1
        )
        do {
            try canonical.saveCommitment(commitment)
            dismiss()
        } catch {
            persistenceError = canonical.lastError
                ?? String(localized: "The commitment could not be saved. Your changes are still open.")
        }
    }

    private static func date(_ due: ReminderDue) -> Date {
        switch due {
        case let .instant(date, _): date
        case let .partialDate(date): date.earliestInstant
        }
    }
}

struct CustomFieldsView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @State private var editingDefinition: AttributeDefinition?
    @State private var creatingDefinition = false
    @State private var includeArchived = false
    @State private var errorMessage: String?

    private var visibleDefinitions: [AttributeDefinition] {
        canonical.attributeDefinitions.filter { includeArchived || $0.archivedAt == nil }
    }

    var body: some View {
        Group {
            if visibleDefinitions.isEmpty && !includeArchived {
                EmptyNotebookView(
                    icon: "slider.horizontal.3",
                    title: "No custom fields",
                    message: "Add a typed field and decide separately where it may be used.",
                    actionTitle: "Add custom field"
                ) { creatingDefinition = true }
            } else {
                List {
                    Section {
                        Toggle("Show archived fields", isOn: $includeArchived)
                    }
                    Section("Definitions") {
                        ForEach(visibleDefinitions) { definition in
                            Button { editingDefinition = definition } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(definition.labels.fallback).font(.headline)
                                        if definition.archivedAt != nil {
                                            Label("Archived", systemImage: "archivebox")
                                                .font(.caption)
                                        }
                                        Spacer()
                                        Text(definition.valueKind.customFieldTitle)
                                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                                    }
                                    Text(definition.predicateID)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(AppTheme.tertiaryText)
                                        .textSelection(.enabled)
                                    HStack {
                                        Text(definition.cardinality == .multiple ? "Multiple values" : "One value")
                                        if let options = definition.options, !options.isEmpty {
                                            Text("· \(options.filter { $0.archivedAt == nil }.count) choices")
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    FlowLayout(spacing: 6) {
                                        if definition.capabilities.supportsSearch { ContextChip(text: String(localized: "Search")) }
                                        if definition.capabilities.supportsFilter { ContextChip(text: String(localized: "Filter")) }
                                        if definition.capabilities.supportsSort { ContextChip(text: String(localized: "Sort")) }
                                        if definition.capabilities.supportsAI { ContextChip(text: String(localized: "AI")) }
                                        if definition.capabilities.supportsConversationMentions { ContextChip(text: String(localized: "Conversation")) }
                                    }
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit") { editingDefinition = definition }
                                Button("Duplicate") { duplicate(definition) }
                                Button(definition.archivedAt == nil ? "Archive" : "Restore") {
                                    toggleArchive(definition)
                                }
                                Button("Move Up") { move(definition, offset: -1) }
                                    .disabled(definition.archivedAt != nil)
                                Button("Move Down") { move(definition, offset: 1) }
                                    .disabled(definition.archivedAt != nil)
                                Divider()
                                Button("Move to Recently Deleted", role: .destructive) {
                                    canonical.delete(definition, kind: "attributeDefinition")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Custom Fields")
        .toolbar { Button { creatingDefinition = true } label: { Label("Add Custom Field", systemImage: "plus") } }
        .sheet(isPresented: $creatingDefinition) { CustomFieldEditorView() }
        .sheet(item: $editingDefinition) { CustomFieldEditorView(definition: $0) }
        .alert("Custom field needs attention", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func toggleArchive(_ original: AttributeDefinition) {
        var definition = original
        definition.archivedAt = original.archivedAt == nil ? .now : nil
        definition.modifiedAt = .now
        do { try canonical.saveAttributeDefinition(definition) }
        catch { errorMessage = error.localizedDescription }
    }

    private func duplicate(_ original: AttributeDefinition) {
        let id = UUID()
        let options = (original.options ?? []).enumerated().map { index, option in
            AttributeOption(
                definitionID: id,
                label: option.label,
                order: index,
                archivedAt: option.archivedAt
            )
        }
        let copy = AttributeDefinition(
            id: id,
            predicateID: "custom.\(UUID().uuidString.lowercased())",
            labels: .init(String(localized: "\(original.labels.fallback) Copy")),
            valueKind: original.valueKind,
            cardinality: original.cardinality,
            validation: original.validation,
            defaultSensitivity: original.defaultSensitivity,
            defaultUsePolicy: original.defaultUsePolicy,
            capabilities: original.capabilities,
            options: options,
            displayOrder: canonical.activeAttributeDefinitions.count
        )
        do { try canonical.saveAttributeDefinition(copy) }
        catch { errorMessage = error.localizedDescription }
    }

    private func move(_ definition: AttributeDefinition, offset: Int) {
        var active = canonical.activeAttributeDefinitions
        guard let index = active.firstIndex(where: { $0.id == definition.id }) else { return }
        let destination = index + offset
        guard active.indices.contains(destination) else { return }
        active.swapAt(index, destination)
        do { try canonical.reorderAttributeDefinitions(active.map(\.id)) }
        catch { errorMessage = error.localizedDescription }
    }
}

private extension AttributeValueKind {
    var customFieldTitle: String {
        switch self {
        case .text: String(localized: "Text")
        case .richText: String(localized: "Long text")
        case .boolean: String(localized: "Yes / No")
        case .number: String(localized: "Number")
        case .partialDate: String(localized: "Partial date")
        case .dateRange: String(localized: "Date range")
        case .singleSelect: String(localized: "Single selection")
        case .multiSelect: String(localized: "Multiple selections")
        case .language: String(localized: "Language")
        case .url: String(localized: "Web address")
        case .email: String(localized: "Email")
        case .phone: String(localized: "Phone")
        case .location: String(localized: "Location")
        case .address: String(localized: "Address")
        case .personReference: String(localized: "Person reference")
        case .contextReference: String(localized: "Context reference")
        case .mediaReference: String(localized: "Media reference")
        case .structuredJSON: String(localized: "Structured data")
        }
    }
}

struct CustomFieldEditorView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss

    private let original: AttributeDefinition?
    @State private var name: String
    @State private var kind: String
    @State private var cardinality: AttributeCardinality
    @State private var sensitivity: String
    @State private var searchable: Bool
    @State private var filterable: Bool
    @State private var sortable: Bool
    @State private var AI: Bool
    @State private var conversation: Bool
    @State private var optionsText: String
    @State private var minimumTextLength: String
    @State private var maximumTextLength: String
    @State private var minimumNumber: String
    @State private var maximumNumber: String
    @State private var regularExpression: String
    @State private var errorMessage: String?

    init(definition: AttributeDefinition? = nil) {
        original = definition
        _name = State(initialValue: definition?.labels.fallback ?? "")
        _kind = State(initialValue: definition?.valueKind.rawValue ?? AttributeValueKind.text.rawValue)
        _cardinality = State(initialValue: definition?.cardinality ?? .single)
        _sensitivity = State(initialValue: definition?.defaultSensitivity.rawValue ?? Sensitivity.private.rawValue)
        _searchable = State(initialValue: definition?.capabilities.supportsSearch ?? false)
        _filterable = State(initialValue: definition?.capabilities.supportsFilter ?? false)
        _sortable = State(initialValue: definition?.capabilities.supportsSort ?? false)
        _AI = State(initialValue: definition?.capabilities.supportsAI ?? false)
        _conversation = State(initialValue: definition?.capabilities.supportsConversationMentions ?? false)
        _optionsText = State(initialValue: (definition?.options ?? [])
            .filter { $0.archivedAt == nil }
            .sorted { $0.order < $1.order }
            .map(\.label.fallback).joined(separator: ", "))
        _minimumTextLength = State(initialValue: definition?.validation.minimumTextLength.map(String.init) ?? "")
        _maximumTextLength = State(initialValue: definition?.validation.maximumTextLength.map(String.init) ?? "")
        _minimumNumber = State(initialValue: definition?.validation.minimumNumber.map { String(describing: $0) } ?? "")
        _maximumNumber = State(initialValue: definition?.validation.maximumNumber.map { String(describing: $0) } ?? "")
        _regularExpression = State(initialValue: definition?.validation.regularExpression ?? "")
    }

    private var credentialWarning: String? { SensitiveFieldPolicy.credentialWarning(for: name) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Field") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(AttributeValueKind.allCases, id: \.rawValue) {
                            Text($0.customFieldTitle).tag($0.rawValue)
                        }
                    }
                    .disabled(original != nil)
                    Picker("Cardinality", selection: $cardinality) {
                        Text("One value").tag(AttributeCardinality.single)
                        Text("Multiple values").tag(AttributeCardinality.multiple)
                    }
                    .disabled(original != nil || selectedKind == .multiSelect)
                    Picker("Default sensitivity", selection: $sensitivity) {
                        Text("Ordinary").tag(Sensitivity.ordinary.rawValue)
                        Text("Private").tag(Sensitivity.private.rawValue)
                        Text("Sensitive").tag(Sensitivity.sensitive.rawValue)
                        Text("Highly sensitive").tag(Sensitivity.highlySensitive.rawValue)
                    }
                }
                if selectedKind == .singleSelect || selectedKind == .multiSelect {
                    Section("Choices") {
                        TextField("Choices, separated by commas", text: $optionsText, axis: .vertical)
                        Text("Choices receive immutable identifiers, so renaming the field does not break existing facts or saved filters.")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                if selectedKind == .text || selectedKind == .richText {
                    Section("Text validation") {
                        TextField("Minimum characters", text: $minimumTextLength)
                        TextField("Maximum characters", text: $maximumTextLength)
                        TextField("Regular expression (optional)", text: $regularExpression)
                    }
                } else if selectedKind == .number {
                    Section("Number validation") {
                        TextField("Minimum", text: $minimumNumber)
                        TextField("Maximum", text: $maximumNumber)
                    }
                }
                if let credentialWarning {
                    Section {
                        Label(credentialWarning, systemImage: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(.red)
                    }
                }
                Section("Allowed uses — off by default") {
                    Toggle("Search", isOn: $searchable)
                    Toggle("Filters", isOn: $filterable)
                    Toggle("Sorting", isOn: $sortable)
                    Toggle("AI processing", isOn: $AI)
                    Toggle("Conversation prompts", isOn: $conversation)
                    Text("Only capabilities with complete product surfaces are offered. Search, filtering, and sorting are independent; reminder and profile-card permissions remain unavailable until those workflows consume custom fields end to end.")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(original == nil ? "New Custom Field" : "Edit Custom Field")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(original == nil ? "Create" : "Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .keepsakeSheetSize(minWidth: 500, minHeight: 620)
        .alert("Custom field could not be saved", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private var selectedKind: AttributeValueKind {
        AttributeValueKind(rawValue: kind) ?? .text
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            credentialWarning == nil &&
            (selectedKind != .singleSelect && selectedKind != .multiSelect || !parsedOptionLabels.isEmpty)
    }

    private var parsedOptionLabels: [String] {
        var seen = Set<String>()
        return optionsText.split(separator: ",").compactMap { raw in
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = SearchNormalizer.normalize(label)
            return !label.isEmpty && seen.insert(key).inserted ? label : nil
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueKind = selectedKind
        let defaultSensitivity = Sensitivity(rawValue: sensitivity) ?? .private
        let id = original?.id ?? UUID()
        let existingOptions = Dictionary(uniqueKeysWithValues: (original?.options ?? []).map {
            (SearchNormalizer.normalize($0.label.fallback), $0)
        })
        let activeOptionKeys = Set(parsedOptionLabels.map(SearchNormalizer.normalize))
        let activeOptions = parsedOptionLabels.enumerated().map { index, label -> AttributeOption in
            if var existing = existingOptions[SearchNormalizer.normalize(label)] {
                existing.label = .init(label)
                existing.order = index
                existing.archivedAt = nil
                existing.modifiedAt = .now
                return existing
            }
            return AttributeOption(definitionID: id, label: .init(label), order: index)
        }
        let retiredOptions = (original?.options ?? []).compactMap { original -> AttributeOption? in
            guard !activeOptionKeys.contains(SearchNormalizer.normalize(original.label.fallback)) else {
                return nil
            }
            var retired = original
            retired.archivedAt = retired.archivedAt ?? .now
            retired.modifiedAt = .now
            return retired
        }
        var validation = original?.validation ?? .init()
        validation.minimumTextLength = Int(minimumTextLength)
        validation.maximumTextLength = Int(maximumTextLength)
        validation.regularExpression = regularExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : regularExpression
        validation.minimumNumber = Decimal(string: minimumNumber)
        validation.maximumNumber = Decimal(string: maximumNumber)
        let definition = AttributeDefinition(
            id: id,
            predicateID: original?.predicateID ?? "custom.\(UUID().uuidString.lowercased())",
            labels: LocalizedText(trimmed),
            valueKind: valueKind,
            cardinality: valueKind == .multiSelect ? .multiple : cardinality,
            validation: validation,
            defaultSensitivity: defaultSensitivity,
            defaultUsePolicy: AssertionUsePolicy(
                search: searchable ? .include : .exclude,
                remindersAllowed: false,
                notifications: .exclude,
                sharing: .exclude,
                mention: conversation ? .ask : .never,
                ai: AI ? .allowConfiguredShortcut : .deny
            ),
            capabilities: AttributeCapabilities(
                supportsSearch: searchable,
                supportsFilter: filterable,
                supportsSort: sortable,
                supportsReminders: false,
                supportsAI: AI,
                supportsConversationMentions: conversation,
                supportsProfileSharing: false
            ),
            options: activeOptions + retiredOptions,
            displayOrder: original?.displayOrder ?? canonical.activeAttributeDefinitions.count,
            archivedAt: original?.archivedAt,
            createdAt: original?.createdAt ?? .now,
            modifiedAt: .now,
            schemaRevision: original?.schemaRevision ?? 1
        )
        do {
            try canonical.saveAttributeDefinition(definition)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
