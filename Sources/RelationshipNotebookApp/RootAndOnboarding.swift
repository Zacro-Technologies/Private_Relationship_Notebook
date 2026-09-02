import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case today = "Today"
    case people = "People"
    case contexts = "Contexts"
    case add = "Add"
    case activity = "Activity"
    case imports = "Imports & Review"
    case profile = "Profile Sharing"
    case deleted = "Recently Deleted"
    case settings = "Settings"

    var id: String { rawValue }
    var localizedTitle: String { localizedTitle(locale: .current) }

    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .today: String(localized: "Today", locale: locale)
        case .people: String(localized: "People", locale: locale)
        case .contexts: String(localized: "Contexts", locale: locale)
        case .add: String(localized: "Add", locale: locale)
        case .activity: String(localized: "Activity", locale: locale)
        case .imports: String(localized: "Imports & Review", locale: locale)
        case .profile: String(localized: "Profile Sharing", locale: locale)
        case .deleted: String(localized: "Recently Deleted", locale: locale)
        case .settings: String(localized: "Settings", locale: locale)
        }
    }
    var icon: String {
        switch self {
        case .today: "sun.max"
        case .people: "person.2"
        case .contexts: "square.stack.3d.up"
        case .add: "plus.circle.fill"
        case .activity: "clock.arrow.circlepath"
        case .imports: "tray.and.arrow.down"
        case .profile: "person.text.rectangle"
        case .deleted: "archivebox"
        case .settings: "gearshape"
        }
    }
}

