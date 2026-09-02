import SwiftUI

struct PeopleDiscoveryView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.locale) private var locale

    @State private var searchText = ""
    @State private var selectedCircles: Set<String> = []
    @State private var selectedContexts: Set<String> = []
    @State private var excludedContexts: Set<String> = []
    @State private var selectedChannels: Set<String> = []
    @State private var excludedChannels: Set<String> = []
    @State private var selectedTags: Set<String> = []
    @State private var excludedTags: Set<String> = []
    @State private var canonicalFilters = CanonicalDiscoveryFilterState()
    @State private var contactAge = DiscoveryContactAge.any.rawValue
    @State private var eligibleOnly = false
    @State private var includeArchived = false
    @State private var sort = LocalSearchPersonField.name
    @State private var descending = false
    @State private var unknownsFirst = false
    @State private var selectedSavedViewID: UUID?

    @State private var searchService = LocalSearch()
    @State private var results: [DiscoveryResult] = []
    @State private var totalCount = 0
    @State private var nextCursor: LocalSearchCursor?
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var showingAddPerson = false
    @State private var showingFilters = false
    @State private var showingLocalQueryBuilder = false
    @State private var showingSaveView = false
    @State private var showingManageViews = false
    @State private var isIndexing = false
    @State private var indexProgress: Double?
    @State private var indexingTask: Task<Void, Never>?

    private var contexts: [String] {
        let canonicalNames = canonical.contexts.map {
            $0.names.resolved(preferredLanguageTags: [locale.identifier])
        }
        return Set(store.people.flatMap(\.contexts) + canonicalNames).sorted()
    }
    private var tags: [String] { Set(store.people.flatMap(\.tags)).sorted() }
    private var channels: [String] { Set(store.people.flatMap { $0.contacts.map(\.kind.rawValue) }).sorted() }
    private var canonicalFacetOptions: CanonicalDiscoveryFacetOptions {
        CanonicalDiscoveryFacetOptions(
            cohorts: canonical.cohorts.map {
                DiscoveryUUIDOption(
                    id: $0.id,
                    title: $0.labels.resolved(preferredLanguageTags: [locale.identifier])
                )
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
            roles: Set(
                store.people.map(\.role).filter { !$0.isEmpty }
                    + canonical.roleDefinitions.map {
                        $0.labels.resolved(preferredLanguageTags: [locale.identifier])
                    }
                    + canonical.roleAssignments.map {
                        $0.roleLabel.resolved(preferredLanguageTags: [locale.identifier])
                    }
            ).sorted(),
            locations: assertionFacetStrings { value in
                switch value {
                case let .location(location): [location.label]
                case let .address(address): [
                    address.locality,
                    address.administrativeArea,
                    address.countryCode
                ].compactMap { $0 }
                default: []
                }
            },
            timeZones: assertionFacetStrings { value in
                guard case let .location(location) = value,
                      let timeZone = location.timeZoneIdentifier else { return [] }
                return [timeZone]
            },
            languages: assertionFacetStrings { value in
                guard case let .language(language) = value else { return [] }
                return [language]
            },
            sources: canonical.sources.map {
                DiscoveryUUIDOption(id: $0.id, title: sourceTitle($0))
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
            customFields: canonical.attributeDefinitions
                .filter { $0.archivedAt == nil && $0.capabilities.supportsFilter }
                .map {
                    DiscoveryCustomField(
                        id: "attribute.\($0.predicateID)",
                        title: $0.labels.resolved(preferredLanguageTags: [locale.identifier]),
                        valueKind: $0.valueKind,
                        options: discoveryOptions(for: $0)
                    )
                }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        )
    }

    private var sortOptions: [DiscoverySortOption] {
        [
            .init(field: LocalSearchPersonField.name, title: String(localized: "Name")),
            .init(field: LocalSearchPersonField.createdAt, title: String(localized: "Recently added")),
            .init(field: LocalSearchPersonField.modifiedAt, title: String(localized: "Recently updated")),
            .init(field: LocalSearchPersonField.lastInteractionAt, title: String(localized: "Last interaction")),
            .init(field: LocalSearchPersonField.nextCadenceDue, title: String(localized: "Next contact due")),
            .init(field: LocalSearchPersonField.educationGraduation, title: String(localized: "Actual graduation"))
        ] + canonical.attributeDefinitions
            .filter { $0.archivedAt == nil && $0.capabilities.supportsSort }
            .map {
                DiscoverySortOption(
                    field: "attribute.\($0.predicateID)",
                    title: $0.labels.resolved(preferredLanguageTags: [locale.identifier])
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        Group {
            if store.people.filter({ !$0.isArchived && $0.deletedAt == nil }).isEmpty,
               !includeArchived {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if store.people.contains(where: { $0.isArchived && $0.deletedAt == nil }) {
                    ContentUnavailableView {
                        Label("Only archived people", systemImage: "archivebox")
                    } description: {
                        Text("Your active People list is empty. Archived profiles are still available.")
                    } actions: {
                        Button("Show Archived People") { includeArchived = true }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.actionFill)
                        Button("Add person") { showingAddPerson = true }
                    }
                } else {
                    EmptyNotebookView(
                        icon: "person.2",
                        title: "Your people, in context",
                        message: "Start with a name. Rich details are always optional.",
                        actionTitle: "Add person"
                    ) { showingAddPerson = true }
                }
            } else {
                List {
                    Section {
                        discoveryControls
                            .listRowSeparator(.hidden)
                    }
                    Section {
                        if isSearching && results.isEmpty {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else if results.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        } else {
                            ForEach(results) { result in
                                NavigationLink {
                                    PersonDetailView(personID: result.person.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        PersonRow(person: result.person)
                                        if !result.reasonLabels.isEmpty {
                                            Label(
                                                "Matched: \(result.reasonLabels.joined(separator: ", "))",
                                                systemImage: "magnifyingglass"
                                            )
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.secondaryText)
                                            .padding(.leading, 57)
                                        }
                                    }
                                }
                            }
                            if nextCursor != nil {
                                Button {
                                    Task { await loadNextPage() }
                                } label: {
                                    HStack {
                                        Spacer()
                                        Label("Load more", systemImage: "chevron.down.circle")
                                        Spacer()
                                    }
                                }
                                .disabled(isSearching)
                            }
                        }
                    } header: {
                        if results.count < totalCount {
                            Text("Showing \(results.count) of \(totalCount) people")
                        } else {
                            Text("\(totalCount) people")
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("People")
        .searchable(text: $searchText, prompt: "Names, aliases, contexts, roles, tags")
        .toolbar {
            #if os(iOS)
            NavigationLink {
                ContextsView()
            } label: {
                Label("Contexts", systemImage: "square.stack.3d.up")
            }
            #endif
            Button { showingFilters = true } label: {
                Label("Filters", systemImage: hasManualFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .disabled(selectedSavedViewID != nil)
            Button { showingLocalQueryBuilder = true } label: {
                Label("Build Local Query", systemImage: "text.magnifyingglass")
            }
            .disabled(selectedSavedViewID != nil)
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(sortOptions) { option in Text(option.title).tag(option.field) }
                }
                Toggle("Descending", isOn: $descending)
                Toggle("Unknown values first", isOn: $unknownsFirst)
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            .disabled(selectedSavedViewID != nil)
            Button { showingAddPerson = true } label: { Label("Add Person", systemImage: "plus") }
        }
        .sheet(isPresented: $showingAddPerson) { PersonEditorView() }
        .sheet(isPresented: $showingFilters) {
            PeopleFilterSheet(
                contexts: contexts,
                tags: tags,
                channels: channels,
                selectedCircles: $selectedCircles,
                selectedContexts: $selectedContexts,
                excludedContexts: $excludedContexts,
                selectedChannels: $selectedChannels,
                excludedChannels: $excludedChannels,
                selectedTags: $selectedTags,
                excludedTags: $excludedTags,
                canonicalFilters: $canonicalFilters,
                canonicalOptions: canonicalFacetOptions,
                contactAge: $contactAge,
                eligibleOnly: $eligibleOnly,
                includeArchived: $includeArchived
            )
        }
        .sheet(isPresented: $showingLocalQueryBuilder) {
            LocalPeopleQueryBuilderSheet(
                contexts: contexts,
                tags: tags,
                channels: channels,
                onApply: applyLocalQuery
            )
        }
        .sheet(isPresented: $showingSaveView) {
            SaveDiscoveryViewSheet(filter: currentFilter, sorts: currentSorts)
        }
        .sheet(isPresented: $showingManageViews) {
            SavedViewsManagerSheet()
        }
        .task(id: projectionRevision) {
            indexingTask?.cancel()
            let task = Task { await rebuildAndSearch() }
            indexingTask = task
            await task.value
        }
        .task(id: queryFingerprint) { await runSearch() }
        .onDisappear { indexingTask?.cancel() }
        .onChange(of: selectedSavedViewID) { _, newValue in
            if newValue != nil { clearManualFiltersForSavedView() }
        }
        .alert("Search needs attention", isPresented: Binding(
            get: { searchError != nil },
            set: { if !$0 { searchError = nil } }
        )) {
            Button("OK") { searchError = nil }
        } message: { Text(searchError ?? "") }
    }

    private var discoveryControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Saved view", selection: $selectedSavedViewID) {
                    Text("Custom filters").tag(nil as UUID?)
                    ForEach(canonical.activeSavedViews) { view in Text(view.name).tag(view.id as UUID?) }
                }
                .frame(maxWidth: 280)
                Button("Save Current View…") { showingSaveView = true }
                    .disabled(selectedSavedViewID != nil)
                Button("Manage Views…") { showingManageViews = true }
                Spacer()
                if isIndexing {
                    if let indexProgress { ProgressView(value: indexProgress).frame(width: 80) }
                    else { ProgressView().controlSize(.small) }
                    Button("Cancel indexing") { indexingTask?.cancel() }
                        .font(.caption)
                } else if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            if let selectedSavedView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved criteria are active and manual Filter/Sort controls are locked.")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    Text(savedViewCriteriaSummary(selectedSavedView))
                        .font(.caption2).foregroundStyle(AppTheme.secondaryText)
                        .textSelection(.enabled)
                    Toggle("Include archived people as an explicit overlay", isOn: $includeArchived)
                        .font(.caption)
                    Button("Return to editable custom filters") { selectedSavedViewID = nil }
                        .font(.caption)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(activeFilterLabels, id: \.self) { ContextChip(text: $0) }
                    if activeFilterLabels.isEmpty {
                        Text("Offline search across the complete local notebook")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                }
            }
        }
    }

    private var selectedSavedView: SavedView? {
        guard let selectedSavedViewID else { return nil }
        return canonical.savedViews.first { $0.id == selectedSavedViewID }
    }

    private func applyLocalQuery(_ interpretation: LocalPeopleQueryInterpretation) {
        selectedSavedViewID = nil
        searchText = interpretation.searchTerms
        selectedContexts = interpretation.includedContexts
        excludedContexts = interpretation.excludedContexts
        selectedTags = interpretation.includedTags
        excludedTags = interpretation.excludedTags
        selectedChannels = interpretation.includedChannels
        excludedChannels = interpretation.excludedChannels
        includeArchived = interpretation.includeArchived
        eligibleOnly = interpretation.eligibleOnly
        contactAge = interpretation.contactAge.rawValue
    }

    private var currentFilter: FilterNode {
        var conditions: [FilterNode] = []
        if !selectedCircles.isEmpty {
            conditions.append(.condition(.init(
                field: LocalSearchPersonField.relationshipCircle,
                operator: .containsAny,
                value: .strings(selectedCircles.sorted())
            )))
        }
        if !selectedContexts.isEmpty {
            conditions.append(.condition(.init(
                field: LocalSearchPersonField.context,
                operator: .containsAny,
                value: .strings(selectedContexts.sorted())
            )))
        }
        if !excludedContexts.isEmpty {
            conditions.append(.not(.condition(.init(
                field: LocalSearchPersonField.context,
                operator: .containsAny,
                value: .strings(excludedContexts.sorted())
            ))))
        }
        if !selectedChannels.isEmpty {
            conditions.append(.condition(.init(
                field: LocalSearchPersonField.channel,
                operator: .containsAny,
                value: .strings(selectedChannels.sorted())
            )))
        }
        if !excludedChannels.isEmpty {
            conditions.append(.not(.condition(.init(
                field: LocalSearchPersonField.channel,
                operator: .containsAny,
                value: .strings(excludedChannels.sorted())
            ))))
        }
        if !selectedTags.isEmpty {
            conditions.append(.condition(.init(
                field: LocalSearchPersonField.tag,
                operator: .containsAny,
                value: .strings(selectedTags.sorted())
            )))
        }
        if !excludedTags.isEmpty {
            conditions.append(.not(.condition(.init(
                field: LocalSearchPersonField.tag,
                operator: .containsAny,
                value: .strings(excludedTags.sorted())
            ))))
        }
        appendUUIDFacet(
            field: LocalSearchPersonField.cohort,
            included: canonicalFilters.selectedCohortIDs,
            excluded: canonicalFilters.excludedCohortIDs,
            to: &conditions
        )
        appendStringFacet(
            field: LocalSearchPersonField.membershipStatus,
            included: canonicalFilters.selectedMembershipStatuses,
            excluded: canonicalFilters.excludedMembershipStatuses,
            to: &conditions
        )
        appendStringFacet(
            field: LocalSearchPersonField.role,
            included: canonicalFilters.selectedRoles,
            excluded: canonicalFilters.excludedRoles,
            to: &conditions
        )
        appendStringFacet(
            field: LocalSearchPersonField.educationStatus,
            included: canonicalFilters.selectedEducationStatuses,
            excluded: canonicalFilters.excludedEducationStatuses,
            to: &conditions
        )
        appendStringFacet(
            field: LocalSearchPersonField.location,
            included: canonicalFilters.selectedLocations,
            excluded: canonicalFilters.excludedLocations,
            to: &conditions
        )
        appendStringFacet(
            field: LocalSearchPersonField.timeZone,
            included: canonicalFilters.selectedTimeZones,
            excluded: canonicalFilters.excludedTimeZones,
            to: &conditions
        )
        appendStringFacet(
            field: LocalSearchPersonField.language,
            included: canonicalFilters.selectedLanguages,
            excluded: canonicalFilters.excludedLanguages,
            to: &conditions
        )
        appendStringFacet(
            field: LocalSearchPersonField.relativeCohortPosition,
            included: canonicalFilters.selectedRelativeCohortPositions,
            excluded: canonicalFilters.excludedRelativeCohortPositions,
            to: &conditions
        )
        if canonicalFilters.maximumCohortDistanceEnabled {
            conditions.append(.condition(.init(
                field: LocalSearchPersonField.cohortDistance,
                operator: .lessThanOrEqual,
                value: .integer(canonicalFilters.maximumCohortDistance)
            )))
        }
        appendUUIDFacet(
            field: LocalSearchPersonField.source,
            included: canonicalFilters.selectedSourceIDs,
            excluded: canonicalFilters.excludedSourceIDs,
            to: &conditions
        )
        appendStringFacet(
            field: LocalSearchPersonField.assertionReviewStatus,
            included: canonicalFilters.selectedReviewStatuses,
            excluded: canonicalFilters.excludedReviewStatuses,
            to: &conditions
        )
        appendStringFacet(
            field: LocalSearchPersonField.assertionSensitivity,
            included: canonicalFilters.selectedSensitivities,
            excluded: canonicalFilters.excludedSensitivities,
            to: &conditions
        )
        appendGraduationFilter(to: &conditions)
        appendConfidenceFilter(to: &conditions)
        appendFreshnessFilter(to: &conditions)
        appendCustomFilters(to: &conditions)
        if eligibleOnly {
            conditions.append(.condition(.init(
                field: LocalSearchPersonField.nudgeEligible,
                operator: .equals,
                value: .boolean(true)
            )))
        }
        switch DiscoveryContactAge(rawValue: contactAge) ?? .any {
        case .any: break
        case .over30: conditions.append(contactAgeNode(days: 30))
        case .over90: conditions.append(contactAgeNode(days: 90))
        case .over180: conditions.append(contactAgeNode(days: 180))
        case .unknown:
            conditions.append(.condition(.init(
                field: LocalSearchPersonField.lastInteractionAt,
                operator: .isUnknown
            )))
        }
        if conditions.isEmpty {
            return .condition(.init(field: LocalSearchPersonField.name, operator: .exists))
        }
        return conditions.count == 1 ? conditions[0] : .and(conditions)
    }

    private func contactAgeNode(days: Int) -> FilterNode {
        .condition(.init(
            field: LocalSearchPersonField.lastInteractionAt,
            operator: .beforeRelativeDays,
            value: .integer(days)
        ))
    }

    private func appendStringFacet(
        field: String,
        included: Set<String>,
        excluded: Set<String>,
        to conditions: inout [FilterNode]
    ) {
        if !included.isEmpty {
            conditions.append(.condition(.init(
                field: field,
                operator: .containsAny,
                value: .strings(included.sorted())
            )))
        }
        if !excluded.isEmpty {
            conditions.append(.not(.condition(.init(
                field: field,
                operator: .containsAny,
                value: .strings(excluded.sorted())
            ))))
        }
    }

    private func appendUUIDFacet(
        field: String,
        included: Set<UUID>,
        excluded: Set<UUID>,
        to conditions: inout [FilterNode]
    ) {
        if !included.isEmpty {
            conditions.append(.condition(.init(
                field: field,
                operator: .containsAny,
                value: .uuids(included.sorted { $0.uuidString < $1.uuidString })
            )))
        }
        if !excluded.isEmpty {
            conditions.append(.not(.condition(.init(
                field: field,
                operator: .containsAny,
                value: .uuids(excluded.sorted { $0.uuidString < $1.uuidString })
            ))))
        }
    }

    private func appendGraduationFilter(to conditions: inout [FilterNode]) {
        switch DiscoveryDateFilter(rawValue: canonicalFilters.graduationFilter) ?? .any {
        case .any:
            break
        case .known:
            conditions.append(.condition(.init(
                field: LocalSearchPersonField.educationGraduation,
                operator: .exists
            )))
        case .unknown:
            conditions.append(.condition(.init(
                field: LocalSearchPersonField.educationGraduation,
                operator: .isUnknown
            )))
        case .range:
            if let range = partialDateRange(
                startYear: canonicalFilters.graduationStartYear,
                endYear: canonicalFilters.graduationEndYear
            ) {
                conditions.append(.condition(.init(
                    field: LocalSearchPersonField.educationGraduation,
                    operator: .between,
                    value: .dateRange(range)
                )))
            }
        }
    }

    private func appendConfidenceFilter(to conditions: inout [FilterNode]) {
        guard canonicalFilters.confidenceRangeEnabled else { return }
        conditions.append(.condition(.init(
            field: LocalSearchPersonField.assertionConfidence,
            operator: .greaterThanOrEqual,
            value: .number(min(canonicalFilters.minimumConfidence, canonicalFilters.maximumConfidence))
        )))
        conditions.append(.condition(.init(
            field: LocalSearchPersonField.assertionConfidence,
            operator: .lessThanOrEqual,
            value: .number(max(canonicalFilters.minimumConfidence, canonicalFilters.maximumConfidence))
        )))
    }

    private func appendFreshnessFilter(to conditions: inout [FilterNode]) {
        let condition: FilterCondition?
        switch DiscoveryFreshnessFilter(rawValue: canonicalFilters.assertionFreshness) ?? .any {
        case .any: condition = nil
        case .recent30: condition = .init(
            field: LocalSearchPersonField.assertionFreshness,
            operator: .afterRelativeDays,
            value: .integer(30)
        )
        case .recent90: condition = .init(
            field: LocalSearchPersonField.assertionFreshness,
            operator: .afterRelativeDays,
            value: .integer(90)
        )
        case .recent365: condition = .init(
            field: LocalSearchPersonField.assertionFreshness,
            operator: .afterRelativeDays,
            value: .integer(365)
        )
        case .older365: condition = .init(
            field: LocalSearchPersonField.assertionFreshness,
            operator: .beforeRelativeDays,
            value: .integer(365)
        )
        case .unknown: condition = .init(
            field: LocalSearchPersonField.assertionFreshness,
            operator: .isUnknown
        )
        }
        if let condition { conditions.append(.condition(condition)) }
    }

    private func appendCustomFilters(to conditions: inout [FilterNode]) {
        for field in canonicalFacetOptions.customFields {
            let availability = DiscoveryAvailabilityFilter(
                rawValue: canonicalFilters.customAvailability[field.id] ?? DiscoveryAvailabilityFilter.any.rawValue
            ) ?? .any
            switch availability {
            case .any: break
            case .known: conditions.append(.condition(.init(field: field.id, operator: .exists)))
            case .unknown: conditions.append(.condition(.init(field: field.id, operator: .isUnknown)))
            }

            switch field.valueKind {
            case .boolean:
                switch canonicalFilters.customBooleanValue[field.id] {
                case "true": conditions.append(.condition(.init(
                    field: field.id, operator: .equals, value: .boolean(true)
                )))
                case "false": conditions.append(.condition(.init(
                    field: field.id, operator: .equals, value: .boolean(false)
                )))
                default: break
                }
            case .number:
                if let minimum = Double(canonicalFilters.customMinimum[field.id] ?? "") {
                    conditions.append(.condition(.init(
                        field: field.id,
                        operator: .greaterThanOrEqual,
                        value: .number(minimum)
                    )))
                }
                if let maximum = Double(canonicalFilters.customMaximum[field.id] ?? "") {
                    conditions.append(.condition(.init(
                        field: field.id,
                        operator: .lessThanOrEqual,
                        value: .number(maximum)
                    )))
                }
            case .partialDate:
                if let range = partialDateRange(
                    startYear: Int(canonicalFilters.customMinimum[field.id] ?? ""),
                    endYear: Int(canonicalFilters.customMaximum[field.id] ?? "")
                ) {
                    conditions.append(.condition(.init(
                        field: field.id,
                        operator: .between,
                        value: .dateRange(range)
                    )))
                }
            case .dateRange:
                if let range = partialDateRange(
                    startYear: Int(canonicalFilters.customMinimum[field.id] ?? ""),
                    endYear: Int(canonicalFilters.customMaximum[field.id] ?? "")
                ) {
                    conditions.append(.condition(.init(
                        field: field.id,
                        operator: .between,
                        value: .dateRange(range)
                    )))
                }
            case .text, .richText, .language, .url, .email, .phone, .location, .address:
                let value = canonicalFilters.customExactValue[field.id, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    conditions.append(.condition(.init(
                        field: field.id,
                        operator: canonicalFilters.excludedCustomExactFields.contains(field.id)
                            ? .notEquals : .equals,
                        value: .string(value)
                    )))
                }
            case .singleSelect, .multiSelect, .personReference,
                 .contextReference, .mediaReference:
                appendUUIDFacet(
                    field: field.id,
                    included: canonicalFilters.customIncludedUUIDValues[field.id] ?? [],
                    excluded: canonicalFilters.customExcludedUUIDValues[field.id] ?? [],
                    to: &conditions
                )
            case .structuredJSON:
                break
            }
        }
    }

    private func partialDateRange(startYear: Int?, endYear: Int?) -> PartialDateRange? {
        let start = startYear.flatMap { try? PartialDate.year($0) }
        let end = endYear.flatMap { try? PartialDate.year($0) }
        return try? PartialDateRange(start: start, end: end)
    }

    private var currentSorts: [SortSpecification] {
        let field = sortOptions.contains(where: { $0.field == sort })
            ? sort : LocalSearchPersonField.name
        return [.init(
            field: field,
            direction: descending ? .descending : .ascending,
            unknownPlacement: unknownsFirst ? .first : .last
        )]
    }

    private var query: LocalSearchQuery {
        if let saved = selectedSavedView {
            return LocalSearchQuery(
                savedView: saved,
                text: searchText,
                includeArchived: includeArchived,
                localeIdentifier: locale.identifier
            )
        }
        return LocalSearchQuery(
            text: searchText,
            textMatchMode: .allTerms,
            filter: currentFilter,
            sorts: currentSorts,
            includeArchived: includeArchived,
            localeIdentifier: locale.identifier
        )
    }

    private var hasManualFilters: Bool {
        !selectedCircles.isEmpty || !selectedContexts.isEmpty || !excludedContexts.isEmpty ||
            !selectedChannels.isEmpty || !excludedChannels.isEmpty ||
            !selectedTags.isEmpty || !excludedTags.isEmpty || eligibleOnly ||
            !canonicalFilters.isEmpty || contactAge != DiscoveryContactAge.any.rawValue || includeArchived
    }

    private var activeFilterLabels: [String] {
        if let selectedSavedView { return [String(localized: "Saved: \(selectedSavedView.name)")] }
        var values = selectedCircles.sorted() + selectedContexts.sorted()
        values += excludedContexts.sorted().map { String(localized: "Not \($0)") }
        values += selectedChannels.sorted() + selectedTags.sorted()
        values += excludedChannels.sorted().map { String(localized: "Not \($0)") }
        values += excludedTags.sorted().map { String(localized: "Not \($0)") }
        if !canonicalFilters.isEmpty { values.append(String(localized: "Structured filters")) }
        if eligibleOnly { values.append(String(localized: "Eligible for nudges")) }
        if contactAge != DiscoveryContactAge.any.rawValue {
            values.append((DiscoveryContactAge(rawValue: contactAge) ?? .any).title)
        }
        if includeArchived { values.append(String(localized: "Including archived")) }
        return values
    }

    private var queryFingerprint: String {
        let filterLabels: [String] = [
            selectedCircles.sorted().joined(),
            selectedContexts.sorted().joined(),
            excludedContexts.sorted().joined(),
            selectedChannels.sorted().joined(),
            excludedChannels.sorted().joined(),
            selectedTags.sorted().joined(),
            excludedTags.sorted().joined()
        ]
        let state: [String] = [
            contactAge,
            String(eligibleOnly),
            String(includeArchived),
            sort,
            String(descending),
            String(unknownsFirst),
            selectedSavedViewID?.uuidString ?? "custom",
            String(store.people.count),
            String(canonicalFilters.hashValue)
        ]
        return ([searchText] + filterLabels + state).joined(separator: "|")
    }

    private func rebuildAndSearch() async {
        isIndexing = true
        indexProgress = nil
        defer {
            isIndexing = false
            indexProgress = nil
        }
        do {
            try Task.checkCancellation()
            let schema = FilterSchema.localSearchPerson(
                customAttributes: canonical.attributeDefinitions
            )
            let documents = CanonicalLocalSearchProjection().documents(
                people: store.people,
                canonical: canonicalArchivePayload,
                localeIdentifier: locale.identifier
            )
            let service: LocalSearch
            if let fileURL = store.localSearchIndexURL {
                let persistence = FileLocalSearchIndexPersistence(fileURL: fileURL)
                let prior = try await persistence.load()
                service = LocalSearch(
                    index: InMemoryLocalSearchIndex(persistence: persistence),
                    schema: schema
                )
                let outcome = try await service.restore()
                if case .restored = outcome, let prior {
                    let old = Dictionary(uniqueKeysWithValues: prior.documents.map { ($0.id, $0) })
                    let current = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
                    let changed = documents.filter { old[$0.id] != $0 }
                    let removed = Set(old.keys).subtracting(current.keys)
                    if !changed.isEmpty { try await service.upsert(changed) }
                    if !removed.isEmpty { try await service.remove(personIDs: removed) }
                    indexProgress = 1
                } else {
                    try await rebuild(service, from: documents)
                }
            } else {
                service = LocalSearch(schema: schema)
                try await rebuild(service, from: documents)
            }
            try Task.checkCancellation()
            searchService = service
            await runSearch()
        } catch is CancellationError {
            return
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func rebuild(_ service: LocalSearch, from documents: [LocalSearchDocument]) async throws {
        _ = try await service.rebuild(
            from: CollectionLocalSearchRebuildSource(documents: documents),
            batchSize: 500
        ) { progress in
            Task { @MainActor in indexProgress = progress.fractionCompleted }
        }
    }

    private func clearManualFiltersForSavedView() {
        selectedCircles.removeAll()
        selectedContexts.removeAll()
        excludedContexts.removeAll()
        selectedChannels.removeAll()
        excludedChannels.removeAll()
        selectedTags.removeAll()
        excludedTags.removeAll()
        canonicalFilters.clear()
        contactAge = DiscoveryContactAge.any.rawValue
        eligibleOnly = false
        sort = LocalSearchPersonField.name
        descending = false
        unknownsFirst = false
    }

    private func sanitizeDynamicSelections() {
        let options = canonicalFacetOptions
        let cohortIDs = Set(options.cohorts.map(\.id))
        canonicalFilters.selectedCohortIDs.formIntersection(cohortIDs)
        canonicalFilters.excludedCohortIDs.formIntersection(cohortIDs)
        let roles = Set(options.roles)
        canonicalFilters.selectedRoles.formIntersection(roles)
        canonicalFilters.excludedRoles.formIntersection(roles)
        let locations = Set(options.locations)
        canonicalFilters.selectedLocations.formIntersection(locations)
        canonicalFilters.excludedLocations.formIntersection(locations)
        canonicalFilters.selectedTimeZones.formIntersection(Set(options.timeZones))
        canonicalFilters.excludedTimeZones.formIntersection(Set(options.timeZones))
        canonicalFilters.selectedLanguages.formIntersection(Set(options.languages))
        canonicalFilters.excludedLanguages.formIntersection(Set(options.languages))
        let sourceIDs = Set(options.sources.map(\.id))
        canonicalFilters.selectedSourceIDs.formIntersection(sourceIDs)
        canonicalFilters.excludedSourceIDs.formIntersection(sourceIDs)

        let customFieldIDs = Set(options.customFields.map(\.id))
        canonicalFilters.customAvailability = canonicalFilters.customAvailability.filter {
            customFieldIDs.contains($0.key)
        }
        canonicalFilters.customBooleanValue = canonicalFilters.customBooleanValue.filter {
            customFieldIDs.contains($0.key)
        }
        canonicalFilters.customMinimum = canonicalFilters.customMinimum.filter {
            customFieldIDs.contains($0.key)
        }
        canonicalFilters.customMaximum = canonicalFilters.customMaximum.filter {
            customFieldIDs.contains($0.key)
        }
        canonicalFilters.customExactValue = canonicalFilters.customExactValue.filter {
            customFieldIDs.contains($0.key)
        }
        canonicalFilters.excludedCustomExactFields.formIntersection(customFieldIDs)
        canonicalFilters.customIncludedUUIDValues = canonicalFilters.customIncludedUUIDValues
            .filter { customFieldIDs.contains($0.key) }
        canonicalFilters.customExcludedUUIDValues = canonicalFilters.customExcludedUUIDValues
            .filter { customFieldIDs.contains($0.key) }
        for field in options.customFields {
            let validIDs = Set(field.options.map(\.id))
            canonicalFilters.customIncludedUUIDValues[field.id]?.formIntersection(validIDs)
            canonicalFilters.customExcludedUUIDValues[field.id]?.formIntersection(validIDs)
        }
        if let selectedSavedViewID,
           !canonical.activeSavedViews.contains(where: { $0.id == selectedSavedViewID }) {
            self.selectedSavedViewID = nil
        }
        if !sortOptions.contains(where: { $0.field == sort }) {
            sort = LocalSearchPersonField.name
        }
    }

    private var canonicalArchivePayload: CanonicalArchivePayload {
        CanonicalArchivePayload(
            contexts: canonical.contexts,
            cohortSchemes: canonical.cohortSchemes,
            cohorts: canonical.cohorts,
            memberships: canonical.memberships,
            cohortAssignments: canonical.cohortAssignments,
            roleDefinitions: canonical.roleDefinitions,
            roleAssignments: canonical.roleAssignments,
            education: canonical.education,
            assertions: canonical.assertions,
            sources: canonical.sources,
            artifactUnits: canonical.artifactUnits,
            portraitMedia: canonical.portraitMedia,
            evidence: canonical.evidence,
            reminders: canonical.reminders,
            commitments: canonical.commitments,
            savedViews: canonical.savedViews,
            attributeDefinitions: canonical.attributeDefinitions,
            textImportReviews: canonical.textImportReviews,
            personMergeEvents: canonical.personMergeEvents
        )
    }

    private var projectionRevision: String {
        "\(store.revision)|\(canonical.revision)|\(locale.identifier)"
    }

    private func runSearch() async {
        isSearching = true
        defer { isSearching = false }
        do {
            let page = try await searchService.search(query, page: .init(limit: 500))
            results = page.hits.compactMap { hit in
                store.person(id: hit.personID).map {
                    DiscoveryResult(person: $0, reasonLabels: reasonLabels(hit.matchReasons))
                }
            }
            totalCount = page.totalCount
            nextCursor = page.nextCursor
            searchError = nil
        } catch LocalSearchError.staleCursor {
            await rebuildAndSearch()
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func loadNextPage() async {
        guard let cursor = nextCursor, !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let page = try await searchService.search(
                query,
                page: .init(limit: 500, cursor: cursor)
            )
            let existingIDs = Set(results.map(\.id))
            results.append(contentsOf: page.hits.compactMap { hit in
                guard !existingIDs.contains(hit.personID) else { return nil }
                return store.person(id: hit.personID).map {
                    DiscoveryResult(
                        person: $0,
                        reasonLabels: reasonLabels(hit.matchReasons)
                    )
                }
            })
            totalCount = page.totalCount
            nextCursor = page.nextCursor
            searchError = nil
        } catch LocalSearchError.staleCursor {
            await rebuildAndSearch()
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func reasonLabels(_ reasons: [LocalSearchMatchReason]) -> [String] {
        var seen = Set<String>()
        return reasons.compactMap { reason in
            let label = discoveryFieldTitle(reason.fieldID)
            return seen.insert(label).inserted ? label : nil
        }
    }

    private func assertionFacetStrings(
        _ values: (TypedValue) -> [String]
    ) -> [String] {
        Set(canonical.assertions
            .filter {
                $0.reviewStatus == .accepted && $0.usePolicy.search == .include
            }
            .flatMap { values($0.value) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
            .sorted()
    }

    private func sourceTitle(_ source: SourceArtifact) -> String {
        if let filename = source.originalFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !filename.isEmpty {
            return filename
        }
        return sourceKindTitle(source.kind)
    }

    private func discoveryOptions(for definition: AttributeDefinition) -> [DiscoveryUUIDOption] {
        switch definition.valueKind {
        case .singleSelect, .multiSelect:
            return (definition.options ?? [])
                .filter { $0.archivedAt == nil }
                .sorted { $0.order < $1.order }
                .map { .init(
                    id: $0.id,
                    title: $0.label.resolved(preferredLanguageTags: [locale.identifier])
                ) }
        case .personReference:
            return store.people
                .filter { $0.deletedAt == nil && $0.mergedIntoPersonID == nil }
                .map { .init(id: $0.id, title: disambiguatedPersonLabel($0)) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .contextReference:
            return canonical.contexts
                .filter { $0.archivedAt == nil }
                .map { .init(
                    id: $0.id,
                    title: $0.names.resolved(preferredLanguageTags: [locale.identifier])
                ) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .mediaReference:
            return canonical.portraitMedia.map { asset in
                let personName = store.person(id: canonical.resolvedPersonID(asset.personID))?.displayName
                    ?? String(localized: "Unknown person")
                return .init(
                    id: asset.id,
                    title: "\(personName) · \(asset.id.uuidString.prefix(8))"
                )
            }
        default:
            return []
        }
    }

    private func disambiguatedPersonLabel(_ person: Person) -> String {
        var details: [String] = []
        if let alias = person.aliases.first { details.append(alias) }
        if let context = canonical.contexts(for: person.id).first?.names
            .resolved(preferredLanguageTags: [locale.identifier]) ?? person.contexts.first {
            details.append(context)
        }
        if let contact = person.preferredAvailableContactMethod {
            details.append("\(contact.kind.localizedTitle): \(contact.value)")
        }
        return details.isEmpty
            ? person.displayName
            : "\(person.displayName) — \(details.joined(separator: " · "))"
    }
}

private struct DiscoveryResult: Identifiable {
    let person: Person
    let reasonLabels: [String]
    var id: UUID { person.id }
}

private struct DiscoverySortOption: Identifiable, Hashable {
    let field: String
    let title: String
    var id: String { field }
}

private enum DiscoveryContactAge: String, CaseIterable, Identifiable {
    case any, over30, over90, over180, unknown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: String(localized: "Any last contact")
        case .over30: String(localized: "No contact for 30 days")
        case .over90: String(localized: "No contact for 90 days")
        case .over180: String(localized: "No contact for 6 months")
        case .unknown: String(localized: "No interaction recorded")
        }
    }
}

private struct DiscoveryUUIDOption: Identifiable, Hashable {
    let id: UUID
    let title: String
}

private struct DiscoveryCustomField: Identifiable, Hashable {
    let id: String
    let title: String
    let valueKind: AttributeValueKind
    let options: [DiscoveryUUIDOption]
}

private struct CanonicalDiscoveryFacetOptions: Hashable {
    let cohorts: [DiscoveryUUIDOption]
    let roles: [String]
    let locations: [String]
    let timeZones: [String]
    let languages: [String]
    let sources: [DiscoveryUUIDOption]
    let customFields: [DiscoveryCustomField]
}

private struct CanonicalDiscoveryFilterState: Hashable {
    var selectedCohortIDs: Set<UUID> = []
    var excludedCohortIDs: Set<UUID> = []
    var selectedMembershipStatuses: Set<String> = []
    var excludedMembershipStatuses: Set<String> = []
    var selectedRoles: Set<String> = []
    var excludedRoles: Set<String> = []
    var selectedEducationStatuses: Set<String> = []
    var excludedEducationStatuses: Set<String> = []
    var graduationFilter = DiscoveryDateFilter.any.rawValue
    var graduationStartYear = Calendar.current.component(.year, from: .now) - 10
    var graduationEndYear = Calendar.current.component(.year, from: .now) + 5
    var selectedLocations: Set<String> = []
    var excludedLocations: Set<String> = []
    var selectedTimeZones: Set<String> = []
    var excludedTimeZones: Set<String> = []
    var selectedLanguages: Set<String> = []
    var excludedLanguages: Set<String> = []
    var selectedRelativeCohortPositions: Set<String> = []
    var excludedRelativeCohortPositions: Set<String> = []
    var maximumCohortDistanceEnabled = false
    var maximumCohortDistance = 1
    var selectedSourceIDs: Set<UUID> = []
    var excludedSourceIDs: Set<UUID> = []
    var selectedReviewStatuses: Set<String> = []
    var excludedReviewStatuses: Set<String> = []
    var selectedSensitivities: Set<String> = []
    var excludedSensitivities: Set<String> = []
    var confidenceRangeEnabled = false
    var minimumConfidence = 0.0
    var maximumConfidence = 1.0
    var assertionFreshness = DiscoveryFreshnessFilter.any.rawValue
    var customAvailability: [String: String] = [:]
    var customBooleanValue: [String: String] = [:]
    var customMinimum: [String: String] = [:]
    var customMaximum: [String: String] = [:]
    var customExactValue: [String: String] = [:]
    var excludedCustomExactFields: Set<String> = []
    var customIncludedUUIDValues: [String: Set<UUID>] = [:]
    var customExcludedUUIDValues: [String: Set<UUID>] = [:]

    var isEmpty: Bool {
        selectedCohortIDs.isEmpty && excludedCohortIDs.isEmpty &&
            selectedMembershipStatuses.isEmpty && excludedMembershipStatuses.isEmpty &&
            selectedRoles.isEmpty && excludedRoles.isEmpty &&
            selectedEducationStatuses.isEmpty && excludedEducationStatuses.isEmpty &&
            graduationFilter == DiscoveryDateFilter.any.rawValue &&
            selectedLocations.isEmpty && excludedLocations.isEmpty &&
            selectedTimeZones.isEmpty && excludedTimeZones.isEmpty &&
            selectedLanguages.isEmpty && excludedLanguages.isEmpty &&
            selectedRelativeCohortPositions.isEmpty && excludedRelativeCohortPositions.isEmpty &&
            !maximumCohortDistanceEnabled &&
            selectedSourceIDs.isEmpty && excludedSourceIDs.isEmpty &&
            selectedReviewStatuses.isEmpty && excludedReviewStatuses.isEmpty &&
            selectedSensitivities.isEmpty && excludedSensitivities.isEmpty &&
            !confidenceRangeEnabled &&
            assertionFreshness == DiscoveryFreshnessFilter.any.rawValue &&
            !customAvailability.values.contains { $0 != DiscoveryAvailabilityFilter.any.rawValue } &&
            !customBooleanValue.values.contains { $0 == "true" || $0 == "false" } &&
            !customMinimum.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
            !customMaximum.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
            !customExactValue.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
            !customIncludedUUIDValues.values.contains { !$0.isEmpty } &&
            !customExcludedUUIDValues.values.contains { !$0.isEmpty }
    }

    mutating func clear() {
        self = CanonicalDiscoveryFilterState()
    }
}

private enum DiscoveryDateFilter: String, CaseIterable, Identifiable {
    case any, known, unknown, range
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: String(localized: "Any date")
        case .known: String(localized: "Known date")
        case .unknown: String(localized: "Unknown date")
        case .range: String(localized: "Year range")
        }
    }
}

private enum DiscoveryFreshnessFilter: String, CaseIterable, Identifiable {
    case any, recent30, recent90, recent365, older365, unknown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: String(localized: "Any assertion date")
        case .recent30: String(localized: "Asserted in the last 30 days")
        case .recent90: String(localized: "Asserted in the last 90 days")
        case .recent365: String(localized: "Asserted in the last year")
        case .older365: String(localized: "Asserted more than a year ago")
        case .unknown: String(localized: "No assertions")
        }
    }
}

private enum DiscoveryAvailabilityFilter: String, CaseIterable, Identifiable {
    case any, known, unknown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: String(localized: "Any availability")
        case .known: String(localized: "Has a value")
        case .unknown: String(localized: "No value")
        }
    }
}

private struct PeopleFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contexts: [String]
    let tags: [String]
    let channels: [String]
    @Binding var selectedCircles: Set<String>
    @Binding var selectedContexts: Set<String>
    @Binding var excludedContexts: Set<String>
    @Binding var selectedChannels: Set<String>
    @Binding var excludedChannels: Set<String>
    @Binding var selectedTags: Set<String>
    @Binding var excludedTags: Set<String>
    @Binding var canonicalFilters: CanonicalDiscoveryFilterState
    let canonicalOptions: CanonicalDiscoveryFacetOptions
    @Binding var contactAge: String
    @Binding var eligibleOnly: Bool
    @Binding var includeArchived: Bool
    @State private var showAdvancedFilters = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Filter detail") {
                    Toggle("Show advanced structure and provenance filters", isOn: $showAdvancedFilters)
                    Text("Everyday filters stay short. Advanced mode adds cohorts, education, relative position, sources, assertion policy, and custom fields.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Section("Relationship circle — match any") {
                    ForEach(RelationshipCircle.allCases) { circle in
                        selectionToggle(
                            circle.rawValue,
                            title: circle.localizedTitle,
                            set: $selectedCircles
                        )
                    }
                }
                if !contexts.isEmpty {
                    Section("Contexts — match any") {
                        ForEach(contexts, id: \.self) {
                            selectionToggle(
                                $0,
                                set: $selectedContexts,
                                removingFrom: $excludedContexts
                            )
                        }
                    }
                    Section("Exclude contexts") {
                        ForEach(contexts, id: \.self) {
                            selectionToggle(
                                $0,
                                set: $excludedContexts,
                                removingFrom: $selectedContexts
                            )
                        }
                    }
                }
                if showAdvancedFilters, !canonicalOptions.cohorts.isEmpty {
                    Section("Cohorts — match any") {
                        ForEach(canonicalOptions.cohorts) { option in
                            selectionToggle(
                                option,
                                set: $canonicalFilters.selectedCohortIDs,
                                removingFrom: $canonicalFilters.excludedCohortIDs
                            )
                        }
                    }
                    Section("Exclude cohorts") {
                        ForEach(canonicalOptions.cohorts) { option in
                            selectionToggle(
                                option,
                                set: $canonicalFilters.excludedCohortIDs,
                                removingFrom: $canonicalFilters.selectedCohortIDs
                            )
                        }
                    }
                }
                if showAdvancedFilters {
                Section("Membership status — match any") {
                    ForEach(MembershipStatus.allCases, id: \.rawValue) { status in
                        selectionToggle(
                            status.rawValue,
                            title: membershipStatusTitle(status),
                            set: $canonicalFilters.selectedMembershipStatuses,
                            removingFrom: $canonicalFilters.excludedMembershipStatuses
                        )
                    }
                }
                Section("Exclude membership statuses") {
                    ForEach(MembershipStatus.allCases, id: \.rawValue) { status in
                        selectionToggle(
                            status.rawValue,
                            title: membershipStatusTitle(status),
                            set: $canonicalFilters.excludedMembershipStatuses,
                            removingFrom: $canonicalFilters.selectedMembershipStatuses
                        )
                    }
                }
                if !canonicalOptions.roles.isEmpty {
                    Section("Roles — match any") {
                        ForEach(canonicalOptions.roles, id: \.self) {
                            selectionToggle(
                                $0,
                                set: $canonicalFilters.selectedRoles,
                                removingFrom: $canonicalFilters.excludedRoles
                            )
                        }
                    }
                    Section("Exclude roles") {
                        ForEach(canonicalOptions.roles, id: \.self) {
                            selectionToggle(
                                $0,
                                set: $canonicalFilters.excludedRoles,
                                removingFrom: $canonicalFilters.selectedRoles
                            )
                        }
                    }
                }
                Section("Education status — match any") {
                    ForEach(EducationStatus.allCases, id: \.rawValue) { status in
                        selectionToggle(
                            status.rawValue,
                            title: educationStatusTitle(status),
                            set: $canonicalFilters.selectedEducationStatuses,
                            removingFrom: $canonicalFilters.excludedEducationStatuses
                        )
                    }
                }
                Section("Exclude education statuses") {
                    ForEach(EducationStatus.allCases, id: \.rawValue) { status in
                        selectionToggle(
                            status.rawValue,
                            title: educationStatusTitle(status),
                            set: $canonicalFilters.excludedEducationStatuses,
                            removingFrom: $canonicalFilters.selectedEducationStatuses
                        )
                    }
                }
                Section("Actual graduation") {
                    Picker("Date availability", selection: $canonicalFilters.graduationFilter) {
                        ForEach(DiscoveryDateFilter.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if canonicalFilters.graduationFilter == DiscoveryDateFilter.range.rawValue {
                        Stepper(
                            "From year: \(canonicalFilters.graduationStartYear)",
                            value: $canonicalFilters.graduationStartYear,
                            in: 1800...canonicalFilters.graduationEndYear
                        )
                        Stepper(
                            "Through year: \(canonicalFilters.graduationEndYear)",
                            value: $canonicalFilters.graduationEndYear,
                            in: canonicalFilters.graduationStartYear...(Calendar.current.component(.year, from: .now) + 20)
                        )
                    }
                }
                if !canonicalOptions.locations.isEmpty {
                    Section("Locations — match any") {
                        ForEach(canonicalOptions.locations, id: \.self) {
                            selectionToggle(
                                $0,
                                set: $canonicalFilters.selectedLocations,
                                removingFrom: $canonicalFilters.excludedLocations
                            )
                        }
                    }
                    Section("Exclude locations") {
                        ForEach(canonicalOptions.locations, id: \.self) {
                            selectionToggle(
                                $0,
                                set: $canonicalFilters.excludedLocations,
                                removingFrom: $canonicalFilters.selectedLocations
                            )
                        }
                    }
                }
                if !canonicalOptions.timeZones.isEmpty {
                    Section("Time zones — match any") {
                        ForEach(canonicalOptions.timeZones, id: \.self) {
                            selectionToggle(
                                $0,
                                set: $canonicalFilters.selectedTimeZones,
                                removingFrom: $canonicalFilters.excludedTimeZones
                            )
                        }
                    }
                    Section("Exclude time zones") {
                        ForEach(canonicalOptions.timeZones, id: \.self) {
                            selectionToggle(
                                $0,
                                set: $canonicalFilters.excludedTimeZones,
                                removingFrom: $canonicalFilters.selectedTimeZones
                            )
                        }
                    }
                }
                if !canonicalOptions.languages.isEmpty {
                    Section("Languages — match any") {
                        ForEach(canonicalOptions.languages, id: \.self) {
                            selectionToggle(
                                $0,
                                set: $canonicalFilters.selectedLanguages,
                                removingFrom: $canonicalFilters.excludedLanguages
                            )
                        }
                    }
                    Section("Exclude languages") {
                        ForEach(canonicalOptions.languages, id: \.self) {
                            selectionToggle(
                                $0,
                                set: $canonicalFilters.excludedLanguages,
                                removingFrom: $canonicalFilters.selectedLanguages
                            )
                        }
                    }
                }
                }
                if !channels.isEmpty {
                    Section("Channels — match any") {
                        ForEach(channels, id: \.self) { channel in
                            selectionToggle(
                                channel,
                                title: ContactKind(rawValue: channel)?.localizedTitle ?? channel,
                                set: $selectedChannels,
                                removingFrom: $excludedChannels
                            )
                        }
                    }
                    Section("Exclude channels") {
                        ForEach(channels, id: \.self) { channel in
                            selectionToggle(
                                channel,
                                title: ContactKind(rawValue: channel)?.localizedTitle ?? channel,
                                set: $excludedChannels,
                                removingFrom: $selectedChannels
                            )
                        }
                    }
                }
                if !tags.isEmpty {
                    Section("Tags — match any") {
                        ForEach(tags, id: \.self) {
                            selectionToggle($0, set: $selectedTags, removingFrom: $excludedTags)
                        }
                    }
                    Section("Exclude tags") {
                        ForEach(tags, id: \.self) {
                            selectionToggle($0, set: $excludedTags, removingFrom: $selectedTags)
                        }
                    }
                }
                if showAdvancedFilters {
                Section("Relative to Me") {
                    ForEach(RelativeCohortPosition.allCases.filter { $0 != .unknown }, id: \.rawValue) {
                        position in
                        selectionToggle(
                            position.rawValue,
                            title: relativeCohortPositionTitle(position),
                            set: $canonicalFilters.selectedRelativeCohortPositions,
                            removingFrom: $canonicalFilters.excludedRelativeCohortPositions
                        )
                    }
                    Toggle("Limit cohort distance", isOn: $canonicalFilters.maximumCohortDistanceEnabled)
                    if canonicalFilters.maximumCohortDistanceEnabled {
                        Stepper(
                            "Within \(canonicalFilters.maximumCohortDistance) cohort(s)",
                            value: $canonicalFilters.maximumCohortDistance,
                            in: 0...100
                        )
                    }
                    Text("Available after one active person is marked as Me and both people have comparable dated cohort memberships.")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                if !canonicalOptions.sources.isEmpty {
                    Section("Sources — match any") {
                        ForEach(canonicalOptions.sources) { option in
                            selectionToggle(
                                option,
                                set: $canonicalFilters.selectedSourceIDs,
                                removingFrom: $canonicalFilters.excludedSourceIDs
                            )
                        }
                    }
                    Section("Exclude sources") {
                        ForEach(canonicalOptions.sources) { option in
                            selectionToggle(
                                option,
                                set: $canonicalFilters.excludedSourceIDs,
                                removingFrom: $canonicalFilters.selectedSourceIDs
                            )
                        }
                    }
                }
                Section("Assertion review status — match any") {
                    ForEach(AssertionReviewStatus.allCases, id: \.rawValue) { status in
                        selectionToggle(
                            status.rawValue,
                            title: assertionReviewStatusTitle(status),
                            set: $canonicalFilters.selectedReviewStatuses,
                            removingFrom: $canonicalFilters.excludedReviewStatuses
                        )
                    }
                }
                Section("Exclude assertion review statuses") {
                    ForEach(AssertionReviewStatus.allCases, id: \.rawValue) { status in
                        selectionToggle(
                            status.rawValue,
                            title: assertionReviewStatusTitle(status),
                            set: $canonicalFilters.excludedReviewStatuses,
                            removingFrom: $canonicalFilters.selectedReviewStatuses
                        )
                    }
                }
                Section("Assertion sensitivity — match any") {
                    ForEach(Sensitivity.allCases, id: \.rawValue) { sensitivity in
                        selectionToggle(
                            sensitivity.rawValue,
                            title: sensitivityTitle(sensitivity),
                            set: $canonicalFilters.selectedSensitivities,
                            removingFrom: $canonicalFilters.excludedSensitivities
                        )
                    }
                }
                Section("Exclude assertion sensitivities") {
                    ForEach(Sensitivity.allCases, id: \.rawValue) { sensitivity in
                        selectionToggle(
                            sensitivity.rawValue,
                            title: sensitivityTitle(sensitivity),
                            set: $canonicalFilters.excludedSensitivities,
                            removingFrom: $canonicalFilters.selectedSensitivities
                        )
                    }
                }
                Section("Assertion confidence") {
                    Toggle("Use confidence range", isOn: $canonicalFilters.confidenceRangeEnabled)
                    if canonicalFilters.confidenceRangeEnabled {
                        LabeledContent(
                            "Minimum",
                            value: canonicalFilters.minimumConfidence.formatted(.percent.precision(.fractionLength(0)))
                        )
                        Slider(
                            value: $canonicalFilters.minimumConfidence,
                            in: 0...canonicalFilters.maximumConfidence
                        )
                        LabeledContent(
                            "Maximum",
                            value: canonicalFilters.maximumConfidence.formatted(.percent.precision(.fractionLength(0)))
                        )
                        Slider(
                            value: $canonicalFilters.maximumConfidence,
                            in: canonicalFilters.minimumConfidence...1
                        )
                    }
                    Picker("Assertion age", selection: $canonicalFilters.assertionFreshness) {
                        ForEach(DiscoveryFreshnessFilter.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                ForEach(canonicalOptions.customFields) { field in
                    Section(field.title) {
                        Picker("Availability", selection: customAvailabilityBinding(field.id)) {
                            ForEach(DiscoveryAvailabilityFilter.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        customValueControls(field)
                    }
                }
                }
                Section("Contact timing") {
                    Picker("Last interaction", selection: $contactAge) {
                        ForEach(DiscoveryContactAge.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Toggle("Eligible for nudges", isOn: $eligibleOnly)
                    Toggle("Include archived people", isOn: $includeArchived)
                }
                Section {
                    Button("Clear all filters") {
                        selectedCircles.removeAll(); selectedContexts.removeAll(); excludedContexts.removeAll()
                        selectedChannels.removeAll(); excludedChannels.removeAll()
                        selectedTags.removeAll(); excludedTags.removeAll(); contactAge = DiscoveryContactAge.any.rawValue
                        canonicalFilters.clear()
                        eligibleOnly = false; includeArchived = false
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Filter People")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .keepsakeSheetSize(minWidth: 520, minHeight: 650)
    }

    @ViewBuilder
    private func customValueControls(_ field: DiscoveryCustomField) -> some View {
        switch field.valueKind {
        case .boolean:
            Picker("Value", selection: customBooleanBinding(field.id)) {
                Text("Any value").tag("any")
                Text("Yes").tag("true")
                Text("No").tag("false")
            }
        case .number:
            TextField("Minimum", text: customMinimumBinding(field.id))
            TextField("Maximum", text: customMaximumBinding(field.id))
        case .partialDate, .dateRange:
            TextField("From year", text: customMinimumBinding(field.id))
            TextField("Through year", text: customMaximumBinding(field.id))
        case .text, .richText, .language, .url, .email, .phone, .location, .address:
            TextField("Exact value", text: customExactBinding(field.id))
            Toggle("Exclude this value", isOn: Binding(
                get: { canonicalFilters.excludedCustomExactFields.contains(field.id) },
                set: { excluded in
                    if excluded { canonicalFilters.excludedCustomExactFields.insert(field.id) }
                    else { canonicalFilters.excludedCustomExactFields.remove(field.id) }
                }
            ))
        case .singleSelect, .multiSelect, .personReference,
             .contextReference, .mediaReference:
            if field.options.isEmpty {
                Text("No selectable values are available yet.")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
            } else {
                Text("Include any")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                ForEach(field.options) { option in
                    selectionToggle(
                        option,
                        set: customUUIDBinding(field.id, excluded: false),
                        removingFrom: customUUIDBinding(field.id, excluded: true)
                    )
                }
                DisclosureGroup("Exclude values") {
                    ForEach(field.options) { option in
                        selectionToggle(
                            option,
                            set: customUUIDBinding(field.id, excluded: true),
                            removingFrom: customUUIDBinding(field.id, excluded: false)
                        )
                    }
                }
            }
        case .structuredJSON:
            Text("This field supports known or unknown filtering here.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private func customAvailabilityBinding(_ fieldID: String) -> Binding<String> {
        Binding(
            get: {
                canonicalFilters.customAvailability[fieldID]
                    ?? DiscoveryAvailabilityFilter.any.rawValue
            },
            set: { canonicalFilters.customAvailability[fieldID] = $0 }
        )
    }

    private func customBooleanBinding(_ fieldID: String) -> Binding<String> {
        Binding(
            get: { canonicalFilters.customBooleanValue[fieldID] ?? "any" },
            set: { canonicalFilters.customBooleanValue[fieldID] = $0 }
        )
    }

    private func customMinimumBinding(_ fieldID: String) -> Binding<String> {
        Binding(
            get: { canonicalFilters.customMinimum[fieldID] ?? "" },
            set: { canonicalFilters.customMinimum[fieldID] = $0 }
        )
    }

    private func customMaximumBinding(_ fieldID: String) -> Binding<String> {
        Binding(
            get: { canonicalFilters.customMaximum[fieldID] ?? "" },
            set: { canonicalFilters.customMaximum[fieldID] = $0 }
        )
    }

    private func customExactBinding(_ fieldID: String) -> Binding<String> {
        Binding(
            get: { canonicalFilters.customExactValue[fieldID] ?? "" },
            set: { canonicalFilters.customExactValue[fieldID] = $0 }
        )
    }

    private func customUUIDBinding(_ fieldID: String, excluded: Bool) -> Binding<Set<UUID>> {
        Binding(
            get: {
                if excluded { return canonicalFilters.customExcludedUUIDValues[fieldID] ?? [] }
                return canonicalFilters.customIncludedUUIDValues[fieldID] ?? []
            },
            set: { values in
                if excluded { canonicalFilters.customExcludedUUIDValues[fieldID] = values }
                else { canonicalFilters.customIncludedUUIDValues[fieldID] = values }
            }
        )
    }

    private func selectionToggle(
        _ value: String,
        title: String? = nil,
        set: Binding<Set<String>>,
        removingFrom opposite: Binding<Set<String>>? = nil
    ) -> some View {
        Toggle(title ?? value, isOn: Binding(
            get: { set.wrappedValue.contains(value) },
            set: { selected in
                if selected {
                    set.wrappedValue.insert(value)
                    opposite?.wrappedValue.remove(value)
                } else {
                    set.wrappedValue.remove(value)
                }
            }
        ))
    }

    private func selectionToggle(
        _ option: DiscoveryUUIDOption,
        set: Binding<Set<UUID>>,
        removingFrom opposite: Binding<Set<UUID>>? = nil
    ) -> some View {
        Toggle(option.title, isOn: Binding(
            get: { set.wrappedValue.contains(option.id) },
            set: { selected in
                if selected {
                    set.wrappedValue.insert(option.id)
                    opposite?.wrappedValue.remove(option.id)
                } else {
                    set.wrappedValue.remove(option.id)
                }
            }
        ))
    }
}

private struct SaveDiscoveryViewSheet: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss
    let filter: FilterNode
    let sorts: [SortSpecification]
    @State private var name = ""
    @State private var nudgePool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("View name", text: $name)
                Toggle("Available as a nudge pool", isOn: $nudgePool)
                Text("Saved views are live: membership updates whenever a person changes. The structured filter remains editable and portable.")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            .formStyle(.grouped)
            .navigationTitle("Save View")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try canonical.saveSavedView(SavedView(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                filter: filter,
                                sorts: sorts,
                                isEligibleNudgePool: nudgePool,
                                displayOrder: canonical.activeSavedViews.count
                            ))
                            dismiss()
                        } catch {
                            errorMessage = (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .keepsakeSheetSize(minWidth: 440, minHeight: 300)
        .alert("Saved view could not be saved", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct SavedViewsManagerSheet: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var includeArchived = false
    @State private var editingView: SavedView?
    @State private var duplicatingView: SavedView?
    @State private var errorMessage: String?

    private var visibleViews: [SavedView] {
        canonical.savedViews.filter { includeArchived || !$0.isArchived }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Show archived saved views", isOn: $includeArchived)
                }
                Section("Saved Views") {
                    if visibleViews.isEmpty {
                        ContentUnavailableView(
                            "No saved views",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("Save a People query to manage it here.")
                        )
                    }
                    ForEach(visibleViews) { view in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(view.name).font(.headline)
                                if view.isArchived { Label("Archived", systemImage: "archivebox") }
                                if view.isEligibleNudgePool { Label("Nudge pool", systemImage: "sparkles") }
                                Spacer()
                                Menu {
                                    Button("Edit…") { editingView = view }
                                    Button("Duplicate…") { duplicatingView = view }
                                    Button(view.isArchived ? "Restore" : "Archive") {
                                        updateArchiveState(view)
                                    }
                                    Divider()
                                    Button("Move Up") { move(view, offset: -1) }
                                        .disabled(view.isArchived)
                                    Button("Move Down") { move(view, offset: 1) }
                                        .disabled(view.isArchived)
                                    Divider()
                                    Button("Move to Recently Deleted", role: .destructive) {
                                        canonical.delete(view, kind: "savedView")
                                    }
                                } label: {
                                    Label("Manage \(view.name)", systemImage: "ellipsis.circle")
                                }
                                .labelStyle(.iconOnly)
                            }
                            Text(savedViewCriteriaSummary(view))
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .textSelection(.enabled)
                            Text("Updated \(view.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(AppTheme.tertiaryText)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Manage Saved Views")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheet(item: $editingView) { SavedViewEditorSheet(view: $0, duplicates: false) }
        .sheet(item: $duplicatingView) { SavedViewEditorSheet(view: $0, duplicates: true) }
        .alert("Saved view needs attention", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .keepsakeSheetSize(minWidth: 620, minHeight: 620)
    }

    private func updateArchiveState(_ original: SavedView) {
        var view = original
        view.archivedAt = original.isArchived ? nil : .now
        view.modifiedAt = .now
        do { try canonical.saveSavedView(view) }
        catch { errorMessage = error.localizedDescription }
    }

    private func move(_ view: SavedView, offset: Int) {
        var active = canonical.activeSavedViews
        guard let index = active.firstIndex(where: { $0.id == view.id }) else { return }
        let destination = index + offset
        guard active.indices.contains(destination) else { return }
        active.swapAt(index, destination)
        do { try canonical.reorderSavedViews(active.map(\.id)) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct SavedViewEditorSheet: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss
    let original: SavedView
    let duplicates: Bool
    @State private var name: String
    @State private var nudgePool: Bool
    @State private var errorMessage: String?

    init(view: SavedView, duplicates: Bool) {
        original = view
        self.duplicates = duplicates
        _name = State(initialValue: duplicates
            ? String(localized: "\(view.name) Copy")
            : view.name)
        _nudgePool = State(initialValue: view.isEligibleNudgePool)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("View name", text: $name)
                Toggle("Available as a nudge pool", isOn: $nudgePool)
                LabeledContent("Criteria", value: savedViewCriteriaSummary(original))
            }
            .formStyle(.grouped)
            .navigationTitle(duplicates ? "Duplicate Saved View" : "Edit Saved View")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert("Saved view could not be saved", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .keepsakeSheetSize(minWidth: 480, minHeight: 360)
    }

    private func save() {
        do {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let view: SavedView
            if duplicates {
                view = SavedView(
                    name: trimmed,
                    filterVersion: original.filterVersion,
                    filter: original.filter,
                    sorts: original.sorts,
                    isEligibleNudgePool: nudgePool,
                    displayOrder: canonical.activeSavedViews.count
                )
            } else {
                var copy = original
                copy.name = trimmed
                copy.isEligibleNudgePool = nudgePool
                copy.modifiedAt = .now
                view = copy
            }
            try canonical.saveSavedView(view)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private func savedViewCriteriaSummary(_ view: SavedView) -> String {
    let filter = filterNodeSummary(view.filter)
    let sorts = view.sorts.map { sort in
        let direction = sort.direction == .ascending ? String(localized: "ascending") : String(localized: "descending")
        return "\(discoveryFieldTitle(sort.field)) \(direction)"
    }.joined(separator: ", ")
    return sorts.isEmpty ? filter : "\(filter); \(String(localized: "sort")): \(sorts)"
}

private func filterNodeSummary(_ node: FilterNode) -> String {
    switch node {
    case .and(let children):
        return children.map(filterNodeSummary).joined(separator: String(localized: " AND "))
    case .or(let children):
        return "(" + children.map(filterNodeSummary).joined(separator: String(localized: " OR ")) + ")"
    case .not(let child):
        return String(localized: "NOT \(filterNodeSummary(child))")
    case .condition(let condition):
        let value = condition.value.map(filterValueSummary) ?? String(localized: "no value")
        return "\(discoveryFieldTitle(condition.field)) \(condition.operator.rawValue) \(value)"
    }
}

private func filterValueSummary(_ value: FilterValue) -> String {
    switch value {
    case .string(let value): return value
    case .strings(let values): return values.joined(separator: ", ")
    case .boolean(let value): return value ? String(localized: "yes") : String(localized: "no")
    case .integer(let value): return value.formatted()
    case .number(let value): return value.formatted()
    case .uuid(let value): return value.uuidString
    case .uuids(let values): return values.map(\.uuidString).joined(separator: ", ")
    case .instant(let value): return value.formatted(date: .abbreviated, time: .shortened)
    case .partialDate(let value): return value.description
    case .dateRange(let value):
        return "\(value.start?.description ?? "…")–\(value.end?.description ?? "…")"
    }
}

private func relativeCohortPositionTitle(_ position: RelativeCohortPosition) -> String {
    switch position {
    case .earlier: String(localized: "Earlier cohort")
    case .peer: String(localized: "Same cohort")
    case .later: String(localized: "Later cohort")
    case .unknown: String(localized: "Unknown cohort relationship")
    }
}

private func discoveryFieldTitle(_ field: String) -> String {
    switch field {
    case LocalSearchPersonField.name: String(localized: "name")
    case LocalSearchPersonField.pronunciation: String(localized: "pronunciation")
    case LocalSearchPersonField.alias: String(localized: "alias")
    case LocalSearchPersonField.context: String(localized: "context")
    case LocalSearchPersonField.cohort: String(localized: "cohort")
    case LocalSearchPersonField.membershipStatus: String(localized: "membership status")
    case LocalSearchPersonField.role: String(localized: "role")
    case LocalSearchPersonField.educationStatus: String(localized: "education status")
    case LocalSearchPersonField.educationGraduation: String(localized: "actual graduation")
    case LocalSearchPersonField.location: String(localized: "location")
    case LocalSearchPersonField.timeZone: String(localized: "time zone")
    case LocalSearchPersonField.language: String(localized: "language")
    case LocalSearchPersonField.tag: String(localized: "tag")
    case LocalSearchPersonField.channel: String(localized: "channel")
    case LocalSearchPersonField.relationshipCircle: String(localized: "relationship circle")
    case LocalSearchPersonField.lastInteractionAt: String(localized: "last interaction")
    case LocalSearchPersonField.nextCadenceDue: String(localized: "next contact due")
    case LocalSearchPersonField.nudgeEligible: String(localized: "nudge eligibility")
    case LocalSearchPersonField.source: String(localized: "source")
    case LocalSearchPersonField.assertionReviewStatus: String(localized: "assertion review status")
    case LocalSearchPersonField.assertionConfidence: String(localized: "assertion confidence")
    case LocalSearchPersonField.assertionSensitivity: String(localized: "assertion sensitivity")
    case LocalSearchPersonField.assertionFreshness: String(localized: "assertion date")
    default: String(localized: "approved searchable field")
    }
}

private func membershipStatusTitle(_ status: MembershipStatus) -> String {
    switch status {
    case .active: String(localized: "Active")
    case .completed: String(localized: "Completed")
    case .withdrawn: String(localized: "Withdrawn")
    case .transferred: String(localized: "Transferred")
    case .suspended: String(localized: "Suspended")
    case .unknown: String(localized: "Unknown")
    }
}

private func educationStatusTitle(_ status: EducationStatus) -> String {
    switch status {
    case .prospective: String(localized: "Prospective")
    case .enrolled: String(localized: "Enrolled")
    case .leaveOfAbsence: String(localized: "Leave of absence")
    case .completed: String(localized: "Completed")
    case .withdrawn: String(localized: "Withdrawn")
    case .graduated: String(localized: "Graduated (explicit)")
    case .unknown: String(localized: "Unknown")
    }
}

private func assertionReviewStatusTitle(_ status: AssertionReviewStatus) -> String {
    switch status {
    case .pending: String(localized: "Pending review")
    case .accepted: String(localized: "Accepted")
    case .rejected: String(localized: "Rejected")
    case .deferred: String(localized: "Deferred")
    case .conflicted: String(localized: "Conflict")
    }
}

private func sensitivityTitle(_ sensitivity: Sensitivity) -> String {
    switch sensitivity {
    case .ordinary: String(localized: "Ordinary")
    case .private: String(localized: "Private")
    case .sensitive: String(localized: "Sensitive")
    case .highlySensitive: String(localized: "Highly sensitive")
    }
}

private func sourceKindTitle(_ kind: SourceArtifactKind) -> String {
    switch kind {
    case .pdf: String(localized: "PDF")
    case .image: String(localized: "Image")
    case .screenshot: String(localized: "Screenshot")
    case .pastedText: String(localized: "Pasted text")
    case .json: String(localized: "JSON")
    case .exportedConversation: String(localized: "Exported conversation")
    case .selfProfileCard: String(localized: "Self-profile card")
    case .contactRecord: String(localized: "Contact record")
    case .userNote: String(localized: "Manual source note")
    case .other: String(localized: "Other source")
    }
}

private struct LocalPeopleQueryInterpretation: Equatable {
    var searchTerms = ""
    var includedContexts: Set<String> = []
    var excludedContexts: Set<String> = []
    var includedTags: Set<String> = []
    var excludedTags: Set<String> = []
    var includedChannels: Set<String> = []
    var excludedChannels: Set<String> = []
    var includeArchived = false
    var eligibleOnly = false
    var contactAge = DiscoveryContactAge.any
    var recognized: [String] = []

    static func parse(
        _ source: String,
        contexts: [String],
        tags: [String],
        channels: [String]
    ) -> Self {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = SearchNormalizer.normalize(trimmed)
        var result = Self()

        if ["archived people", "include archived", "アーカイブ済みの人", "アーカイブを含む"].contains(normalized) {
            result.includeArchived = true
            result.recognized.append(String(localized: "Include archived people"))
            return result
        }
        if [
            "people due for contact",
            "people eligible for a suggestion",
            "連絡時期の人",
            "つながりの提案対象の人"
        ].contains(normalized) {
            result.eligibleOnly = true
            result.recognized.append(String(localized: "Eligible for a connection suggestion"))
            return result
        }
        let naturalAge: [(phrases: [String], value: DiscoveryContactAge)] = [
            (["people not contacted in 30 days", "no contact for 30 days", "30日間連絡していない人"], .over30),
            (["people not contacted in 90 days", "no contact for 90 days", "90日間連絡していない人"], .over90),
            (["people not contacted in 180 days", "no contact for 6 months", "6か月連絡していない人"], .over180),
            (["people i have never contacted", "no interaction recorded", "交流記録がない人"], .unknown)
        ]
        if let match = naturalAge.first(where: { $0.phrases.contains(normalized) }) {
            result.contactAge = match.value
            result.recognized.append(match.value.title)
            return result
        }
        if let value = naturalValue(in: normalized, prefix: "people tagged ", options: tags) {
            result.includedTags.insert(value)
            result.recognized.append(String(localized: "Tag: \(value)"))
            return result
        }
        if let value = naturalValue(in: normalized, prefix: "タグ付きの人 ", options: tags) {
            result.includedTags.insert(value)
            result.recognized.append(String(localized: "Tag: \(value)"))
            return result
        }
        if let value = naturalValue(in: normalized, prefix: "people in ", options: contexts) {
            result.includedContexts.insert(value)
            result.recognized.append(String(localized: "Context: \(value)"))
            return result
        }
        if let value = naturalValue(in: normalized, prefix: "コンテキスト ", options: contexts) {
            result.includedContexts.insert(value)
            result.recognized.append(String(localized: "Context: \(value)"))
            return result
        }
        for prefix in ["people reachable by ", "people who prefer "] {
            if let value = naturalValue(in: normalized, prefix: prefix, options: channels) {
                result.includedChannels.insert(value)
                result.recognized.append(String(localized: "Channel: \(value)"))
                return result
            }
        }

        var freeTerms: [String] = []
        for token in quotedTokens(in: trimmed) {
            var candidate = token
            let excluded = candidate.hasPrefix("-")
            if excluded { candidate.removeFirst() }
            let pair = candidate.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else {
                freeTerms.append(token)
                continue
            }
            let key = SearchNormalizer.normalize(pair[0])
            let rawValue = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let truth = ["true", "yes", "1"].contains(SearchNormalizer.normalize(rawValue))
            switch key {
            case "tag":
                guard let value = closest(rawValue, in: tags) else { freeTerms.append(token); continue }
                if excluded { result.excludedTags.insert(value) }
                else { result.includedTags.insert(value) }
                result.recognized.append(String(localized: "\(excluded ? "Exclude tag" : "Tag"): \(value)"))
            case "context":
                guard let value = closest(rawValue, in: contexts) else { freeTerms.append(token); continue }
                if excluded { result.excludedContexts.insert(value) }
                else { result.includedContexts.insert(value) }
                result.recognized.append(String(localized: "\(excluded ? "Exclude context" : "Context"): \(value)"))
            case "channel":
                guard let value = closest(rawValue, in: channels) else { freeTerms.append(token); continue }
                if excluded { result.excludedChannels.insert(value) }
                else { result.includedChannels.insert(value) }
                result.recognized.append(String(localized: "\(excluded ? "Exclude channel" : "Channel"): \(value)"))
            case "archived":
                result.includeArchived = !excluded && truth
                result.recognized.append(result.includeArchived
                    ? String(localized: "Include archived people")
                    : String(localized: "Active people only"))
            case "eligible", "due":
                result.eligibleOnly = !excluded && truth
                result.recognized.append(result.eligibleOnly
                    ? String(localized: "Eligible for a connection suggestion")
                    : String(localized: "Any suggestion eligibility"))
            case "contact":
                let value = SearchNormalizer.normalize(rawValue)
                let parsed: DiscoveryContactAge? = switch value {
                case "30", "over30", "30d": .over30
                case "90", "over90", "90d": .over90
                case "180", "over180", "180d", "6m": .over180
                case "unknown", "never": .unknown
                case "any": .any
                default: nil
                }
                guard let parsed else { freeTerms.append(token); continue }
                result.contactAge = parsed
                result.recognized.append(parsed.title)
            default:
                freeTerms.append(token)
            }
        }
        result.searchTerms = freeTerms.joined(separator: " ")
        return result
    }

    private static func naturalValue(
        in normalized: String,
        prefix: String,
        options: [String]
    ) -> String? {
        guard normalized.hasPrefix(prefix) else { return nil }
        let value = String(normalized.dropFirst(prefix.count))
        return closest(value, in: options)
    }

    private static func closest(_ value: String, in options: [String]) -> String? {
        let normalized = SearchNormalizer.normalize(value)
        return options.first { SearchNormalizer.normalize($0) == normalized }
    }

    private static func quotedTokens(in source: String) -> [String] {
        var output: [String] = []
        var current = ""
        var quote: Character?
        for character in source {
            if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                current.append(character)
            } else if character.isWhitespace && quote == nil {
                if !current.isEmpty { output.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { output.append(current) }
        return output
    }
}

private struct LocalPeopleQueryBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contexts: [String]
    let tags: [String]
    let channels: [String]
    let onApply: (LocalPeopleQueryInterpretation) -> Void
    @State private var query = ""

    private var interpretation: LocalPeopleQueryInterpretation {
        .parse(query, contexts: contexts, tags: tags, channels: channels)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Describe who you want to find", text: $query, axis: .vertical)
                        .lineLimit(2...5)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Text("This query is interpreted entirely on this device. It never sends names or notebook data to an online service.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                } header: {
                    Text("Local query")
                }

                Section("Try a phrase") {
                    queryExample("People due for contact")
                    queryExample("People not contacted in 90 days")
                    queryExample("People tagged family")
                    queryExample("People in Book Club")
                }

                Section("Precise local syntax") {
                    Text("Combine tag:, context:, channel:, archived:true, eligible:true, and contact:90. Prefix tag, context, or channel with a minus to exclude it. Put multi-word values in quotes.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text("Example: context:\"Book Club\" -channel:phone contact:90")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                Section("Interpretation preview") {
                    if interpretation.recognized.isEmpty && interpretation.searchTerms.isEmpty {
                        Text("Enter a phrase to preview the exact local filters before applying it.")
                            .foregroundStyle(AppTheme.secondaryText)
                    } else {
                        ForEach(interpretation.recognized, id: \.self) { item in
                            Label(item, systemImage: "line.3.horizontal.decrease.circle")
                        }
                        if !interpretation.searchTerms.isEmpty {
                            LabeledContent("Full-text terms", value: interpretation.searchTerms)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Build Local Query")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply Query") {
                        onApply(interpretation)
                        dismiss()
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .keepsakeSheetSize(minWidth: 600, minHeight: 560)
    }

    @ViewBuilder
    private func queryExample(_ phrase: String) -> some View {
        Button(phrase) { query = phrase }
            .buttonStyle(.plain)
    }
}