struct AdaptiveRootView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var sync: SyncStatusController
    @EnvironmentObject private var lock: AppLockController
    @EnvironmentObject private var notificationDelivery: NotificationDeliveryState
    @EnvironmentObject private var inboundDocuments: InboundDocumentCoordinator
    @Environment(\.locale) private var locale
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var selection: AppSection = .today
    @State private var showingAddPerson = false
    @State private var showingQuickSwitcher = false
    @State private var inboundDocument: InboundDocumentRequest?
    @State private var inboundDocumentError: String?
    @State private var peoplePath: [UUID] = []

    var body: some View {
        platformRoot
            .dropDestination(for: URL.self) { URLs, _ in
                let fileURLs = URLs.filter(\.isFileURL)
                guard !fileURLs.isEmpty else { return false }
                inboundDocuments.enqueue(fileURLs, source: .dragAndDrop)
                presentNextInboundDocumentIfPossible()
                return true
            }
            .onAppear {
                routePendingNotification()
                presentNextInboundDocumentIfPossible()
            }
            .onChange(of: notificationDelivery.pendingRoute) { _, _ in
                routePendingNotification()
            }
            .onChange(of: inboundDocuments.pendingCount) { _, _ in
                presentNextInboundDocumentIfPossible()
            }
            .onChange(of: lock.isLocked) { _, isLocked in
                if !isLocked {
                    routePendingNotification()
                    presentNextInboundDocumentIfPossible()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showQuickSwitcher)) { _ in
                guard !lock.isLocked else { return }
                showingQuickSwitcher = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .sharedCaptureArrived)) { _ in
                presentNextInboundDocumentIfPossible()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAppSection)) { notification in
                guard !lock.isLocked,
                      let section = notification.object as? AppSection else { return }
                selection = section
                if section != .people { peoplePath.removeAll() }
            }
            .sheet(isPresented: $showingQuickSwitcher) {
                KeepsakeQuickSwitcherView(
                    onSelectSection: { section in
                        selection = section
                        if section != .people { peoplePath.removeAll() }
                    },
                    onSelectPerson: { personID in
                        selection = .people
                        peoplePath = [personID]
                    }
                )
            }
            .sheet(item: $inboundDocument, onDismiss: {
                presentNextInboundDocumentIfPossible()
            }) { request in
                InboundDocumentReviewView(request: request) { section in
                    selection = section
                    if section != .people { peoplePath.removeAll() }
                }
            }
            .alert("Shared capture needs attention", isPresented: Binding(
                get: { inboundDocumentError != nil },
                set: { if !$0 { inboundDocumentError = nil } }
            )) {
                Button("OK") { inboundDocumentError = nil }
            } message: {
                Text(inboundDocumentError ?? "")
            }
    }

    @ViewBuilder
    private var platformRoot: some View {
        #if os(iOS)
        if verticalSizeClass == .compact {
            compactLandscapeRoot
        } else if horizontalSizeClass == .regular {
            splitRoot
        } else {
            phoneTabRoot
        }
        #else
        splitRoot
        .sheet(isPresented: $showingAddPerson) { PersonEditorView() }
        .onReceive(NotificationCenter.default.publisher(for: .showAddPerson)) { _ in showingAddPerson = true }
        #endif
    }

    private var splitRoot: some View {
        NavigationSplitView {
            sidebarList
            .navigationTitle("Keepsake")
            .safeAreaInset(edge: .bottom) { syncStatusFooter }
        } detail: {
            selectedDestinationStack
        }
        .onChange(of: selection) { _, section in
            if section != .people { peoplePath.removeAll() }
        }
    }

    @ViewBuilder
    private var sidebarList: some View {
        #if os(iOS)
        List { sidebarSections }
        #else
        List(selection: $selection) { sidebarSections }
        #endif
    }

    @ViewBuilder
    private var sidebarSections: some View {
        Section {
            sidebarLink(.today)
            sidebarLink(.people)
            sidebarLink(.contexts)
            sidebarLink(.activity)
        }
        Section("Capture") {
            sidebarLink(.add)
            sidebarLink(.imports)
            sidebarLink(.profile)
        }
        Section("Notebook") {
            sidebarLink(.deleted)
            sidebarLink(.settings)
        }
    }

    private var selectedDestinationStack: some View {
        NavigationStack(path: $peoplePath) {
            destination(for: selection)
                .navigationDestination(for: UUID.self) { personID in
                    PersonDetailView(personID: personID)
                }
        }
    }

    private var syncStatusFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
            Text(sync.state.title(locale: locale))
            Spacer()
            Circle().fill(syncStatusColor).frame(width: 7, height: 7)
        }
        .font(.caption)
        .foregroundStyle(AppTheme.secondaryText)
        .padding(12)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(localized: "Sync status: \(sync.state.title(locale: locale))", locale: locale)
        )
    }

    #if os(iOS)
    private var phoneTabRoot: some View {
        TabView(selection: $selection) {
            tabDestination(.today) { TodayView() }
                .tabItem { Label("Today", systemImage: AppSection.today.icon) }
                .tag(AppSection.today)
            NavigationStack(path: $peoplePath) {
                PeopleDiscoveryView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { tabBarClearance }
                    .navigationDestination(for: UUID.self) { personID in
                        PersonDetailView(personID: personID)
                    }
            }
            .tabItem { Label("People", systemImage: AppSection.people.icon) }
            .tag(AppSection.people)
            tabDestination(.add) { AddHubView() }
                .tabItem { Label("Add", systemImage: AppSection.add.icon) }
                .tag(AppSection.add)
            tabDestination(.activity) { ActivityView() }
                .tabItem { Label("Activity", systemImage: AppSection.activity.icon) }
                .tag(AppSection.activity)
            tabDestination(.settings) { MeView() }
                .tabItem { Label("Me", systemImage: "person.crop.circle") }
                .tag(AppSection.settings)
        }
    }

    private func tabDestination<Content: View>(
        _ section: AppSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .safeAreaInset(edge: .bottom, spacing: 0) { tabBarClearance }
        }
    }

    private var tabBarClearance: some View {
        Color.clear
            .frame(height: 72)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private var compactLandscapeRoot: some View {
        selectedDestinationStack
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(AppSection.allCases) { section in
                            Button {
                                selection = section
                            } label: {
                                Label(section.localizedTitle(locale: locale), systemImage: section.icon)
                            }
                        }
                    } label: {
                        Label(selection.localizedTitle(locale: locale), systemImage: selection.icon)
                    }
                    .accessibilityLabel("Navigate")
                    .accessibilityValue(selection.localizedTitle(locale: locale))
                    .accessibilityHint("Shows every Keepsake section without covering the content.")
                }
            }
            .onChange(of: selection) { _, section in
                if section != .people { peoplePath.removeAll() }
            }
    }
    #endif

    private func routePendingNotification() {
        guard !lock.isLocked,
              let route = notificationDelivery.pendingRoute else { return }
        switch route {
        case .today:
            selection = .today
            peoplePath.removeAll()
            // TodayView consumes this route only after drawing from the
            // current, unlocked, scope-aware pool.
        case let .person(personID):
            selection = .people
            if let person = store.person(id: personID), person.deletedAt == nil {
                peoplePath = [personID]
            } else {
                peoplePath = []
            }
            notificationDelivery.consume(route)
        }
    }

    private func presentNextInboundDocumentIfPossible() {
        guard !lock.isLocked, inboundDocument == nil else { return }
        do {
            try inboundDocuments.stagePendingShareExtensionItems()
        } catch {
            inboundDocumentError = error.localizedDescription
        }
        inboundDocument = inboundDocuments.takeNext()
    }

    private var syncStatusColor: Color {
        switch sync.state {
        case .localOnly:
            .secondary
        case .waitingForNetwork:
            .orange
        case .syncing:
            .blue
        case .upToDate:
            .green
        case .needsAttention:
            .red
        }
    }

    @ViewBuilder
    private func sidebarLink(_ section: AppSection) -> some View {
        #if os(iOS)
        Button {
            selection = section
        } label: {
            Label(section.localizedTitle(locale: locale), systemImage: section.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == section ? .isSelected : [])
        #else
        Label(section.localizedTitle(locale: locale), systemImage: section.icon)
            .tag(section)
        #endif
    }

    @ViewBuilder
    private func destination(for section: AppSection) -> some View {
        switch section {
        case .today: TodayView()
        case .people: PeopleDiscoveryView()
        case .contexts: ContextsView()
        case .add: AddHubView()
        case .activity: ActivityView()
        case .imports: GuidedImportReviewView()
        case .profile: ProfileSnapshotStudioView()
        case .deleted: RecentlyDeletedView()
        case .settings: SettingsView()
        }
    }
}

/// iPhone's Me tab is an identity landing screen, not a mislabeled Settings
/// form. Self identity is optional and is always an ordinary, editable person
/// record with the explicit `isSelf` marker.
struct MeView: View {
    @EnvironmentObject private var store: NotebookStore
    @AppStorage(KeepsakePreferenceKey.nameDisplayOrder)
    private var nameDisplayOrder = PersonNameDisplayOrder.asEntered.rawValue
    @State private var editingIdentity: Person?
    @State private var showingPersonEditor = false

    private var selfIdentity: Person? {
        store.people.first {
            $0.isSelf && $0.deletedAt == nil && $0.mergedIntoPersonID == nil
        }
    }

    private var displayOrder: PersonNameDisplayOrder {
        PersonNameDisplayOrder(rawValue: nameDisplayOrder) ?? .asEntered
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let person = selfIdentity {
                    NotebookCard {
                        VStack(alignment: .leading, spacing: 16) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 16) { identity(person); Spacer() }
                                identity(person)
                            }
                            if !person.contexts.isEmpty {
                                FlowLayout(spacing: 7) {
                                    ForEach(person.contexts, id: \.self) {
                                        ContextChip(text: $0)
                                    }
                                }
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { identityActions(person) }
                                VStack(alignment: .leading, spacing: 10) {
                                    identityActions(person)
                                }
                            }
                        }
                    }
                } else {
                    NotebookCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Your optional Self profile", systemImage: "person.crop.circle.badge.plus")
                                .font(.title3.bold())
                            Text("Add yourself only if it helps with profile sharing or relative relationship context. In the person editor, turn on “This is my own identity.”")
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                showingPersonEditor = true
                            } label: {
                                Label("Add My Profile…", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.actionFill)
                        }
                    }
                }

                NotebookCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Notebook controls", systemImage: "gearshape")
                            .font(.headline)
                        Text("Privacy, notifications, import defaults, portability, notebook structure, and deletion controls live in Settings & Privacy.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Label("Settings & Privacy", systemImage: "lock.shield")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.pageBackground)
        .navigationTitle("Me")
        .sheet(item: $editingIdentity) { PersonEditorView(person: $0) }
        .sheet(isPresented: $showingPersonEditor) { PersonEditorView() }
    }

    private func identity(_ person: Person) -> some View {
        HStack(spacing: 16) {
            PersonAvatar(person: person, size: 72)
            VStack(alignment: .leading, spacing: 5) {
                Text(person.resolvedDisplayName(order: displayOrder))
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                if !person.role.isEmpty {
                    Text(person.role)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Label("My own identity", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func identityActions(_ person: Person) -> some View {
        NavigationLink {
            PersonDetailView(personID: person.id)
        } label: {
            Label("Open My Profile", systemImage: "person.text.rectangle")
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.actionFill)

        Button {
            editingIdentity = person
        } label: {
            Label("Edit My Profile", systemImage: "pencil")
        }
        .buttonStyle(.bordered)
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var appSession: AppSessionController
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var lock: AppLockController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page = 0
    @AppStorage(ShortcutPCCBridgePreferences.setupCompletedKey)
    private var shortcutAISetupCompleted = false
    @AppStorage(ShortcutPCCBridgePreferences.privacyAcknowledgmentKey)
    private var shortcutAIPrivacyAcknowledged = false
    @AppStorage(ShortcutPCCBridgePreferences.shortcutNameKey)
    private var shortcutAIName = ShortcutPCCBridgePreferences.defaultShortcutName
    @State private var language = UserDefaults.standard.string(
        forKey: KeepsakePreferenceKey.appLanguage
    ) ?? "en"
    @State private var wantsSync = UserDefaults.standard.bool(
        forKey: KeepsakePreferenceKey.syncEnabled
    )
    @State private var wantsLock = UserDefaults.standard.bool(
        forKey: KeepsakePreferenceKey.appLockEnabled
    )
    @State private var frequency = NudgeFrequency.twiceWeekly
    @State private var firstPersonName = ""
    @State private var firstPersonContext = ""
    @State private var firstPersonContactKind: ContactKind?
    @State private var firstPersonContactValue = ""
    @State private var showingShortcutAISetup = false
    @State private var isCompletingSetup = false
    @State private var isRequestingAppLock = false
    let onComplete: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.pageBackground,
                    AppTheme.accentSurface.opacity(0.82),
                    AppTheme.cardBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    onboardingProgress

                    Image(systemName: page == 0 ? "book.closed.fill" : page == 1 ? "lock.shield.fill" : page == 2 ? "sparkles" : "person.2.fill")
                        .font(.system(size: 52, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)

                    VStack(spacing: 12) {
                        Text(title)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(message)
                            .font(.title3)
                            .foregroundStyle(AppTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 570)

                    if page == 2 {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Language", selection: $language) {
                                Text("English").tag("en")
                                Text("日本語").tag("ja")
                            }
                            .pickerStyle(.segmented)
                            .accessibilityLabel("Interface language")
                            .accessibilityValue(
                                language == "ja"
                                    ? String(localized: "Japanese", locale: onboardingLocale)
                                    : String(localized: "English", locale: onboardingLocale)
                            )
                            .accessibilityHint("Changes this setup screen immediately.")
                            ViewThatFits(in: .horizontal) {
                                HStack {
                                    Label("Keepsake AI", systemImage: "command")
                                        .font(.headline)
                                    Spacer()
                                    shortcutAIStatus
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("Keepsake AI", systemImage: "command")
                                        .font(.headline)
                                    shortcutAIStatus
                                }
                            }
                            Button(shortcutAISetupReady
                                   ? String(localized: "Review AI Connection", locale: onboardingLocale)
                                   : String(localized: "Connect Keepsake AI", locale: onboardingLocale)) {
                                showingShortcutAISetup = true
                            }
                            .buttonStyle(.borderedProminent)
                            Text("Keepsake has one AI path: a required Apple Shortcut configured with Use Model → Extension Model (ChatGPT). The exact context you approve is intended for ChatGPT, operated by OpenAI. The setup test validates only authenticated Get/Return transport; the model choice, account mode, and other actions remain unverified.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle("Synchronize through my private iCloud", isOn: $wantsSync)
                            Text("Your Apple Account owns its private CloudKit storage and quota. Keepsake verifies a separate iCloud replica before moving any local records.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle("Require device authentication", isOn: Binding(
                                get: { wantsLock || isRequestingAppLock },
                                set: { requestAppLockChange(enabled: $0) }
                            ))
                            .disabled(isRequestingAppLock)
                            if isRequestingAppLock {
                                Label("Confirming device authentication…", systemImage: "lock.shield")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                            } else if wantsLock {
                                Text("App Lock is ready and will apply after setup.")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(18)
                        .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
                        .frame(maxWidth: 570)
                    }

                    if page == 3 {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("First person or placeholder (optional)", text: $firstPersonName)
                                .textFieldStyle(.roundedBorder)
                            TextField("How you know them or a shared context (optional)", text: $firstPersonContext)
                                .textFieldStyle(.roundedBorder)
                            Picker("Preferred channel (optional)", selection: $firstPersonContactKind) {
                                Text("No channel yet").tag(nil as ContactKind?)
                                ForEach(ContactKind.allCases) { kind in
                                    Text(kind.localizedTitle(locale: onboardingLocale))
                                        .tag(kind as ContactKind?)
                                }
                            }
                            if let firstPersonContactKind {
                                TextField(
                                    contactValuePrompt(for: firstPersonContactKind),
                                    text: $firstPersonContactValue
                                )
                                .textFieldStyle(.roundedBorder)
                                .privacySensitive()
                            }
                            Text("A context or complete channel makes this person eligible for a first suggestion. You can leave both blank and add one later from their profile.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider()
                            Picker("Connection suggestions", selection: $frequency) {
                                ForEach(NudgeFrequency.allCases) {
                                    Text($0.localizedTitle(locale: onboardingLocale)).tag($0)
                                }
                            }
                            firstSuggestionPreview
                        }
                        .padding(18)
                        .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
                        .frame(maxWidth: 570)

                        Text("This preview is deterministic and generated on this device; it is not ChatGPT wording and is never sent automatically. If you later request AI wording, the connected model may use different language or phrasing, and you review the result before use.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 570)

                        Button("Explore with three example people") {
                            completeSetup(seedExamples: true)
                        }
                        .font(.subheadline)
                        .disabled(setupActionsAreDisabled)
                    }

                    Text("Your notebook is local-first. Nothing is shared unless you choose to share a profile card or export.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 570)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 32)
            }
            .id(page)
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            onboardingNavigationBar
        }
        .environment(\.locale, onboardingLocale)
        .onChange(of: language) { _, value in
            UserDefaults.standard.set(value, forKey: KeepsakePreferenceKey.appLanguage)
        }
        .sheet(isPresented: $showingShortcutAISetup) {
            NavigationStack {
                ShortcutPCCBridgeSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingShortcutAISetup = false }
                        }
                    }
            }
            .environment(\.locale, onboardingLocale)
        }
        .alert("Couldn’t enable App Lock", isPresented: Binding(
            get: { lock.setupErrorMessage != nil },
            set: { if !$0 { lock.setupErrorMessage = nil } }
        )) {
            Button("OK") { lock.setupErrorMessage = nil }
        } message: {
            Text(lock.setupErrorMessage ?? "")
        }
    }

    private var shortcutAIStatus: some View {
        Text(shortcutAISetupReady
             ? String(localized: "Ready", locale: onboardingLocale)
             : String(localized: "Setup required", locale: onboardingLocale))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(
                shortcutAISetupReady
                    ? String(localized: "Keepsake AI: Ready", locale: onboardingLocale)
                    : String(localized: "Keepsake AI: Setup required", locale: onboardingLocale)
            )
    }

    private var onboardingLocale: Locale {
        Locale(identifier: language)
    }

    private var onboardingProgress: some View {
        ProgressView(value: Double(page + 1), total: 4) {
            Text(String(
                localized: "Setup step \(page + 1) of 4",
                locale: onboardingLocale
            ))
            .font(.caption.weight(.semibold))
        }
        .tint(AppTheme.accent)
        .frame(maxWidth: 570)
        .accessibilityLabel("Setup progress")
        .accessibilityValue(String(
            localized: "Step \(page + 1) of 4",
            locale: onboardingLocale
        ))
    }

    private var onboardingNavigationBar: some View {
        VStack(spacing: 12) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) {
                        if page > 0 { onboardingBackButton }
                        onboardingContinueButton
                    }
                } else {
                    HStack(spacing: 12) {
                        if page > 0 { onboardingBackButton }
                        onboardingContinueButton
                    }
                }
            }
            .frame(maxWidth: 570)

            if isCompletingSetup {
                ProgressView("Finishing setup…")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var onboardingBackButton: some View {
        Button(String(localized: "Back", locale: onboardingLocale)) {
            withAnimation { page -= 1 }
        }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(setupActionsAreDisabled)
    }

    private var onboardingContinueButton: some View {
        Button {
            if page < 3 {
                withAnimation { page += 1 }
            } else {
                completeSetup(seedExamples: false)
            }
        } label: {
            Text(page == 3
                 ? String(localized: "Create private notebook", locale: onboardingLocale)
                 : String(localized: "Continue", locale: onboardingLocale))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.actionFill)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .disabled(setupActionsAreDisabled)
    }

    @ViewBuilder
    private var firstSuggestionPreview: some View {
        let name = firstPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = firstPersonContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let contact = firstPersonContactValue.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 7) {
            Label("First suggestion preview", systemImage: "sparkles")
                .font(.headline)
            if name.isEmpty {
                Text("Enter a name or placeholder to preview a suggestion.")
                    .foregroundStyle(AppTheme.secondaryText)
            } else if context.isEmpty && (firstPersonContactKind == nil || contact.isEmpty) {
                Label(
                    "Add a context or complete a preferred channel before suggestions can include this person.",
                    systemImage: "arrow.up"
                )
                .keepsakeWarningStyle()
            } else {
                Text(String(localized: "Reconnect with \(name)", locale: onboardingLocale))
                    .font(.headline)
                Text(firstSuggestionPrompt(context: context))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.accentSurface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var setupActionsAreDisabled: Bool {
        isCompletingSetup || isRequestingAppLock
    }

    private func firstSuggestionPrompt(context: String) -> String {
        if !context.isEmpty {
            return String(
                localized: "Share a brief, context-neutral check-in. The context “\(context)” makes this person eligible but is not suggested as message content.",
                locale: onboardingLocale
            )
        }
        if let channel = firstPersonContactKind {
            return String(
                localized: "Share a brief check-in using \(channel.localizedTitle(locale: onboardingLocale)).",
                locale: onboardingLocale
            )
        }
        return String(localized: "Share a brief check-in.", locale: onboardingLocale)
    }

    private func contactValuePrompt(for kind: ContactKind) -> String {
        switch kind {
        case .email:
            String(localized: "Email address", locale: onboardingLocale)
        case .messages, .phone:
            String(localized: "Phone number or address", locale: onboardingLocale)
        case .line, .instagram, .whatsapp, .snapchat:
            String(localized: "Handle or recipient", locale: onboardingLocale)
        }
    }

    private var shortcutAISetupReady: Bool {
        ShortcutPCCBridgePreferences.isSetupReady(
            setupCompleted: shortcutAISetupCompleted,
            privacyAcknowledged: shortcutAIPrivacyAcknowledged,
            shortcutName: shortcutAIName
        )
    }

    private var title: String {
        switch page {
        case 0: String(localized: "Remember what matters", locale: onboardingLocale)
        case 1: String(localized: "Private by default", locale: onboardingLocale)
        case 2: String(localized: "Connect Keepsake AI", locale: onboardingLocale)
        default: String(localized: "A useful first step", locale: onboardingLocale)
        }
    }

    private var message: String {
        switch page {
        case 0: String(localized: "A calm, personal notebook for the people already in your life—and the context you want to remember.", locale: onboardingLocale)
        case 1: String(localized: "This is not a directory or social score. Capture respectfully, keep private notes private, and review every suggestion.", locale: onboardingLocale)
        case 2: String(localized: "Personalized AI uses one protected Apple Shortcuts connection to ChatGPT. Every request and result remains reviewable.", locale: onboardingLocale)
        default: String(localized: "Optionally add one person now. You can create a reviewed profile card about yourself later.", locale: onboardingLocale)
        }
    }

    private func requestAppLockChange(enabled: Bool) {
        guard enabled else {
            lock.disable()
            wantsLock = false
            return
        }
        guard !isRequestingAppLock else { return }
        isRequestingAppLock = true
        Task { @MainActor in
            wantsLock = await lock.enable()
            isRequestingAppLock = false
        }
    }

    private func saveSetupChoices() {
        UserDefaults.standard.set(language, forKey: KeepsakePreferenceKey.appLanguage)
        UserDefaults.standard.set(wantsSync, forKey: KeepsakePreferenceKey.syncEnabled)
        UserDefaults.standard.set(frequency.rawValue, forKey: "nudgeFrequency")
        let trimmedPersonName = firstPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPersonName.isEmpty, store.people.isEmpty {
            let context = firstPersonContext.trimmingCharacters(in: .whitespacesAndNewlines)
            let contactValue = firstPersonContactValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let contacts: [ContactMethod]
            if let firstPersonContactKind, !contactValue.isEmpty {
                contacts = [ContactMethod(
                    kind: firstPersonContactKind,
                    value: contactValue,
                    isPreferred: true
                )]
            } else {
                contacts = []
            }
            store.save(Person(
                displayName: trimmedPersonName,
                contexts: context.isEmpty ? [] : [context],
                contacts: contacts
            ))
        }
    }

    private func completeSetup(seedExamples: Bool) {
        guard !isCompletingSetup else { return }
        isCompletingSetup = true
        saveSetupChoices()
        if seedExamples {
            store.seedExamples()
        }
        guard wantsSync else {
            onComplete()
            isCompletingSetup = false
            return
        }
        Task { @MainActor in
            await appSession.beginMoveToICloud {
                // The session transition already owns the loading/review UI.
                // Persist completion now, before any long CloudKit wait, while
                // still preventing a Today/lock-screen flash that can look
                // like an app crash.
                onComplete()
            }
            isCompletingSetup = false
        }
    }
}
