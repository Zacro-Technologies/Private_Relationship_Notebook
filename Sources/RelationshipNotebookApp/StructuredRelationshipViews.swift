import SwiftUI

// MARK: - Context browser

/// Browses the canonical context graph rather than the legacy flattened strings
/// stored on a `Person`. The hierarchy is intentionally always expanded: a user
/// can see where a program, chapter, or track sits before opening it.
struct ContextsView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @State private var includeArchived = false
    @State private var editor: ContextEditorRoute?

    private var visibleContexts: [Context] {
        canonical.contexts.filter { includeArchived || $0.archivedAt == nil }
    }

    private var hierarchyRows: [ContextHierarchyRow] {
        ContextHierarchyRow.flatten(visibleContexts)
    }

    var body: some View {
        Group {
            if visibleContexts.isEmpty {
                EmptyNotebookView(
                    icon: "square.stack.3d.up",
                    title: includeArchived
                        ? LocalizedStringKey("No contexts found")
                        : LocalizedStringKey("Put relationships in context"),
                    message: "Create an organization, university, program, club, team, or project. Contexts can contain other contexts.",
                    actionTitle: "Create Context"
                ) {
                    editor = .new(parentID: nil)
                }
            } else {
                List {
                    Section {
                        ForEach(hierarchyRows) { row in
                            NavigationLink {
                                ContextDetailView(contextID: row.context.id)
                            } label: {
                                ContextHierarchyLabel(
                                    row: row,
                                    memberCount: canonical.memberships.filter { $0.contextID == row.context.id }.count,
                                    childCount: canonical.contexts.filter { $0.parentContextID == row.context.id }.count
                                )
                            }
                            .contextMenu {
                                Button("Add Child Context") { editor = .new(parentID: row.context.id) }
                                Button("Edit") { editor = .edit(row.context) }
                            }
                        }
                    } header: {
                        Text("Hierarchy")
                    } footer: {
                        Text("Membership, cohort order, and roles are scoped to a context. They are not global labels for a person.")
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Contexts")
        .toolbar {
            Menu {
                Toggle("Include Archived Contexts", isOn: $includeArchived)
            } label: {
                Label("View Options", systemImage: "line.3.horizontal.decrease.circle")
            }
            Button { editor = .new(parentID: nil) } label: {
                Label("Add Context", systemImage: "plus")
            }
        }
        .sheet(item: $editor) { route in
            ContextEditorView(context: route.context, proposedParentID: route.parentID)
        }
        .canonicalStoreErrorAlert()
    }
}

private struct ContextHierarchyLabel: View {
    let row: ContextHierarchyRow
    let memberCount: Int
    let childCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.context.kind.structuredIcon)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(row.context.names.fallback).font(.headline)
                    if row.context.archivedAt != nil {
                        Text("Archived")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.14), in: Capsule())
                    }
                }
                Text(row.context.kind.structuredTitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
            if childCount > 0 {
                Label("\(childCount)", systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityLabel("\(childCount) child contexts")
            }
            Text("\(memberCount) people")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.leading, CGFloat(row.depth) * 20)
        .padding(.vertical, 4)
    }
}

private struct ContextHierarchyRow: Identifiable {
    let context: Context
    let depth: Int
    var id: UUID { context.id }

    static func flatten(_ contexts: [Context]) -> [Self] {
        let IDs = Set(contexts.map(\.id))
        let children = Dictionary(grouping: contexts) { context -> UUID? in
            guard let parentID = context.parentContextID, IDs.contains(parentID) else { return nil }
            return parentID
        }
        let sort: (Context, Context) -> Bool = {
            $0.names.fallback.localizedStandardCompare($1.names.fallback) == .orderedAscending
        }
        var result: [Self] = []
        var visited = Set<UUID>()

        func append(_ context: Context, depth: Int, ancestors: Set<UUID>) {
            guard !ancestors.contains(context.id), visited.insert(context.id).inserted else { return }
            result.append(Self(context: context, depth: depth))
            var nextAncestors = ancestors
            nextAncestors.insert(context.id)
            for child in (children[context.id] ?? []).sorted(by: sort) {
                append(child, depth: depth + 1, ancestors: nextAncestors)
            }
        }

        for root in (children[nil] ?? []).sorted(by: sort) {
            append(root, depth: 0, ancestors: [])
        }
        // Defensive fallback for malformed legacy graphs: keep every context
        // reachable in the UI without recursively following a cycle.
        for orphan in contexts.sorted(by: sort) where !visited.contains(orphan.id) {
            append(orphan, depth: 0, ancestors: [])
        }
        return result
    }
}

// MARK: - Context detail

struct ContextDetailView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @EnvironmentObject private var notebook: NotebookStore
    let contextID: UUID

    @State private var editingContext = false
    @State private var addingChild = false
    @State private var schemeEditor: CohortSchemeEditorRoute?
    @State private var roleEditor: RoleDefinitionEditorRoute?
    @State private var includeArchivedDefinitions = false

    private var context: Context? { canonical.contexts.first { $0.id == contextID } }
    private var children: [Context] {
        canonical.contexts
            .filter { $0.parentContextID == contextID }
            .sorted { $0.names.fallback.localizedStandardCompare($1.names.fallback) == .orderedAscending }
    }
    private var schemes: [CohortScheme] {
        canonical.cohortSchemes
            .filter { $0.contextID == contextID && (includeArchivedDefinitions || $0.archivedAt == nil) }
            .sorted { $0.name.fallback.localizedStandardCompare($1.name.fallback) == .orderedAscending }
    }
    private var roles: [RoleDefinition] {
        canonical.roleDefinitions
            .filter { $0.contextID == contextID && (includeArchivedDefinitions || $0.archivedAt == nil) }
            .sorted { ($0.order ?? .max, $0.labels.fallback) < ($1.order ?? .max, $1.labels.fallback) }
    }
    private var memberships: [MembershipEpisode] {
        canonical.memberships.filter { $0.contextID == contextID }
    }

    var body: some View {
        Group {
            if let context {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(context)
                        hierarchyCard(context)
                        schemesCard(context)
                        rolesCard
                        peopleCard
                    }
                    .padding(28)
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity)
                }
                .background(AppTheme.pageBackground)
                .navigationTitle(context.names.fallback)
                .toolbar {
                    Button("Edit") { editingContext = true }
                    Menu {
                        Button("Add Child Context") { addingChild = true }
                        Button("Add Cohort Scheme") { schemeEditor = .new(contextID: context.id) }
                        Button("Add Role Definition") { roleEditor = .new(contextID: context.id) }
                        Divider()
                        Toggle("Include Archived Definitions", isOn: $includeArchivedDefinitions)
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                .sheet(isPresented: $editingContext) {
                    ContextEditorView(context: context, proposedParentID: context.parentContextID)
                }
                .sheet(isPresented: $addingChild) {
                    ContextEditorView(context: nil, proposedParentID: context.id)
                }
                .sheet(item: $schemeEditor) { route in
                    CohortSchemeEditorView(contextID: route.contextID, scheme: route.scheme)
                }
                .sheet(item: $roleEditor) { route in
                    RoleDefinitionEditorView(contextID: route.contextID, role: route.role)
                }
            } else {
                EmptyNotebookView(
                    icon: "questionmark.folder",
                    title: "Context unavailable",
                    message: "This context may have been removed on another device."
                )
            }
        }
    }

    private func header(_ context: Context) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: context.kind.structuredIcon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 66, height: 66)
                .background(AppTheme.accentSurface, in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 5) {
                Text(context.names.fallback)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(context.kind.structuredTitle).foregroundStyle(AppTheme.secondaryText)
                if let japanese = context.names.localized["ja"], !japanese.isEmpty, japanese != context.names.fallback {
                    Text(japanese).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                }
            }
            Spacer()
            if context.archivedAt != nil {
                Label("Archived", systemImage: "archivebox.fill").foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private func hierarchyCard(_ context: Context) -> some View {
        NotebookCard {
            VStack(alignment: .leading, spacing: 13) {
                Label("Hierarchy", systemImage: "arrow.triangle.branch").font(.headline)
                Text(contextPath(for: context).map(\.names.fallback).joined(separator: "  ›  "))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                Divider()
                if children.isEmpty {
                    Text("No child contexts.").foregroundStyle(AppTheme.secondaryText)
                } else {
                    ForEach(children) { child in
                        NavigationLink {
                            ContextDetailView(contextID: child.id)
                        } label: {
                            Label(child.names.fallback, systemImage: child.kind.structuredIcon)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Add child context") { addingChild = true }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func schemesCard(_ context: Context) -> some View {
        NotebookCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label("Cohort schemes", systemImage: "person.3.sequence.fill").font(.headline)
                    Spacer()
                    Button { schemeEditor = .new(contextID: context.id) } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                if schemes.isEmpty {
                    Text("No cohort dimensions. Add one only when groups have meaning inside this context.")
                        .foregroundStyle(AppTheme.secondaryText)
                }
                ForEach(schemes) { scheme in
                    NavigationLink {
                        CohortSchemeDetailView(schemeID: scheme.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: scheme.orderingMethod == .unordered ? "circle.grid.3x3" : "arrow.down.to.line.compact")
                                .foregroundStyle(AppTheme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(scheme.name.fallback).font(.subheadline.weight(.semibold))
                                if scheme.archivedAt != nil {
                                    Text("Archived").font(.caption2).foregroundStyle(AppTheme.secondaryText)
                                }
                                Text(scheme.kind.structuredTitle + " · " + scheme.orderingMethod.structuredTitle)
                                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                            Spacer()
                            Text("\(canonical.cohorts.filter { $0.schemeID == scheme.id }.count)")
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var rolesCard: some View {
        NotebookCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label("Role definitions", systemImage: "person.text.rectangle").font(.headline)
                    Spacer()
                    Button { roleEditor = .new(contextID: contextID) } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                if roles.isEmpty {
                    Text("Roles are independent from cohorts and can change over time.")
                        .foregroundStyle(AppTheme.secondaryText)
                }
                ForEach(roles) { role in
                    Button { roleEditor = .edit(role) } label: {
                        HStack {
                            Text(role.labels.fallback)
                            if role.archivedAt != nil {
                                Text("Archived").font(.caption2).foregroundStyle(AppTheme.secondaryText)
                            }
                            Spacer()
                            if let dimension = role.orderingDimension, !dimension.isEmpty {
                                Text(dimension).font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                            if let order = role.order { Text("#\(order)").font(.caption).foregroundStyle(AppTheme.secondaryText) }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.tertiaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var peopleCard: some View {
        NotebookCard {
            VStack(alignment: .leading, spacing: 13) {
                Label("Membership episodes", systemImage: "person.2").font(.headline)
                if memberships.isEmpty {
                    Text("No one has a structured membership in this context yet.").foregroundStyle(AppTheme.secondaryText)
                }
                ForEach(memberships) { membership in
                    let resolvedID = canonical.resolvedPersonID(membership.personID)
                    if let person = notebook.person(id: resolvedID) {
                        NavigationLink {
                            PersonDetailView(personID: person.id)
                        } label: {
                            HStack {
                                PersonAvatar(person: person, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.displayName).font(.subheadline.weight(.semibold))
                                    if resolvedID != membership.personID {
                                        Text("Merged identity resolved from historical membership")
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }
                                    Text(membership.status.structuredTitle + " · " + structuredDateRange(membership.startDate, membership.endDate))
                                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        LabeledContent("Unknown person", value: membership.status.structuredTitle)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
            }
        }
    }

    private func contextPath(for context: Context) -> [Context] {
        (try? ContextHierarchy(contexts: canonical.contexts).path(to: context.id)) ?? [context]
    }
}

// MARK: - Cohort scheme detail

struct CohortSchemeDetailView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    let schemeID: UUID
    @State private var editingScheme = false
    @State private var cohortEditor: CohortEditorRoute?
    @State private var cohortToDelete: Cohort?
    @State private var includeArchivedCohorts = false

    private var scheme: CohortScheme? { canonical.cohortSchemes.first { $0.id == schemeID } }
    private var context: Context? { scheme.flatMap { value in canonical.contexts.first { $0.id == value.contextID } } }
    private var cohorts: [Cohort] {
        guard let scheme else { return [] }
        let values = canonical.cohorts.filter {
            $0.schemeID == scheme.id && (includeArchivedCohorts || $0.archivedAt == nil)
        }
        if scheme.orderingMethod == .chronologicalRank {
            return values.sorted {
                ($0.chronologicalRank ?? .max, $0.labels.fallback) < ($1.chronologicalRank ?? .max, $1.labels.fallback)
            }
        }
        return values.sorted { $0.labels.fallback.localizedStandardCompare($1.labels.fallback) == .orderedAscending }
    }

    var body: some View {
        Group {
            if let scheme {
                List {
                    Section("Definition") {
                        LabeledContent("Context", value: context?.names.fallback ?? String(localized: "Unavailable context"))
                        LabeledContent("Template", value: scheme.kind.structuredTitle)
                        LabeledContent("Ordering", value: scheme.orderingMethod.structuredTitle)
                        LabeledContent("Relative meaning", value: scheme.seniorityRule.structuredTitle)
                        LabeledContent("Distance") {
                            Text(scheme.distanceIsMeaningful
                                ? String(localized: "Sequential ranks are meaningful")
                                : String(localized: "Do not calculate a distance"))
                        }
                    }

                    Section {
                        if scheme.orderingMethod == .chronologicalRank {
                            Label(
                                "Lower chronological rank always means earlier. Visible labels and generation numbers are display values only.",
                                systemImage: "arrow.down.to.line.compact"
                            )
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                        } else {
                            Label(
                                "This scheme is unordered. Keepsake will not derive earlier/later or senior/junior relationships.",
                                systemImage: "info.circle"
                            )
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    Section("Cohorts") {
                        if cohorts.isEmpty {
                            Text("No cohorts yet.").foregroundStyle(AppTheme.secondaryText)
                        }
                        ForEach(cohorts) { cohort in
                            Button { cohortEditor = .edit(cohort, in: scheme) } label: {
                                CohortRow(cohort: cohort, ordered: scheme.orderingMethod == .chronologicalRank)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit") { cohortEditor = .edit(cohort, in: scheme) }
                                Button("Move to Recently Deleted", role: .destructive) { cohortToDelete = cohort }
                            }
                        }
                    }
                }
                .navigationTitle(scheme.name.fallback)
                .toolbar {
                    Button("Edit Scheme") { editingScheme = true }
                    Menu {
                        Toggle("Include Archived Cohorts", isOn: $includeArchivedCohorts)
                    } label: {
                        Label("View Options", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Button { cohortEditor = .new(in: scheme) } label: {
                        Label("Add Cohort", systemImage: "plus")
                    }
                }
                .sheet(isPresented: $editingScheme) {
                    CohortSchemeEditorView(contextID: scheme.contextID, scheme: scheme)
                }
                .sheet(item: $cohortEditor) { route in
                    CohortEditorView(scheme: route.scheme, cohort: route.cohort)
                }
                .confirmationDialog(
                    "Move this cohort to Recently Deleted?",
                    isPresented: Binding(
                        get: { cohortToDelete != nil },
                        set: { if !$0 { cohortToDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Move to Recently Deleted", role: .destructive) {
                        if let cohortToDelete { canonical.delete(cohortToDelete, kind: "cohort") }
                        cohortToDelete = nil
                    }
                    Button("Cancel", role: .cancel) { cohortToDelete = nil }
                } message: {
                    Text("Existing assignments retain their stable references for recovery. Relative comparisons may be unavailable until the cohort is restored.")
                }
            } else {
                EmptyNotebookView(icon: "person.3.sequence", title: "Scheme unavailable", message: "It may have been removed on another device.")
            }
        }
    }
}

private struct CohortRow: View {
    let cohort: Cohort
    let ordered: Bool

    var body: some View {
        HStack(spacing: 12) {
            if ordered {
                Text(cohort.chronologicalRank.map(String.init) ?? "—")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .frame(width: 42)
                    .padding(.vertical, 6)
                    .background(AppTheme.accentSurface, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel(cohort.chronologicalRank.map {
                        String(localized: "Chronological rank \($0)")
                    } ?? String(localized: "No chronological rank"))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(cohort.labels.fallback).font(.headline)
                if cohort.archivedAt != nil {
                    Text("Archived").font(.caption2).foregroundStyle(AppTheme.secondaryText)
                }
                HStack(spacing: 6) {
                    if let number = cohort.displayNumber { Text("Display #\(number)") }
                    Text(structuredDateRange(cohort.startDate, cohort.endDate))
                }
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.tertiaryText)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

// MARK: - Person structured data

/// Reusable person-detail section for canonical memberships, roles, cohorts,
/// university education, and source-aware facts.
struct PersonStructuredDataView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    let person: Person

    @State private var membershipEditor: MembershipEditorRoute?
    @State private var educationEditor: EducationEditorRoute?
    @State private var factEditor: ManualFactEditorRoute?
    @State private var factDetail: FactDetailRoute?
    @State private var deleteTarget: StructuredDeleteTarget?

    private var memberships: [MembershipEpisode] {
        canonical.memberships(for: person.id).sorted {
            ($0.startDate?.earliestInstant ?? .distantPast) > ($1.startDate?.earliestInstant ?? .distantPast)
        }
    }
    private var education: [EducationEnrollment] {
        canonical.education(for: person.id).sorted {
            ($0.startDate?.earliestInstant ?? .distantPast) > ($1.startDate?.earliestInstant ?? .distantPast)
        }
    }
    private var currentAssertions: [AssertionEnvelope] {
        let values = canonical.assertions(for: person.id)
        let superseded = Set(values.compactMap(\.supersedesID))
        return values.filter {
            !superseded.contains($0.id) &&
                RecommendationMemoryCategory.category(forPredicateID: $0.predicateID) == nil
        }
            .sorted { $0.assertedAt > $1.assertedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            membershipsCard
            educationCard
            factsCard
        }
        .sheet(item: $membershipEditor) { route in
            MembershipEditorView(
                person: person,
                membership: route.membership,
                cohortAssignment: route.cohortAssignment,
                roleAssignment: route.roleAssignment
            )
        }
        .sheet(item: $educationEditor) { route in
            EducationEditorView(person: person, enrollment: route.enrollment)
        }
        .sheet(item: $factEditor) { route in
            ManualFactEditorView(person: person, assertion: route.assertion, fieldName: route.fieldName)
        }
        .sheet(item: $factDetail) { route in
            FactProvenanceView(person: person, assertion: route.assertion, fieldName: route.fieldName)
        }
        .confirmationDialog(
            deleteTarget?.title ?? String(localized: "Move record to Recently Deleted?"),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Recently Deleted", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget?.message ?? String(localized: "The record remains recoverable under the vault retention policy."))
        }
        .canonicalStoreErrorAlert()
    }

    private var membershipsCard: some View {
        NotebookCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Memberships & roles", systemImage: "square.stack.3d.up").font(.headline)
                    Spacer()
                    Button { membershipEditor = .new } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(.bordered)
                }
                Text("Memberships are dated episodes. Cohorts and roles belong to an episode and keep their own history.")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                if memberships.isEmpty {
                    Text("No structured memberships yet.").foregroundStyle(AppTheme.secondaryText)
                }
                ForEach(memberships) { membership in
                    MembershipEpisodeView(
                        membership: membership,
                        context: canonical.contexts.first { $0.id == membership.contextID },
                        assignments: canonical.cohortAssignments.filter { $0.membershipEpisodeID == membership.id },
                        roles: canonical.roleAssignments.filter { $0.membershipEpisodeID == membership.id },
                        cohorts: canonical.cohorts,
                        schemes: canonical.cohortSchemes,
                        onEditEpisode: { membershipEditor = .editEpisode(membership) },
                        onAddDetail: { membershipEditor = .addDetail(to: membership) },
                        onEditCohort: { membershipEditor = .editCohort($0, membership: membership) },
                        onEditRole: { membershipEditor = .editRole($0, membership: membership) },
                        onDelete: { deleteTarget = .membership(membership) },
                        onDeleteCohort: { deleteTarget = .cohortAssignment($0) },
                        onDeleteRole: { deleteTarget = .roleAssignment($0) }
                    )
                    if membership.id != memberships.last?.id { Divider() }
                }
            }
        }
    }

    private var educationCard: some View {
        NotebookCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Education", systemImage: "graduationcap").font(.headline)
                    Spacer()
                    Button { educationEditor = .new } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(.bordered)
                }
                Text("Expected and actual university graduation are stored separately. Program or scholarship completion never fills either value.")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                if education.isEmpty {
                    Text("No education enrollments yet.").foregroundStyle(AppTheme.secondaryText)
                }
                ForEach(education) { enrollment in
                    Button { educationEditor = .edit(enrollment) } label: {
                        EducationEnrollmentRow(
                            enrollment: enrollment,
                            institution: canonical.contexts.first { $0.id == enrollment.institutionContextID }
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit") { educationEditor = .edit(enrollment) }
                        Button("Move to Recently Deleted", role: .destructive) { deleteTarget = .education(enrollment) }
                    }
                }
            }
        }
    }

    private var factsCard: some View {
        NotebookCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Facts & provenance", systemImage: "checkmark.seal").font(.headline)
                    Spacer()
                    Button { factEditor = .new } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(.bordered)
                }
                Text("Each fact keeps its source, time, sensitivity, and permitted uses. Editing creates a new version instead of overwriting its history.")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                if currentAssertions.isEmpty {
                    Text("No source-aware facts yet.").foregroundStyle(AppTheme.secondaryText)
                }
                ForEach(currentAssertions) { assertion in
                    let fieldName = factName(assertion)
                    Button { factDetail = .init(assertion: assertion, fieldName: fieldName) } label: {
                        AssertionRow(
                            assertion: assertion,
                            fieldName: fieldName,
                            source: assertion.sourceID.flatMap { sourceID in canonical.sources.first { $0.id == sourceID } }
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Add corrected version") { factEditor = .edit(assertion, fieldName: fieldName) }
                        Button("Move to Recently Deleted", role: .destructive) { deleteTarget = .assertion(assertion) }
                    }
                }
            }
        }
    }

    private func factName(_ assertion: AssertionEnvelope) -> String {
        if let definition = canonical.attributeDefinitions.first(where: { $0.predicateID == assertion.predicateID }) {
            return definition.labels.fallback
        }
        return humanizedPredicate(assertion.predicateID)
    }

    private func performDelete() {
        guard let deleteTarget else { return }
        switch deleteTarget {
        case let .membership(membership):
            for assignment in canonical.cohortAssignments where assignment.membershipEpisodeID == membership.id {
                canonical.delete(assignment, kind: "cohortAssignment")
            }
            for role in canonical.roleAssignments where role.membershipEpisodeID == membership.id {
                canonical.delete(role, kind: "roleAssignment")
            }
            canonical.delete(membership, kind: "membership")
        case let .cohortAssignment(value): canonical.delete(value, kind: "cohortAssignment")
        case let .roleAssignment(value): canonical.delete(value, kind: "roleAssignment")
        case let .education(value): canonical.delete(value, kind: "education")
        case let .assertion(value): canonical.delete(value, kind: "assertion")
        }
        self.deleteTarget = nil
    }
}

private struct MembershipEpisodeView: View {
    let membership: MembershipEpisode
    let context: Context?
    let assignments: [CohortAssignment]
    let roles: [RoleAssignment]
    let cohorts: [Cohort]
    let schemes: [CohortScheme]
    let onEditEpisode: () -> Void
    let onAddDetail: () -> Void
    let onEditCohort: (CohortAssignment) -> Void
    let onEditRole: (RoleAssignment) -> Void
    let onDelete: () -> Void
    let onDeleteCohort: (CohortAssignment) -> Void
    let onDeleteRole: (RoleAssignment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Button(action: onEditEpisode) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context?.names.fallback ?? String(localized: "Unavailable context"))
                            .font(.subheadline.weight(.semibold))
                        Text(membership.status.structuredTitle + " · " + structuredDateRange(membership.startDate, membership.endDate))
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("Edit membership", action: onEditEpisode)
                    Button("Add cohort or role", action: onAddDetail)
                    Divider()
                    Button("Move membership to Recently Deleted", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }

            ForEach(assignments) { assignment in
                Button { onEditCohort(assignment) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: assignment.isPrimary ? "person.3.fill" : "person.3")
                            .foregroundStyle(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cohortDescription(assignment)).font(.subheadline)
                            Text(assignment.assignmentKind.structuredTitle + " · " + structuredDateRange(assignment.startDate, assignment.endDate))
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit") { onEditCohort(assignment) }
                    Button("Move to Recently Deleted", role: .destructive) { onDeleteCohort(assignment) }
                }
            }

            ForEach(roles) { role in
                Button { onEditRole(role) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "person.text.rectangle").foregroundStyle(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(role.roleLabel.fallback).font(.subheadline)
                            Text(String(localized: "Role") + " · " + structuredDateRange(role.startDate, role.endDate))
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit") { onEditRole(role) }
                    Button("Move to Recently Deleted", role: .destructive) { onDeleteRole(role) }
                }
            }
            if assignments.isEmpty && roles.isEmpty {
                Button("Add a cohort assignment or role", action: onAddDetail).font(.caption)
            }
        }
        .padding(.vertical, 3)
    }

    private func cohortDescription(_ assignment: CohortAssignment) -> String {
        guard let cohort = cohorts.first(where: { $0.id == assignment.cohortID }) else {
            return String(localized: "Unavailable cohort")
        }
        let scheme = schemes.first { $0.id == cohort.schemeID }
        return [scheme?.name.fallback, cohort.labels.fallback].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct EducationEnrollmentRow: View {
    let enrollment: EducationEnrollment
    let institution: Context?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "graduationcap.fill").foregroundStyle(AppTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(institution?.names.fallback ?? String(localized: "Unavailable institution"))
                    .font(.subheadline.weight(.semibold))
                let detail = [enrollment.program?.fallback, enrollment.degree?.fallback]
                    .compactMap { value in value?.isEmpty == false ? value : nil }
                    .joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(.subheadline) }
                Text(enrollment.status.structuredTitle + " · " + structuredDateRange(enrollment.startDate, enrollment.endDate))
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                if let expected = enrollment.expectedGraduation {
                    Text("Expected graduation: \(expected.description)").font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                if let actual = enrollment.actualGraduation {
                    Label("Graduated \(actual.description)", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(AppTheme.accent)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.tertiaryText)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }
}

private struct AssertionRow: View {
    let assertion: AssertionEnvelope
    let fieldName: String
    let source: SourceArtifact?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: assertion.origin.structuredIcon).foregroundStyle(AppTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(fieldName).font(.subheadline.weight(.semibold))
                    Text(assertion.sensitivity.structuredTitle)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(assertion.sensitivity.structuredColor.opacity(0.14), in: Capsule())
                }
                Text(assertion.value.structuredDisplay).lineLimit(3)
                HStack(spacing: 5) {
                    Text(source?.originalFilename ?? source?.kind.structuredTitle ?? assertion.origin.structuredTitle)
                    Text("·")
                    Text(assertion.observedAt, format: .dateTime.year().month().day())
                    Text("·")
                    Text(assertion.reviewStatus.structuredTitle)
                }
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                if assertion.usePolicy.mention == .never || assertion.usePolicy.ai == .deny {
                    HStack(spacing: 8) {
                        if assertion.usePolicy.mention == .never { Label("Never mention", systemImage: "quote.bubble.fill") }
                        if assertion.usePolicy.ai == .deny { Label("AI excluded", systemImage: "sparkles.slash") }
                    }
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.tertiaryText)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }
}

private struct FactProvenanceView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss
    let person: Person
    let assertion: AssertionEnvelope
    let fieldName: String
    @State private var correcting = false

    private var versions: [AssertionEnvelope] {
        canonical.assertions(for: person.id)
            .filter { $0.predicateID == assertion.predicateID }
            .sorted { $0.assertedAt > $1.assertedAt }
    }

    private var currentVersions: [AssertionEnvelope] {
        let superseded = Set(versions.compactMap(\.supersedesID))
        return versions.filter { !superseded.contains($0.id) }
    }

    private var source: SourceArtifact? {
        assertion.sourceID.flatMap { id in canonical.sources.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Current claim") {
                    LabeledContent("Field", value: fieldName)
                    Text(assertion.value.structuredDisplay).textSelection(.enabled)
                    LabeledContent("Review status", value: assertion.reviewStatus.structuredTitle)
                    LabeledContent("Certainty", value: assertion.certainty.structuredTitle)
                    LabeledContent("Confidence", value: assertion.confidence.map { "\(Int($0 * 100))%" } ?? String(localized: "Not recorded"))
                    if assertion.reviewStatus == .conflicted || currentVersions.count > 1 {
                        Label("This predicate has conflicting current versions. Review each source before choosing a correction.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Source & provenance") {
                    LabeledContent("Origin", value: assertion.origin.structuredTitle)
                    if let source {
                        LabeledContent("Source", value: source.originalFilename ?? source.kind.structuredTitle)
                        LabeledContent("Imported", value: source.importedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Original retention", value: source.retentionPolicy.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized)
                        LabeledContent("Source AI policy", value: source.aiPolicy.structuredTitle)
                    } else {
                        Text("No separate source artifact is attached to this version.")
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    if let remote = assertion.remoteSelfProfileProvenance {
                        LabeledContent("Profile card version", value: "\(remote.cardVersion)")
                        LabeledContent("Payload fingerprint", value: String(remote.exactPayloadSHA256.prefix(16)) + "…")
                    }
                }

                Section("Timing & validity") {
                    LabeledContent("Observed", value: assertion.observedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Asserted", value: assertion.assertedAt.formatted(date: .abbreviated, time: .shortened))
                    if let validFrom = assertion.validFrom { LabeledContent("Valid from", value: validFrom.description) }
                    if let validTo = assertion.validTo { LabeledContent("Valid through", value: validTo.description) }
                    if assertion.validFrom == nil && assertion.validTo == nil {
                        Text("No validity interval was recorded.")
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }

                if !assertion.evidenceIDs.isEmpty {
                    Section("Evidence") {
                        ForEach(assertion.evidenceIDs, id: \.self) { evidenceID in
                            if let span = canonical.evidence.first(where: { $0.id == evidenceID }) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Evidence \(evidenceID.uuidString.prefix(8))")
                                        .font(.subheadline.weight(.semibold))
                                    if let excerpt = span.retainedExcerpt {
                                        Text(excerpt).privacySensitive().textSelection(.enabled)
                                    } else {
                                        Text("Location/hash retained; excerpt text was not retained.")
                                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                                    }
                                }
                            } else {
                                Label("Referenced evidence is unavailable", systemImage: "exclamationmark.triangle")
                            }
                        }
                    }
                }

                Section("Permitted uses") {
                    LabeledContent("Sensitivity", value: assertion.sensitivity.structuredTitle)
                    LabeledContent("Search", value: assertion.usePolicy.search.rawValue)
                    LabeledContent("Reminders", value: assertion.usePolicy.remindersAllowed ? String(localized: "Allowed") : String(localized: "Excluded"))
                    LabeledContent("Notifications", value: assertion.usePolicy.notifications.rawValue)
                    LabeledContent("Sharing", value: assertion.usePolicy.sharing.rawValue)
                    LabeledContent("Conversation mention", value: assertion.usePolicy.mention.rawValue)
                    LabeledContent("AI", value: assertion.usePolicy.ai.structuredTitle)
                }

                Section("Version history") {
                    ForEach(versions) { version in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(version.value.structuredDisplay).lineLimit(2)
                                Spacer()
                                if version.id == assertion.id { Text("OPEN").font(.caption2.bold()).foregroundStyle(AppTheme.accent) }
                                else if currentVersions.contains(where: { $0.id == version.id }) { Text("CURRENT").font(.caption2.bold()).foregroundStyle(.orange) }
                                else { Text("SUPERSEDED").font(.caption2.bold()).foregroundStyle(AppTheme.secondaryText) }
                            }
                            Text("\(version.assertedAt.formatted(date: .abbreviated, time: .shortened)) · \(version.reviewStatus.structuredTitle) · \(version.certainty.structuredTitle)")
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                            if let predecessor = version.supersedesID {
                                Text("Corrects version \(predecessor.uuidString.prefix(8))")
                                    .font(.caption2).foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Fact Provenance")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Add Corrected Version") { correcting = true } }
            }
        }
        .keepsakeSheetSize(minWidth: 560, minHeight: 700)
        .sheet(isPresented: $correcting) {
            ManualFactEditorView(person: person, assertion: assertion, fieldName: fieldName)
        }
    }
}

// MARK: - Context editors

struct ContextEditorView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss

    private let original: Context?
    private let proposedParentID: UUID?
    @State private var name: String
    @State private var japaneseName: String
    @State private var kind: ContextKind
    @State private var parentID: UUID?
    @State private var archived: Bool
    @State private var validationMessage: String?

    init(context: Context? = nil, proposedParentID: UUID? = nil) {
        self.original = context
        self.proposedParentID = proposedParentID
        _name = State(initialValue: context?.names.fallback ?? "")
        _japaneseName = State(initialValue: context?.names.localized["ja"] ?? "")
        _kind = State(initialValue: context?.kind ?? .organization)
        _parentID = State(initialValue: context?.parentContextID ?? proposedParentID)
        _archived = State(initialValue: context?.archivedAt != nil)
    }

    private var parentCandidates: [Context] {
        var excluded = Set<UUID>()
        if let original {
            excluded.insert(original.id)
            if let hierarchy = try? ContextHierarchy(contexts: canonical.contexts),
               let descendants = try? hierarchy.descendants(of: original.id) {
                excluded.formUnion(descendants.map(\.id))
            }
        }
        return canonical.contexts
            .filter {
                !excluded.contains($0.id) &&
                    ($0.archivedAt == nil || $0.id == original?.parentContextID)
            }
            .sorted { $0.names.fallback.localizedStandardCompare($1.names.fallback) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    TextField("Japanese name (optional)", text: $japaneseName)
                    Picker("Kind", selection: $kind) {
                        ForEach(ContextKind.allCases, id: \.rawValue) { value in
                            Label(value.structuredTitle, systemImage: value.structuredIcon).tag(value)
                        }
                    }
                }
                Section {
                    Picker("Parent context", selection: $parentID) {
                        Text("None — top level").tag(nil as UUID?)
                        ForEach(parentCandidates) { context in
                            Text(contextPathLabel(context)).tag(context.id as UUID?)
                        }
                    }
                } header: {
                    Text("Hierarchy")
                } footer: {
                    Text("A context cannot be its own parent or be moved inside one of its descendants.")
                }
                if original != nil {
                    Section("Availability") {
                        Toggle("Archived", isOn: $archived)
                        Text("Archiving hides this context from new selections but keeps memberships and history intact.")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(original == nil
                ? String(localized: "New Context")
                : String(localized: "Edit Context"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(trimmedName.isEmpty)
                }
            }
        }
        #if os(macOS)
        .keepsakeSheetSize(minWidth: 520, minHeight: 520)
        #endif
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func contextPathLabel(_ context: Context) -> String {
        guard let hierarchy = try? ContextHierarchy(contexts: canonical.contexts),
              let path = try? hierarchy.path(to: context.id) else { return context.names.fallback }
        return path.map(\.names.fallback).joined(separator: " › ")
    }

    private func save() {
        validationMessage = nil
        let localizedName = japaneseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date.now
        let value = Context(
            id: original?.id ?? UUID(),
            parentContextID: parentID,
            kind: kind,
            names: LocalizedText(trimmedName, localized: localizedName.isEmpty ? [:] : ["ja": localizedName]),
            archivedAt: archived ? (original?.archivedAt ?? now) : nil,
            createdAt: original?.createdAt ?? now,
            modifiedAt: now,
            schemaRevision: original?.schemaRevision ?? 1
        )
        let proposed = canonical.contexts.filter { $0.id != value.id } + [value]
        do {
            _ = try ContextHierarchy(contexts: proposed)
            canonical.save(value)
            dismiss()
        } catch {
            validationMessage = String(localized: "That parent would make the context hierarchy invalid. Choose another parent.")
        }
    }
}

struct CohortSchemeEditorView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss

    let contextID: UUID
    private let original: CohortScheme?
    @State private var name: String
    @State private var japaneseName: String
    @State private var kind: CohortSchemeKind
    @State private var orderingMethod: CohortOrderingMethod
    @State private var seniorityRule: CohortSeniorityRule
    @State private var distanceIsMeaningful: Bool
    @State private var chronologyConfirmed = false
    @State private var archived: Bool

    init(contextID: UUID, scheme: CohortScheme? = nil) {
        self.contextID = contextID
        self.original = scheme
        _name = State(initialValue: scheme?.name.fallback ?? CohortSchemeKind.numberedGeneration.structuredTitle)
        _japaneseName = State(initialValue: scheme?.name.localized["ja"] ?? "")
        _kind = State(initialValue: scheme?.kind ?? .numberedGeneration)
        _orderingMethod = State(initialValue: scheme?.orderingMethod ?? .chronologicalRank)
        _seniorityRule = State(initialValue: scheme?.seniorityRule ?? .noSeniority)
        _distanceIsMeaningful = State(initialValue: scheme?.distanceIsMeaningful ?? false)
        _archived = State(initialValue: scheme?.archivedAt != nil)
    }

    private var isOrdered: Bool { orderingMethod == .chronologicalRank }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!isOrdered || chronologyConfirmed)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Scheme") {
                    TextField("Scheme name", text: $name)
                    TextField("Japanese name (optional)", text: $japaneseName)
                    Picker("Template", selection: $kind) {
                        ForEach(CohortSchemeKind.allCases, id: \.rawValue) { value in
                            Text(value.structuredTitle).tag(value)
                        }
                    }
                    Picker("Ordering", selection: $orderingMethod) {
                        ForEach(CohortOrderingMethod.allCases, id: \.rawValue) { value in
                            Text(value.structuredTitle).tag(value)
                        }
                    }
                    .disabled(original != nil && !existingCohorts.isEmpty)
                    if original != nil && !existingCohorts.isEmpty {
                        Text("Ordering cannot be reinterpreted after cohorts exist. Create a new scheme for a different ordering model.")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                }

                if isOrdered {
                    Section {
                        Label(
                            "Every cohort gets an independent chronological rank. A lower rank always means earlier in time, even when visible generation numbers count in the opposite direction.",
                            systemImage: "arrow.down.to.line.compact"
                        )
                        .font(.subheadline)
                        Picker("Relative meaning", selection: $seniorityRule) {
                            ForEach(CohortSeniorityRule.allCases, id: \.rawValue) { value in
                                Text(value.structuredTitle).tag(value)
                            }
                        }
                        Toggle("Every intervening rank is a meaningful distance", isOn: $distanceIsMeaningful)
                        Toggle("I confirm that lower chronological rank means earlier", isOn: $chronologyConfirmed)
                            .fontWeight(.semibold)
                    } header: {
                        Text("Chronology confirmation")
                    } footer: {
                        Text("Keepsake will derive earlier/later only inside this scheme. It will show cohort distance only when all intervening ranks exist and distance is enabled.")
                    }
                } else {
                    Section {
                        Label("No chronological comparisons or seniority labels will be derived for this scheme.", systemImage: "info.circle")
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }

                if original != nil {
                    Section("Availability") { Toggle("Archived", isOn: $archived) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(original == nil
                ? String(localized: "New Cohort Scheme")
                : String(localized: "Edit Cohort Scheme"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .onChange(of: kind) { oldKind, newKind in
                if original == nil || name == oldKind.structuredTitle {
                    name = newKind.structuredTitle
                }
                if newKind == .unorderedGroup { orderingMethod = .unordered }
            }
            .onChange(of: orderingMethod) { _, method in
                chronologyConfirmed = false
                if method == .unordered {
                    seniorityRule = .noSeniority
                    distanceIsMeaningful = false
                }
            }
        }
        #if os(macOS)
        .keepsakeSheetSize(minWidth: 560, minHeight: 620)
        #endif
    }

    private var existingCohorts: [Cohort] {
        guard let original else { return [] }
        return canonical.cohorts.filter { $0.schemeID == original.id }
    }

    private func save() {
        let now = Date.now
        let japanese = japaneseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = orderingMethod == .chronologicalRank
        canonical.save(CohortScheme(
            id: original?.id ?? UUID(),
            contextID: contextID,
            kind: kind,
            name: LocalizedText(
                name.trimmingCharacters(in: .whitespacesAndNewlines),
                localized: japanese.isEmpty ? [:] : ["ja": japanese]
            ),
            orderingMethod: orderingMethod,
            seniorityRule: ordered ? seniorityRule : .noSeniority,
            distanceIsMeaningful: ordered && distanceIsMeaningful,
            archivedAt: archived ? (original?.archivedAt ?? now) : nil,
            createdAt: original?.createdAt ?? now,
            modifiedAt: now,
            schemaRevision: original?.schemaRevision ?? 1
        ))
        dismiss()
    }
}

struct CohortEditorView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss

    let scheme: CohortScheme
    private let original: Cohort?
    @State private var label: String
    @State private var japaneseLabel: String
    @State private var hasDisplayNumber: Bool
    @State private var displayNumber: Int
    @State private var startDate: PartialDate?
    @State private var endDate: PartialDate?
    @State private var rankText: String
    @State private var rankConfirmed = false
    @State private var archived: Bool
    @State private var validationMessage: String?
    @State private var partialDateInputsValid = true

    init(scheme: CohortScheme, cohort: Cohort? = nil) {
        self.scheme = scheme
        self.original = cohort
        _label = State(initialValue: cohort?.labels.fallback ?? "")
        _japaneseLabel = State(initialValue: cohort?.labels.localized["ja"] ?? "")
        _hasDisplayNumber = State(initialValue: cohort?.displayNumber != nil)
        _displayNumber = State(initialValue: cohort?.displayNumber ?? 1)
        _startDate = State(initialValue: cohort?.startDate)
        _endDate = State(initialValue: cohort?.endDate)
        _rankText = State(initialValue: cohort?.chronologicalRank.map(String.init) ?? "")
        _archived = State(initialValue: cohort?.archivedAt != nil)
    }

    private var isOrdered: Bool { scheme.orderingMethod == .chronologicalRank }
    private var parsedRank: Int? { Int(rankText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            partialDateInputsValid &&
            PartialDateRange.isOrdered(start: startDate, end: endDate) &&
            (!isOrdered || (parsedRank != nil && rankConfirmed))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    TextField("Cohort label", text: $label)
                    TextField("Japanese label (optional)", text: $japaneseLabel)
                    Toggle("Has a display number", isOn: $hasDisplayNumber)
                    if hasDisplayNumber {
                        Stepper("Display number: \(displayNumber)", value: $displayNumber, in: -10_000...10_000)
                        Text("The display number does not determine chronology.")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                }

                Section("Dates") {
                    StructuredPartialDateField("Starts", value: $startDate)
                    StructuredPartialDateField("Ends", value: $endDate)
                    if !PartialDateRange.isOrdered(start: startDate, end: endDate) {
                        Label("The start must not follow the end.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if isOrdered {
                    Section {
                        TextField("Chronological rank", text: $rankText)
                        #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                        #endif
                        let otherRanks = canonical.cohorts
                            .filter { $0.schemeID == scheme.id && $0.id != original?.id }
                            .compactMap(\.chronologicalRank)
                            .sorted()
                        if !otherRanks.isEmpty {
                            Text("Existing ranks: \(otherRanks.map(String.init).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                        if let rank = parsedRank,
                           canonical.cohorts.contains(where: { $0.schemeID == scheme.id && $0.id != original?.id && $0.chronologicalRank == rank }) {
                            Label("That chronological rank is already used in this scheme.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        Toggle("I confirm this rank places the cohort in real chronological order", isOn: $rankConfirmed)
                            .fontWeight(.semibold)
                    } header: {
                        Text("Chronological order")
                    } footer: {
                        Text("Lower rank means earlier. The visible label and display number never override this rank.")
                    }
                }

                if original != nil { Section("Availability") { Toggle("Archived", isOn: $archived) } }
                if let validationMessage {
                    Section { Label(validationMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .onPreferenceChange(StructuredPartialDateValidityKey.self) { partialDateInputsValid = $0 }
            .navigationTitle(original == nil
                ? String(localized: "New Cohort")
                : String(localized: "Edit Cohort"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave || hasDuplicateRank) }
            }
        }
        #if os(macOS)
        .keepsakeSheetSize(minWidth: 560, minHeight: 650)
        #endif
    }

    private var hasDuplicateRank: Bool {
        guard isOrdered, let parsedRank else { return false }
        return canonical.cohorts.contains { $0.schemeID == scheme.id && $0.id != original?.id && $0.chronologicalRank == parsedRank }
    }

    private func save() {
        guard canSave, !hasDuplicateRank else {
            validationMessage = String(localized: "Choose a unique chronological rank and confirm its meaning.")
            return
        }
        let now = Date.now
        let japanese = japaneseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        canonical.save(Cohort(
            id: original?.id ?? UUID(),
            schemeID: scheme.id,
            labels: LocalizedText(label.trimmingCharacters(in: .whitespacesAndNewlines), localized: japanese.isEmpty ? [:] : ["ja": japanese]),
            displayNumber: hasDisplayNumber ? displayNumber : nil,
            startDate: startDate,
            endDate: endDate,
            chronologicalRank: isOrdered ? parsedRank : nil,
            archivedAt: archived ? (original?.archivedAt ?? now) : nil,
            createdAt: original?.createdAt ?? now,
            modifiedAt: now,
            schemaRevision: original?.schemaRevision ?? 1
        ))
        dismiss()
    }
}

struct RoleDefinitionEditorView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss
    let contextID: UUID
    private let original: RoleDefinition?
    @State private var label: String
    @State private var japaneseLabel: String
    @State private var dimension: String
    @State private var hasOrder: Bool
    @State private var order: Int
    @State private var archived: Bool

    init(contextID: UUID, role: RoleDefinition? = nil) {
        self.contextID = contextID
        self.original = role
        _label = State(initialValue: role?.labels.fallback ?? "")
        _japaneseLabel = State(initialValue: role?.labels.localized["ja"] ?? "")
        _dimension = State(initialValue: role?.orderingDimension ?? "")
        _hasOrder = State(initialValue: role?.order != nil)
        _order = State(initialValue: role?.order ?? 0)
        _archived = State(initialValue: role?.archivedAt != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Role") {
                    TextField("Role label", text: $label)
                    TextField("Japanese label (optional)", text: $japaneseLabel)
                }
                Section {
                    TextField("Ordering dimension (optional)", text: $dimension)
                    Toggle("Has an order within this dimension", isOn: $hasOrder)
                    if hasOrder { Stepper("Order: \(order)", value: $order, in: -10_000...10_000) }
                } footer: {
                    Text("Role order is separate from cohort chronology. For example, a job level must not be compared with a university class.")
                }
                if original != nil { Section("Availability") { Toggle("Archived", isOn: $archived) } }
            }
            .formStyle(.grouped)
            .navigationTitle(original == nil
                ? String(localized: "New Role Definition")
                : String(localized: "Edit Role Definition"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .keepsakeSheetSize(minWidth: 520, minHeight: 500)
        #endif
    }

    private func save() {
        let now = Date.now
        let japanese = japaneseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        canonical.save(RoleDefinition(
            id: original?.id ?? UUID(),
            contextID: contextID,
            labels: LocalizedText(label.trimmingCharacters(in: .whitespacesAndNewlines), localized: japanese.isEmpty ? [:] : ["ja": japanese]),
            orderingDimension: dimension.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            order: hasOrder ? order : nil,
            archivedAt: archived ? (original?.archivedAt ?? now) : nil,
            createdAt: original?.createdAt ?? now,
            modifiedAt: now,
            schemaRevision: original?.schemaRevision ?? 1
        ))
        dismiss()
    }
}

// MARK: - Membership and education editors

struct MembershipEditorView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss

    let person: Person
    private let originalMembership: MembershipEpisode?
    private let originalCohortAssignment: CohortAssignment?
    private let originalRoleAssignment: RoleAssignment?

    @State private var contextID: UUID?
    @State private var status: MembershipStatus
    @State private var startDate: PartialDate?
    @State private var endDate: PartialDate?

    @State private var cohortID: UUID?
    @State private var assignmentKind: CohortAssignmentKind
    @State private var assignmentIsPrimary: Bool
    @State private var assignmentStartDate: PartialDate?
    @State private var assignmentEndDate: PartialDate?

    @State private var roleDefinitionID: UUID?
    @State private var roleLabel: String
    @State private var roleJapaneseLabel: String
    @State private var roleStartDate: PartialDate?
    @State private var roleEndDate: PartialDate?
    @State private var validationMessage: String?
    @State private var showingContextEditor = false
    @State private var partialDateInputsValid = true

    init(
        person: Person,
        membership: MembershipEpisode? = nil,
        cohortAssignment: CohortAssignment? = nil,
        roleAssignment: RoleAssignment? = nil
    ) {
        self.person = person
        self.originalMembership = membership
        self.originalCohortAssignment = cohortAssignment
        self.originalRoleAssignment = roleAssignment
        _contextID = State(initialValue: membership?.contextID)
        _status = State(initialValue: membership?.status ?? .active)
        _startDate = State(initialValue: membership?.startDate)
        _endDate = State(initialValue: membership?.endDate)
        _cohortID = State(initialValue: cohortAssignment?.cohortID)
        _assignmentKind = State(initialValue: cohortAssignment?.assignmentKind ?? .initial)
        _assignmentIsPrimary = State(initialValue: cohortAssignment?.isPrimary ?? true)
        _assignmentStartDate = State(initialValue: cohortAssignment?.startDate)
        _assignmentEndDate = State(initialValue: cohortAssignment?.endDate)
        _roleDefinitionID = State(initialValue: roleAssignment?.roleDefinitionID)
        _roleLabel = State(initialValue: roleAssignment?.roleLabel.fallback ?? "")
        _roleJapaneseLabel = State(initialValue: roleAssignment?.roleLabel.localized["ja"] ?? "")
        _roleStartDate = State(initialValue: roleAssignment?.startDate)
        _roleEndDate = State(initialValue: roleAssignment?.endDate)
    }

    private var contexts: [Context] {
        canonical.contexts.filter { $0.archivedAt == nil }
            .sorted { $0.names.fallback.localizedStandardCompare($1.names.fallback) == .orderedAscending }
    }
    private var availableCohorts: [(scheme: CohortScheme, cohort: Cohort)] {
        guard let contextID else { return [] }
        let schemes = canonical.cohortSchemes.filter { $0.contextID == contextID && $0.archivedAt == nil }
        let schemeByID = Dictionary(uniqueKeysWithValues: schemes.map { ($0.id, $0) })
        return canonical.cohorts
            .filter { $0.archivedAt == nil && schemeByID[$0.schemeID] != nil }
            .compactMap { cohort in schemeByID[cohort.schemeID].map { ($0, cohort) } }
            .sorted {
                let first = $0.0.name.fallback + " " + $0.1.labels.fallback
                let second = $1.0.name.fallback + " " + $1.1.labels.fallback
                return first.localizedStandardCompare(second) == .orderedAscending
            }
    }
    private var availableRoles: [RoleDefinition] {
        guard let contextID else { return [] }
        return canonical.roleDefinitions.filter { $0.contextID == contextID && $0.archivedAt == nil }
            .sorted { $0.labels.fallback.localizedStandardCompare($1.labels.fallback) == .orderedAscending }
    }
    private var roleIsPresent: Bool {
        roleDefinitionID != nil || !roleLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var datesAreValid: Bool {
        PartialDateRange.isOrdered(start: startDate, end: endDate) &&
            PartialDateRange.isOrdered(start: assignmentStartDate, end: assignmentEndDate) &&
            PartialDateRange.isOrdered(start: roleStartDate, end: roleEndDate)
    }
    private var canSave: Bool { contextID != nil && datesAreValid && partialDateInputsValid && !hasOverlappingPrimary }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if contexts.isEmpty {
                        ContentUnavailableView {
                            Label("Create a context first", systemImage: "square.stack.3d.up.badge.plus")
                        } description: {
                            Text("Membership needs an organization, program, school, club, team, or other context.")
                        } actions: {
                            Button("Create Context") { showingContextEditor = true }
                        }
                    } else {
                        Picker("Context", selection: $contextID) {
                            Text("Choose a context").tag(nil as UUID?)
                            ForEach(contexts) { context in Text(context.names.fallback).tag(context.id as UUID?) }
                        }
                    }
                    Picker("Status", selection: $status) {
                        ForEach(MembershipStatus.allCases, id: \.rawValue) { value in Text(value.structuredTitle).tag(value) }
                    }
                } header: {
                    Text("Membership episode")
                } footer: {
                    Text("Use separate episodes for non-contiguous membership, an alumni return, or simultaneous membership in another context.")
                }

                Section("Membership dates") {
                    StructuredPartialDateField("Starts", value: $startDate)
                    StructuredPartialDateField("Ends", value: $endDate)
                }

                Section {
                    if availableCohorts.isEmpty {
                    Text(contextID == nil
                        ? String(localized: "Choose a context to see its cohorts.")
                        : String(localized: "This context has no cohorts. You can save the membership without one."))
                            .foregroundStyle(AppTheme.secondaryText)
                    } else {
                        Picker("Cohort", selection: $cohortID) {
                            Text("No cohort assignment").tag(nil as UUID?)
                            ForEach(availableCohorts, id: \.cohort.id) { item in
                                Text(item.scheme.name.fallback + " · " + item.cohort.labels.fallback).tag(item.cohort.id as UUID?)
                            }
                        }
                    }
                    if cohortID != nil {
                        Picker("Assignment kind", selection: $assignmentKind) {
                            ForEach(CohortAssignmentKind.allCases, id: \.rawValue) { value in Text(value.structuredTitle).tag(value) }
                        }
                        Toggle("Primary assignment for overlapping dates", isOn: $assignmentIsPrimary)
                        StructuredPartialDateField("Assignment starts", value: $assignmentStartDate)
                        StructuredPartialDateField("Assignment ends", value: $assignmentEndDate)
                        if hasOverlappingPrimary {
                            Label("This would overlap another primary cohort assignment in the same episode.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text(originalCohortAssignment == nil
                        ? String(localized: "Add cohort assignment (optional)")
                        : String(localized: "Cohort assignment"))
                } footer: {
                    Text("Transfers, repeats, and secondary cohorts are additional dated assignments. Existing assignments are not overwritten.")
                }

                Section {
                    Picker("Defined role", selection: $roleDefinitionID) {
                        Text("Custom or no role").tag(nil as UUID?)
                        ForEach(availableRoles) { role in Text(role.labels.fallback).tag(role.id as UUID?) }
                    }
                    TextField("Role label", text: $roleLabel)
                    TextField("Japanese role label (optional)", text: $roleJapaneseLabel)
                    if roleIsPresent {
                        StructuredPartialDateField("Role starts", value: $roleStartDate)
                        StructuredPartialDateField("Role ends", value: $roleEndDate)
                    }
                } header: {
                    Text(originalRoleAssignment == nil
                        ? String(localized: "Add role (optional)")
                        : String(localized: "Role assignment"))
                } footer: {
                    Text("Roles are independent of cohorts. Add another dated role instead of replacing simultaneous or historic roles.")
                }

                if !datesAreValid {
                    Section {
                        Label("A start date must not follow its end date.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if let validationMessage {
                    Section { Label(validationMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .onPreferenceChange(StructuredPartialDateValidityKey.self) { partialDateInputsValid = $0 }
            .navigationTitle(originalMembership == nil
                ? String(localized: "New Membership")
                : String(localized: "Edit Membership"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .task {
                if contextID == nil, let first = contexts.first { contextID = first.id }
                synchronizeLinkedSelections()
            }
            .onChange(of: contextID) { oldID, newID in
                guard oldID != nil, oldID != newID else { return }
                cohortID = nil
                roleDefinitionID = nil
                roleLabel = ""
                roleJapaneseLabel = ""
            }
            .onChange(of: roleDefinitionID) { _, definitionID in
                guard let definitionID, let definition = availableRoles.first(where: { $0.id == definitionID }) else { return }
                roleLabel = definition.labels.fallback
                roleJapaneseLabel = definition.labels.localized["ja"] ?? ""
            }
            .sheet(isPresented: $showingContextEditor) { ContextEditorView() }
        }
        #if os(macOS)
        .keepsakeSheetSize(minWidth: 600, minHeight: 760)
        #endif
    }

    private var hasOverlappingPrimary: Bool {
        guard assignmentIsPrimary, cohortID != nil, let membershipID = originalMembership?.id else { return false }
        let ownID = originalCohortAssignment?.id
        let proposedStart = assignmentStartDate?.earliestInstant ?? .distantPast
        let proposedEnd = assignmentEndDate?.latestInstant ?? .distantFuture
        return canonical.cohortAssignments.contains { assignment in
            guard assignment.membershipEpisodeID == membershipID,
                  assignment.id != ownID,
                  assignment.isPrimary else { return false }
            let existingStart = assignment.startDate?.earliestInstant ?? .distantPast
            let existingEnd = assignment.endDate?.latestInstant ?? .distantFuture
            return proposedStart <= existingEnd && existingStart <= proposedEnd
        }
    }

    private func synchronizeLinkedSelections() {
        if let cohortID,
           !availableCohorts.contains(where: { $0.cohort.id == cohortID }) {
            self.cohortID = nil
        }
        if let roleDefinitionID,
           !availableRoles.contains(where: { $0.id == roleDefinitionID }) {
            self.roleDefinitionID = nil
        }
    }

    private func save() {
        validationMessage = nil
        guard let contextID, canSave else {
            validationMessage = String(localized: "Choose a valid context and review the dated assignments.")
            return
        }
        let now = Date.now
        let membershipID = originalMembership?.id ?? UUID()
        let membership = MembershipEpisode(
            id: membershipID,
            personID: person.id,
            contextID: contextID,
            startDate: startDate,
            endDate: endDate,
            status: status,
            assertionID: originalMembership?.assertionID,
            createdAt: originalMembership?.createdAt ?? now,
            modifiedAt: now,
            schemaRevision: originalMembership?.schemaRevision ?? 1
        )

        var cohortValue: CohortAssignment?
        if let cohortID {
            cohortValue = CohortAssignment(
                id: originalCohortAssignment?.id ?? UUID(),
                membershipEpisodeID: membershipID,
                cohortID: cohortID,
                startDate: assignmentStartDate,
                endDate: assignmentEndDate,
                assignmentKind: assignmentKind,
                isPrimary: assignmentIsPrimary,
                assertionID: originalCohortAssignment?.assertionID,
                createdAt: originalCohortAssignment?.createdAt ?? now,
                modifiedAt: now,
                schemaRevision: originalCohortAssignment?.schemaRevision ?? 1
            )
        }

        var roleValue: RoleAssignment?
        let trimmedRole = roleLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRole.isEmpty {
            let japanese = roleJapaneseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            roleValue = RoleAssignment(
                id: originalRoleAssignment?.id ?? UUID(),
                membershipEpisodeID: membershipID,
                roleDefinitionID: roleDefinitionID,
                roleLabel: LocalizedText(trimmedRole, localized: japanese.isEmpty ? [:] : ["ja": japanese]),
                startDate: roleStartDate,
                endDate: roleEndDate,
                assertionID: originalRoleAssignment?.assertionID,
                createdAt: originalRoleAssignment?.createdAt ?? now,
                modifiedAt: now,
                schemaRevision: originalRoleAssignment?.schemaRevision ?? 1
            )
        }

        canonical.save(membership)
        if let cohortValue { canonical.save(cohortValue) }
        else if let originalCohortAssignment { canonical.delete(originalCohortAssignment, kind: "cohortAssignment") }
        if let roleValue { canonical.save(roleValue) }
        else if let originalRoleAssignment { canonical.delete(originalRoleAssignment, kind: "roleAssignment") }
        dismiss()
    }
}

struct EducationEditorView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss
    let person: Person
    private let original: EducationEnrollment?

    @State private var institutionID: UUID?
    @State private var program: String
    @State private var programJapanese: String
    @State private var degree: String
    @State private var degreeJapanese: String
    @State private var status: EducationStatus
    @State private var startDate: PartialDate?
    @State private var endDate: PartialDate?
    @State private var expectedGraduation: PartialDate?
    @State private var actualGraduation: PartialDate?
    @State private var validationMessage: String?
    @State private var showingContextEditor = false
    @State private var partialDateInputsValid = true

    init(person: Person, enrollment: EducationEnrollment? = nil) {
        self.person = person
        self.original = enrollment
        _institutionID = State(initialValue: enrollment?.institutionContextID)
        _program = State(initialValue: enrollment?.program?.fallback ?? "")
        _programJapanese = State(initialValue: enrollment?.program?.localized["ja"] ?? "")
        _degree = State(initialValue: enrollment?.degree?.fallback ?? "")
        _degreeJapanese = State(initialValue: enrollment?.degree?.localized["ja"] ?? "")
        _status = State(initialValue: enrollment?.status ?? .unknown)
        _startDate = State(initialValue: enrollment?.startDate)
        _endDate = State(initialValue: enrollment?.endDate)
        _expectedGraduation = State(initialValue: enrollment?.expectedGraduation)
        _actualGraduation = State(initialValue: enrollment?.actualGraduation)
    }

    private var institutions: [Context] {
        canonical.contexts.filter { $0.archivedAt == nil }
            .sorted {
                let firstPriority = $0.kind == .university || $0.kind == .school ? 0 : 1
                let secondPriority = $1.kind == .university || $1.kind == .school ? 0 : 1
                return (firstPriority, $0.names.fallback) < (secondPriority, $1.names.fallback)
            }
    }
    private var datesAreValid: Bool {
        guard PartialDateRange.isOrdered(start: startDate, end: endDate) else { return false }
        if let actualGraduation, let startDate,
           actualGraduation.latestInstant < startDate.earliestInstant { return false }
        return true
    }
    private var canSave: Bool { institutionID != nil && datesAreValid && partialDateInputsValid }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if institutions.isEmpty {
                        Button("Create an institution context") { showingContextEditor = true }
                    } else {
                        Picker("Institution", selection: $institutionID) {
                            Text("Choose an institution").tag(nil as UUID?)
                            ForEach(institutions) { context in
                                Text(context.names.fallback + " · " + context.kind.structuredTitle).tag(context.id as UUID?)
                            }
                        }
                    }
                    TextField("Program or field", text: $program)
                    TextField("Program in Japanese (optional)", text: $programJapanese)
                    TextField("Degree (optional)", text: $degree)
                    TextField("Degree in Japanese (optional)", text: $degreeJapanese)
                    Picker("Enrollment status", selection: $status) {
                        ForEach(EducationStatus.allCases, id: \.rawValue) { value in Text(value.structuredTitle).tag(value) }
                    }
                } header: {
                    Text("Enrollment")
                }

                Section("Enrollment dates") {
                    StructuredPartialDateField("Starts", value: $startDate)
                    StructuredPartialDateField("Ends", value: $endDate)
                }

                Section {
                    StructuredPartialDateField("Expected graduation", value: $expectedGraduation)
                    StructuredPartialDateField("Actual graduation", value: $actualGraduation)
                    if let expectedGraduation, actualGraduation == nil {
                        Label("Expected \(expectedGraduation.description) — not recorded as graduated", systemImage: "calendar.badge.clock")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                    if let actualGraduation {
                        Label("Explicitly recorded as graduated \(actualGraduation.description)", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(AppTheme.accent)
                    }
                } header: {
                    Text("University graduation")
                } footer: {
                    Text("Keepsake never infers graduation from age, cohort, employment, scholarship completion, or an expected date.")
                }

                if !datesAreValid {
                    Section {
                        Label("Review the date order. Actual graduation cannot precede enrollment.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if let validationMessage {
                    Section { Label(validationMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .onPreferenceChange(StructuredPartialDateValidityKey.self) { partialDateInputsValid = $0 }
            .navigationTitle(original == nil
                ? String(localized: "New Education Record")
                : String(localized: "Edit Education"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .task { if institutionID == nil { institutionID = institutions.first?.id } }
            .sheet(isPresented: $showingContextEditor) {
                ContextEditorView(context: nil, proposedParentID: nil)
            }
        }
        #if os(macOS)
        .keepsakeSheetSize(minWidth: 600, minHeight: 740)
        #endif
    }

    private func localized(_ fallback: String, japanese: String) -> LocalizedText? {
        let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let japanese = japanese.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty || !japanese.isEmpty else { return nil }
        let resolvedFallback = fallback.isEmpty ? japanese : fallback
        return LocalizedText(resolvedFallback, localized: japanese.isEmpty ? [:] : ["ja": japanese])
    }

    private func save() {
        validationMessage = nil
        guard let institutionID, canSave else {
            validationMessage = String(localized: "Choose an institution and review the enrollment dates.")
            return
        }
        let now = Date.now
        canonical.save(EducationEnrollment(
            id: original?.id ?? UUID(),
            personID: person.id,
            institutionContextID: institutionID,
            program: localized(program, japanese: programJapanese),
            degree: localized(degree, japanese: degreeJapanese),
            startDate: startDate,
            endDate: endDate,
            expectedGraduation: expectedGraduation,
            actualGraduation: actualGraduation,
            status: status,
            assertionID: original?.assertionID,
            createdAt: original?.createdAt ?? now,
            modifiedAt: now,
            schemaRevision: original?.schemaRevision ?? 1
        ))
        dismiss()
    }
}

// MARK: - Source-aware manual facts

struct ManualFactEditorView: View {
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss

    let person: Person
    private let original: AssertionEnvelope?
    private let newDefinitionID: UUID
    private let newPredicateID: String

    @State private var fieldName: String
    @State private var selectedDefinitionID: UUID?
    @State private var valueKind: AttributeValueKind
    @State private var textValue: String
    @State private var booleanValue: Bool
    @State private var numberValue: String
    @State private var unitCode: String
    @State private var partialDate: PartialDate?
    @State private var rangeStart: PartialDate?
    @State private var rangeEnd: PartialDate?
    @State private var referencedContextID: UUID?

    @State private var sourceNote: String
    @State private var certainty: AssertionCertainty
    @State private var reviewStatus: AssertionReviewStatus
    @State private var hasConfidence: Bool
    @State private var confidencePercent: Double
    @State private var observedAt: Date
    @State private var validFrom: PartialDate?
    @State private var validTo: PartialDate?
    @State private var sensitivity: Sensitivity
    @State private var searchPolicy: SearchUsePolicy
    @State private var remindersAllowed: Bool
    @State private var notificationPolicy: NotificationUsePolicy
    @State private var sharingPolicy: SharingUsePolicy
    @State private var mentionPolicy: MentionPolicy
    @State private var aiPolicy: AIPolicy
    @State private var validationMessage: String?
    @State private var partialDateInputsValid = true

    init(person: Person, assertion: AssertionEnvelope? = nil, fieldName: String = "") {
        self.person = person
        self.original = assertion
        let definitionID = UUID()
        self.newDefinitionID = definitionID
        self.newPredicateID = "custom.manual.\(definitionID.uuidString.lowercased())"
        _fieldName = State(initialValue: fieldName)
        _selectedDefinitionID = State(initialValue: nil)
        _valueKind = State(initialValue: assertion?.value.kind ?? .text)

        let initialText: String
        let initialBool: Bool
        let initialNumber: String
        let initialUnit: String
        let initialDate: PartialDate?
        let initialRangeStart: PartialDate?
        let initialRangeEnd: PartialDate?
        let initialContextID: UUID?
        if let assertion {
            switch assertion.value {
            case let .text(value), let .richText(value), let .language(value), let .email(value), let .phone(value):
                initialText = value
            case let .url(value):
                initialText = value.absoluteString
            case let .location(value):
                initialText = value.label
            default:
                initialText = ""
            }
            if case let .boolean(value) = assertion.value { initialBool = value } else { initialBool = false }
            if case let .number(value) = assertion.value {
                initialNumber = NSDecimalNumber(decimal: value.value).stringValue
                initialUnit = value.unitCode ?? ""
            } else {
                initialNumber = ""
                initialUnit = ""
            }
            if case let .partialDate(value) = assertion.value { initialDate = value } else { initialDate = nil }
            if case let .dateRange(value) = assertion.value {
                initialRangeStart = value.start
                initialRangeEnd = value.end
            } else {
                initialRangeStart = nil
                initialRangeEnd = nil
            }
            if case let .contextReference(value) = assertion.value { initialContextID = value } else { initialContextID = nil }
        } else {
            initialText = ""
            initialBool = false
            initialNumber = ""
            initialUnit = ""
            initialDate = nil
            initialRangeStart = nil
            initialRangeEnd = nil
            initialContextID = nil
        }
        _textValue = State(initialValue: initialText)
        _booleanValue = State(initialValue: initialBool)
        _numberValue = State(initialValue: initialNumber)
        _unitCode = State(initialValue: initialUnit)
        _partialDate = State(initialValue: initialDate)
        _rangeStart = State(initialValue: initialRangeStart)
        _rangeEnd = State(initialValue: initialRangeEnd)
        _referencedContextID = State(initialValue: initialContextID)
        _sourceNote = State(initialValue: "")
        _certainty = State(initialValue: assertion?.certainty ?? .exact)
        _reviewStatus = State(initialValue: assertion?.reviewStatus ?? .accepted)
        _hasConfidence = State(initialValue: assertion?.confidence != nil)
        _confidencePercent = State(initialValue: (assertion?.confidence ?? 1) * 100)
        _observedAt = State(initialValue: assertion?.observedAt ?? .now)
        _validFrom = State(initialValue: assertion?.validFrom)
        _validTo = State(initialValue: assertion?.validTo)
        _sensitivity = State(initialValue: assertion?.sensitivity ?? .private)
        _searchPolicy = State(initialValue: assertion?.usePolicy.search ?? .include)
        _remindersAllowed = State(initialValue: assertion?.usePolicy.remindersAllowed ?? true)
        _notificationPolicy = State(initialValue: assertion?.usePolicy.notifications ?? .genericOnly)
        _sharingPolicy = State(initialValue: assertion?.usePolicy.sharing ?? .exclude)
        _mentionPolicy = State(initialValue: assertion?.usePolicy.mention ?? .ask)
        let storedAIPolicy = assertion?.usePolicy.ai ?? .deny
        _aiPolicy = State(initialValue: storedAIPolicy == .allowConfiguredShortcut
            ? .allowConfiguredShortcut
            : .deny)
    }

    private var supportedKinds: [AttributeValueKind] {
        [.text, .richText, .boolean, .number, .partialDate, .dateRange, .language, .url, .email, .phone, .location, .contextReference]
    }
    private var trimmedFieldName: String { fieldName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var activeDefinitions: [AttributeDefinition] {
        canonical.attributeDefinitions
            .filter { $0.archivedAt == nil && supportedKinds.contains($0.valueKind) }
            .sorted {
                $0.labels.fallback.localizedStandardCompare($1.labels.fallback) == .orderedAscending
            }
    }
    private var selectedDefinition: AttributeDefinition? {
        guard let selectedDefinitionID else { return nil }
        return canonical.attributeDefinitions.first { $0.id == selectedDefinitionID }
    }
    private var originalDefinition: AttributeDefinition? {
        guard let original else { return nil }
        return canonical.attributeDefinitions.first { $0.predicateID == original.predicateID }
    }
    private var fieldCredentialWarning: String? {
        SensitiveFieldPolicy.credentialWarning(for: trimmedFieldName) ??
            CredentialFieldGuard.blockingMessage(for: trimmedFieldName)
    }
    private var valueCredentialWarning: String? {
        switch valueKind {
        case .text, .richText, .language, .url, .email, .phone, .location:
            SensitiveFieldPolicy.credentialWarning(forFactValue: .text(textValue))
        default:
            nil
        }
    }
    private var sourceCredentialWarning: String? {
        SensitiveFieldPolicy.credentialWarning(forPrivateNote: sourceNote)
    }
    private var credentialWarning: String? {
        fieldCredentialWarning ?? valueCredentialWarning ?? sourceCredentialWarning
    }
    private var validValidityRange: Bool { PartialDateRange.isOrdered(start: validFrom, end: validTo) }
    private var canSave: Bool {
        !trimmedFieldName.isEmpty && credentialWarning == nil && validValidityRange &&
            partialDateInputsValid && supportedKinds.contains(valueKind) &&
            (original == nil || !sourceNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var authoritativeDefinition: AttributeDefinition? {
        originalDefinition ?? selectedDefinition
    }
    private var allowedSensitivities: [Sensitivity] {
        guard let definition = authoritativeDefinition else { return Sensitivity.allCases }
        return Sensitivity.allCases.filter(definition.permitsFactSensitivity)
    }
    private var allowedSearchPolicies: [SearchUsePolicy] {
        authoritativeDefinition?.permittedFactUsePolicy.search == .exclude
            ? [.exclude] : SearchUsePolicy.allCases
    }
    private var allowedNotificationPolicies: [NotificationUsePolicy] {
        switch authoritativeDefinition?.permittedFactUsePolicy.notifications {
        case .exclude: [.exclude]
        case .genericOnly: [.exclude, .genericOnly]
        case .includeValue, nil: NotificationUsePolicy.allCases
        }
    }
    private var allowedSharingPolicies: [SharingUsePolicy] {
        authoritativeDefinition?.permittedFactUsePolicy.sharing == .exclude
            ? [.exclude] : SharingUsePolicy.allCases
    }
    private var allowedMentionPolicies: [MentionPolicy] {
        switch authoritativeDefinition?.permittedFactUsePolicy.mention {
        case .never: [.never]
        case .ask: [.never, .ask]
        case .allow, nil: MentionPolicy.allCases
        }
    }
    private var allowedAIPolicies: [AIPolicy] {
        authoritativeDefinition?.permittedFactUsePolicy.ai == .allowConfiguredShortcut ||
            authoritativeDefinition == nil
            ? [.deny, .allowConfiguredShortcut] : [.deny]
    }

    private var currentUsePolicy: AssertionUsePolicy {
        AssertionUsePolicy(
            search: searchPolicy,
            remindersAllowed: remindersAllowed,
            notifications: notificationPolicy,
            sharing: sharingPolicy,
            mention: mentionPolicy,
            ai: aiPolicy
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if let original {
                    Section {
                        Label("This correction will create a new manual version. The existing \(original.origin.structuredTitle.lowercased()) version and its source remain in history.", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline)
                        LabeledContent("Existing source", value: existingSourceDescription(original))
                        LabeledContent("Originally asserted") {
                            Text(original.assertedAt, format: .dateTime.year().month().day().hour().minute())
                        }
                        LabeledContent("Review state", value: original.reviewStatus.structuredTitle)
                    } header: {
                        Text("Version history")
                    }
                }

                Section {
                    if original == nil {
                        Picker("Custom field", selection: $selectedDefinitionID) {
                            Text("Create a new field").tag(nil as UUID?)
                            ForEach(activeDefinitions) { definition in
                                Text(definition.labels.fallback).tag(definition.id as UUID?)
                            }
                        }
                    }
                    TextField("Field name", text: $fieldName)
                        .disabled(original != nil || selectedDefinitionID != nil)
                    Picker("Value type", selection: $valueKind) {
                        ForEach(supportedKinds, id: \.rawValue) { kind in Text(kind.structuredTitle).tag(kind) }
                        if !supportedKinds.contains(valueKind) {
                            Text(valueKind.structuredTitle + String(localized: " (view only)")).tag(valueKind)
                        }
                    }
                    .disabled(original != nil || selectedDefinitionID != nil)
                    factValueEditor
                } header: {
                    Text("Fact")
                } footer: {
                    if original != nil {
                        Text("A field's type is stable. Create a new field if the meaning or value type changes.")
                    }
                }

                if let credentialWarning {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Credentials and secrets are blocked", systemImage: "key.slash.fill")
                                .font(.headline).foregroundStyle(.red)
                            Text(credentialWarning)
                            Text("Use a trusted password manager or the appropriate secure financial or identity service instead.")
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }

                Section {
                    TextField("How you know this (optional)", text: $sourceNote, axis: .vertical)
                        .lineLimit(2...5)
                    DatePicker("Observed", selection: $observedAt, displayedComponents: [.date])
                    Picker("Certainty", selection: $certainty) {
                        ForEach(AssertionCertainty.allCases, id: \.rawValue) { value in Text(value.structuredTitle).tag(value) }
                    }
                    Picker("Review status", selection: $reviewStatus) {
                        ForEach(AssertionReviewStatus.allCases, id: \.rawValue) { value in
                            Text(value.structuredTitle).tag(value)
                        }
                    }
                    Toggle("Record confidence", isOn: $hasConfidence)
                    if hasConfidence {
                        LabeledContent("Confidence", value: "\(Int(confidencePercent))%")
                        Slider(value: $confidencePercent, in: 0...100, step: 1)
                            .accessibilityLabel("Confidence")
                            .accessibilityValue("\(Int(confidencePercent)) percent")
                    }
                } header: {
                    Text("Source & timing")
                } footer: {
                    Text(original == nil
                         ? String(localized: "An optional source note is stored as a private user-note artifact. It is not evidence from AI and is never shared automatically.")
                         : String(localized: "Describe why this correction is being made. The explanation becomes the new version’s private source; the prior source remains in history."))
                }

                Section("Valid period (optional)") {
                    StructuredPartialDateField("Valid from", value: $validFrom)
                    StructuredPartialDateField("Valid through", value: $validTo)
                    if !validValidityRange {
                        Label("The valid-from date must not follow the valid-through date.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Sensitivity", selection: $sensitivity) {
                        ForEach(allowedSensitivities, id: \.rawValue) { value in Text(value.structuredTitle).tag(value) }
                    }
                    Picker("Conversation mentions", selection: $mentionPolicy) {
                        ForEach(allowedMentionPolicies, id: \.rawValue) { value in Text(value.structuredTitle).tag(value) }
                    }
                    Picker("AI processing", selection: $aiPolicy) {
                        ForEach(allowedAIPolicies, id: \.rawValue) { value in Text(value.structuredTitle).tag(value) }
                    }
                } header: {
                    Text("Privacy controls")
                } footer: {
                    if authoritativeDefinition != nil {
                        Text("The selected custom field sets the maximum allowed uses. This fact can be made more private, but not broader than those defaults.")
                    } else {
                        Text("Mention and AI permissions are independent. Shortcut access requires explicit permission; earlier native-model permissions are not migrated.")
                    }
                }

                Section("Other permitted uses") {
                    Picker("Search", selection: $searchPolicy) {
                        ForEach(allowedSearchPolicies, id: \.rawValue) { value in Text(value.structuredTitle).tag(value) }
                    }
                    Toggle("May support reminders", isOn: $remindersAllowed)
                        .disabled(authoritativeDefinition?.permittedFactUsePolicy.remindersAllowed == false)
                    Picker("Notification previews", selection: $notificationPolicy) {
                        ForEach(allowedNotificationPolicies, id: \.rawValue) { value in Text(value.structuredTitle).tag(value) }
                    }
                    Picker("Profile sharing", selection: $sharingPolicy) {
                        ForEach(allowedSharingPolicies, id: \.rawValue) { value in Text(value.structuredTitle).tag(value) }
                    }
                }

                if let validationMessage {
                    Section { Label(validationMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .onPreferenceChange(StructuredPartialDateValidityKey.self) { partialDateInputsValid = $0 }
            .navigationTitle(original == nil
                ? String(localized: "New Fact")
                : String(localized: "Correct Fact"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .onAppear(perform: selectInitialDefinitionIfNeeded)
            .onChange(of: selectedDefinitionID) { _, _ in
                if let selectedDefinition { applyDefaults(from: selectedDefinition) }
            }
            .onChange(of: sensitivity) { _, newValue in
                if newValue == .highlySensitive {
                    mentionPolicy = .never
                    aiPolicy = .deny
                    searchPolicy = .exclude
                    remindersAllowed = false
                    notificationPolicy = .exclude
                    sharingPolicy = .exclude
                }
            }
        }
        #if os(macOS)
        .keepsakeSheetSize(minWidth: 620, minHeight: 820)
        #endif
    }

    private func selectInitialDefinitionIfNeeded() {
        if let originalDefinition {
            applyLimits(from: originalDefinition)
            return
        }
        guard selectedDefinitionID == nil else { return }
        if let match = activeDefinitions.first(where: {
            $0.labels.fallback.compare(
                trimmedFieldName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }) {
            selectedDefinitionID = match.id
        }
    }

    private func applyDefaults(from definition: AttributeDefinition) {
        fieldName = definition.labels.fallback
        valueKind = definition.valueKind
        sensitivity = definition.defaultSensitivity
        assign(definition.permittedFactUsePolicy)
    }

    private func applyLimits(from definition: AttributeDefinition) {
        if !definition.permitsFactSensitivity(sensitivity) {
            sensitivity = definition.defaultSensitivity
        }
        assign(definition.factUsePolicyByApplyingLimits(to: currentUsePolicy))
    }

    private func assign(_ policy: AssertionUsePolicy) {
        searchPolicy = policy.search
        remindersAllowed = policy.remindersAllowed
        notificationPolicy = policy.notifications
        sharingPolicy = policy.sharing
        mentionPolicy = policy.mention
        aiPolicy = policy.ai == .allowConfiguredShortcut ? .allowConfiguredShortcut : .deny
    }

    @ViewBuilder
    private var factValueEditor: some View {
        switch valueKind {
        case .text:
            TextField("Value", text: $textValue)
        case .richText:
            TextEditor(text: $textValue).frame(minHeight: 110)
        case .boolean:
            Toggle("Value", isOn: $booleanValue)
        case .number:
            TextField("Number", text: $numberValue)
            #if os(iOS)
                .keyboardType(.decimalPad)
            #endif
            TextField("Unit code (optional)", text: $unitCode)
        case .partialDate:
            StructuredPartialDateField("Date", value: $partialDate)
        case .dateRange:
            StructuredPartialDateField("Range starts", value: $rangeStart)
            StructuredPartialDateField("Range ends", value: $rangeEnd)
        case .language:
            TextField("Language or BCP-47 code", text: $textValue)
        case .url:
            TextField("URL including scheme", text: $textValue)
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            #endif
        case .email:
            TextField("Email", text: $textValue)
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            #endif
        case .phone:
            TextField("Phone", text: $textValue)
            #if os(iOS)
                .keyboardType(.phonePad)
            #endif
        case .location:
            TextField("Location label", text: $textValue)
        case .contextReference:
            Picker("Context", selection: $referencedContextID) {
                Text("Choose a context").tag(nil as UUID?)
                ForEach(canonical.contexts.filter { $0.archivedAt == nil }) { context in
                    Text(context.names.fallback).tag(context.id as UUID?)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 7) {
                Text(original?.value.structuredDisplay ?? String(localized: "Unsupported value"))
                Label("This value type is preserved but cannot be edited in the manual fact editor.", systemImage: "lock.doc")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private func existingSourceDescription(_ assertion: AssertionEnvelope) -> String {
        guard let sourceID = assertion.sourceID,
              let source = canonical.sources.first(where: { $0.id == sourceID }) else {
            return assertion.origin.structuredTitle
        }
        return source.originalFilename ?? source.kind.structuredTitle
    }

    private func buildValue() throws -> TypedValue {
        let text = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch valueKind {
        case .text:
            guard !text.isEmpty else { throw StructuredEditorError(String(localized: "Enter a value.")) }
            return .text(text)
        case .richText:
            guard !text.isEmpty else { throw StructuredEditorError(String(localized: "Enter a value.")) }
            return .richText(text)
        case .boolean:
            return .boolean(booleanValue)
        case .number:
            guard let decimal = Decimal(string: numberValue, locale: Locale(identifier: "en_US_POSIX")) else {
                throw StructuredEditorError(String(localized: "Enter a valid number using a decimal point when needed."))
            }
            return .number(MeasuredDecimal(value: decimal, unitCode: unitCode.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty))
        case .partialDate:
            guard let partialDate else { throw StructuredEditorError(String(localized: "Enter a date.")) }
            return .partialDate(partialDate)
        case .dateRange:
            do { return .dateRange(try PartialDateRange(start: rangeStart, end: rangeEnd)) }
            catch { throw StructuredEditorError(String(localized: "Enter at least one range boundary and check their order.")) }
        case .language:
            guard !text.isEmpty else { throw StructuredEditorError(String(localized: "Enter a language or language code.")) }
            return .language(text)
        case .url:
            guard let URL = URL(string: text), URL.scheme != nil else {
                throw StructuredEditorError(String(localized: "Enter a complete URL, including https:// or another scheme."))
            }
            return .url(URL)
        case .email:
            guard text.contains("@"), !text.hasPrefix("@"), !text.hasSuffix("@") else {
                throw StructuredEditorError(String(localized: "Enter a valid email address."))
            }
            return .email(text)
        case .phone:
            guard !text.isEmpty else { throw StructuredEditorError(String(localized: "Enter a phone number.")) }
            return .phone(text)
        case .location:
            guard !text.isEmpty else { throw StructuredEditorError(String(localized: "Enter a location label.")) }
            return .location(LocationValue(label: text))
        case .contextReference:
            guard let referencedContextID else { throw StructuredEditorError(String(localized: "Choose a context.")) }
            return .contextReference(referencedContextID)
        default:
            throw StructuredEditorError(String(localized: "This value type cannot be edited here."))
        }
    }

    private func save() {
        validationMessage = nil
        guard credentialWarning == nil else {
            validationMessage = String(localized: "Credential-oriented fields cannot be stored in Keepsake.")
            return
        }
        do {
            let typedValue = try buildValue()
            let existingDefinition = originalDefinition
            let reusableDefinition = original == nil ? canonical.attributeDefinitions.first {
                $0.id == selectedDefinitionID || ($0.archivedAt == nil &&
                    $0.labels.fallback.compare(trimmedFieldName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                )
            } : nil
            if let reusableDefinition, reusableDefinition.valueKind != valueKind {
                throw StructuredEditorError(String(localized: "A field with this name already exists with type \(reusableDefinition.valueKind.structuredTitle). Use a different name."))
            }
            let definition = existingDefinition ?? reusableDefinition
            let policy = definition?.factUsePolicyByApplyingLimits(to: currentUsePolicy)
                ?? currentUsePolicy
            let factSensitivity = definition.map {
                $0.permitsFactSensitivity(sensitivity) ? sensitivity : $0.defaultSensitivity
            } ?? sensitivity
            let predicateID = original?.predicateID ?? reusableDefinition?.predicateID ?? newPredicateID

            let sourceText = sourceNote.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = sourceText.isEmpty ? nil : SourceArtifact(
                kind: .userNote,
                originalFilename: sourceText,
                retentionPolicy: .discardOriginalAfterExtraction,
                aiPolicy: policy.ai
            )
            let assertion = try AssertionEnvelope(
                subjectID: person.id,
                predicateID: predicateID,
                value: typedValue,
                sourceID: source?.id,
                origin: .manual,
                confidence: hasConfidence ? confidencePercent / 100 : nil,
                reviewStatus: reviewStatus,
                certainty: certainty,
                observedAt: observedAt,
                assertedAt: .now,
                validFrom: validFrom,
                validTo: validTo,
                sensitivity: factSensitivity,
                usePolicy: policy,
                supersedesID: original?.id,
                schemaRevision: original?.schemaRevision ?? 1
            )

            let newDefinition: AttributeDefinition? = if original == nil, reusableDefinition == nil {
                AttributeDefinition(
                    id: newDefinitionID,
                    predicateID: predicateID,
                    labels: LocalizedText(trimmedFieldName),
                    valueKind: valueKind,
                    cardinality: .single,
                    defaultSensitivity: factSensitivity,
                    defaultUsePolicy: policy,
                    capabilities: AttributeCapabilities(
                        supportsSearch: policy.search == .include,
                        supportsFilter: typedValue.isQueryable,
                        supportsSort: typedValue.isQueryable,
                        supportsReminders: policy.remindersAllowed,
                        supportsAI: policy.ai != .deny,
                        supportsConversationMentions: policy.mention != .never,
                        supportsProfileSharing: policy.sharing != .exclude
                    )
                )
            } else {
                nil
            }

            // Validate against the exact chosen/new definition before any
            // supporting records are written. The store repeats this check at
            // persistence time so recommendation and other non-UI writers
            // cannot bypass it.
            try canonical.validateFactWrite(assertion, definition: definition ?? newDefinition)
            if let newDefinition { try canonical.saveAttributeDefinition(newDefinition) }
            if let source { try canonical.saveSourceArtifact(source) }
            try canonical.saveFact(assertion)
            dismiss()
        } catch let error as StructuredEditorError {
            validationMessage = error.message
        } catch {
            validationMessage = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "The fact could not be validated. Review its value and dates.")
        }
    }
}

private struct CredentialFieldGuard {
    private static let blockedPhrases = [
        "password", "passcode", "pin code", "security code", "one-time password", "one time password",
        "otp", "2fa", "mfa", "private key", "secret key", "api key", "api secret", "client secret",
        "access token", "refresh token", "authentication token", "auth token", "session token",
        "recovery code", "backup code", "cvv", "cvc", "card number", "credit card number",
        "debit card number", "bank account number", "routing number", "social security number", "ssn",
        "government authentication", "my number", "マイナンバー", "パスワード", "暗証番号", "秘密鍵",
        "認証コード", "認証トークン", "ワンタイムパスワード", "セキュリティコード", "カード番号",
        "口座番号"
    ]

    static func blockingMessage(for fieldName: String) -> String? {
        let folded = fieldName.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        guard blockedPhrases.contains(where: { phrase in
            folded.contains(phrase.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current))
        }) else { return nil }
        return String(localized: "“\(fieldName)” appears intended for a password, authentication secret, private key, payment credential, or government authentication identifier. This notebook is not a credential vault.")
    }
}

private struct StructuredEditorError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Partial-date input

private struct StructuredPartialDateValidityKey: PreferenceKey {
    static let defaultValue = true

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value && nextValue()
    }
}

/// Edits `PartialDate` without silently converting a year or month into a full
/// day. Invalid intermediate input remains visible and is not committed.
private struct StructuredPartialDateField: View {
    let title: LocalizedStringKey
    @Binding private var value: PartialDate?
    @State private var isPresent: Bool
    @State private var precision: PartialDatePrecision
    @State private var yearText: String
    @State private var month: Int
    @State private var day: Int
    @State private var validationMessage: String?

    init(_ title: LocalizedStringKey, value: Binding<PartialDate?>) {
        self.title = title
        _value = value
        let existing = value.wrappedValue
        _isPresent = State(initialValue: existing != nil)
        _precision = State(initialValue: existing?.precision ?? .year)
        _yearText = State(initialValue: String(existing?.year ?? Calendar.current.component(.year, from: .now)))
        _month = State(initialValue: existing?.month ?? 1)
        _day = State(initialValue: existing?.day ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(title, isOn: $isPresent)
            if isPresent {
                HStack(spacing: 8) {
                    Picker("Precision", selection: $precision) {
                        ForEach(PartialDatePrecision.allCases, id: \.rawValue) { precision in
                            Text(precision.structuredTitle).tag(precision)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 120)
                    TextField("Year", text: $yearText)
                        .frame(minWidth: 66, maxWidth: 86)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                    if precision == .month || precision == .day {
                        Picker("Month", selection: $month) {
                            ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 72)
                    }
                    if precision == .day {
                        Picker("Day", selection: $day) {
                            ForEach(1...31, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 72)
                    }
                    Spacer(minLength: 0)
                }
                if let validationMessage {
                    Text(validationMessage).font(.caption).foregroundStyle(.red)
                } else if let value {
                    Text(value.description).font(.caption.monospacedDigit()).foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
        .onChange(of: isPresent) { _, enabled in
            if enabled { commit() } else { value = nil; validationMessage = nil }
        }
        .onChange(of: precision) { _, _ in commit() }
        .onChange(of: yearText) { _, _ in commit() }
        .onChange(of: month) { _, _ in commit() }
        .onChange(of: day) { _, _ in commit() }
        .preference(
            key: StructuredPartialDateValidityKey.self,
            value: !isPresent || (validationMessage == nil && value != nil)
        )
    }

    private func commit() {
        guard isPresent else { return }
        guard let year = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            value = nil
            validationMessage = String(localized: "Enter a four-digit year.")
            return
        }
        do {
            switch precision {
            case .year:
                value = try PartialDate.year(year)
            case .month:
                value = try PartialDate.month(month, of: year)
            case .day:
                value = try PartialDate.day(day, month: month, year: year)
            }
            validationMessage = nil
        } catch {
            value = nil
            validationMessage = String(localized: "That date is not valid for the selected precision.")
        }
    }
}

// MARK: - Sheet and deletion routes

private struct ContextEditorRoute: Identifiable {
    let id = UUID()
    let context: Context?
    let parentID: UUID?
    static func new(parentID: UUID?) -> Self { Self(context: nil, parentID: parentID) }
    static func edit(_ context: Context) -> Self { Self(context: context, parentID: context.parentContextID) }
}

private struct CohortSchemeEditorRoute: Identifiable {
    let id = UUID()
    let contextID: UUID
    let scheme: CohortScheme?
    static func new(contextID: UUID) -> Self { Self(contextID: contextID, scheme: nil) }
    static func edit(_ scheme: CohortScheme) -> Self { Self(contextID: scheme.contextID, scheme: scheme) }
}

private struct RoleDefinitionEditorRoute: Identifiable {
    let id = UUID()
    let contextID: UUID
    let role: RoleDefinition?
    static func new(contextID: UUID) -> Self { Self(contextID: contextID, role: nil) }
    static func edit(_ role: RoleDefinition) -> Self { Self(contextID: role.contextID, role: role) }
}

private struct CohortEditorRoute: Identifiable {
    let id = UUID()
    let scheme: CohortScheme
    let cohort: Cohort?
    static func new(in scheme: CohortScheme) -> Self { Self(scheme: scheme, cohort: nil) }
    static func edit(_ cohort: Cohort, in scheme: CohortScheme) -> Self { Self(scheme: scheme, cohort: cohort) }
}

private struct MembershipEditorRoute: Identifiable {
    let id = UUID()
    let membership: MembershipEpisode?
    let cohortAssignment: CohortAssignment?
    let roleAssignment: RoleAssignment?

    static let new = Self(membership: nil, cohortAssignment: nil, roleAssignment: nil)
    static func editEpisode(_ value: MembershipEpisode) -> Self {
        Self(membership: value, cohortAssignment: nil, roleAssignment: nil)
    }
    static func addDetail(to value: MembershipEpisode) -> Self {
        Self(membership: value, cohortAssignment: nil, roleAssignment: nil)
    }
    static func editCohort(_ value: CohortAssignment, membership: MembershipEpisode) -> Self {
        Self(membership: membership, cohortAssignment: value, roleAssignment: nil)
    }
    static func editRole(_ value: RoleAssignment, membership: MembershipEpisode) -> Self {
        Self(membership: membership, cohortAssignment: nil, roleAssignment: value)
    }
}

private struct EducationEditorRoute: Identifiable {
    let id = UUID()
    let enrollment: EducationEnrollment?
    static let new = Self(enrollment: nil)
    static func edit(_ value: EducationEnrollment) -> Self { Self(enrollment: value) }
}

private struct ManualFactEditorRoute: Identifiable {
    let id = UUID()
    let assertion: AssertionEnvelope?
    let fieldName: String
    static let new = Self(assertion: nil, fieldName: "")
    static func edit(_ assertion: AssertionEnvelope, fieldName: String) -> Self {
        Self(assertion: assertion, fieldName: fieldName)
    }
}

private struct FactDetailRoute: Identifiable {
    let id = UUID()
    let assertion: AssertionEnvelope
    let fieldName: String
}

private enum StructuredDeleteTarget {
    case membership(MembershipEpisode)
    case cohortAssignment(CohortAssignment)
    case roleAssignment(RoleAssignment)
    case education(EducationEnrollment)
    case assertion(AssertionEnvelope)

    var title: String {
        switch self {
        case .membership: String(localized: "Move this membership and its linked details to Recently Deleted?")
        case .cohortAssignment: String(localized: "Move this cohort assignment to Recently Deleted?")
        case .roleAssignment: String(localized: "Move this role assignment to Recently Deleted?")
        case .education: String(localized: "Move this education record to Recently Deleted?")
        case .assertion: String(localized: "Move this fact version to Recently Deleted?")
        }
    }

    var message: String {
        switch self {
        case .membership:
            String(localized: "Its cohort and role assignments will also be moved. All records remain recoverable under the vault retention policy.")
        case .assertion:
            String(localized: "Only this assertion version is moved. Earlier source-attributed versions are not silently changed.")
        default:
            String(localized: "The record remains recoverable under the vault retention policy.")
        }
    }
}

// MARK: - Display helpers

private struct CanonicalStoreErrorAlert: ViewModifier {
    @EnvironmentObject private var canonical: CanonicalVaultStore

    func body(content: Content) -> some View {
        content.alert(
            "Structured notebook needs attention",
            isPresented: Binding(
                get: { canonical.lastError != nil },
                set: { if !$0 { canonical.lastError = nil } }
            )
        ) {
            Button("OK") { canonical.lastError = nil }
        } message: {
            Text(canonical.lastError ?? "")
        }
    }
}

private extension View {
    func canonicalStoreErrorAlert() -> some View { modifier(CanonicalStoreErrorAlert()) }
}

private func structuredDateRange(_ start: PartialDate?, _ end: PartialDate?) -> String {
    switch (start, end) {
    case let (start?, end?): String(localized: "\(start.description) – \(end.description)")
    case let (start?, nil): String(localized: "From \(start.description)")
    case let (nil, end?): String(localized: "Through \(end.description)")
    case (nil, nil): String(localized: "Dates unknown")
    }
}

private func humanizedPredicate(_ predicate: String) -> String {
    let tail = predicate.split(separator: ".").last.map(String.init) ?? predicate
    let spaced = tail.replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
    return spaced.isEmpty ? String(localized: "Fact") : spaced.capitalized
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension ContextKind {
    var structuredTitle: String {
        switch self {
        case .organization: String(localized: "Organization")
        case .program: String(localized: "Program")
        case .university: String(localized: "University")
        case .school: String(localized: "School")
        case .company: String(localized: "Company")
        case .club: String(localized: "Club")
        case .team: String(localized: "Team")
        case .chapter: String(localized: "Chapter")
        case .track: String(localized: "Track")
        case .project: String(localized: "Project")
        case .community: String(localized: "Community")
        case .other: String(localized: "Other")
        }
    }

    var structuredIcon: String {
        switch self {
        case .organization: "building.2"
        case .program: "rectangle.3.group"
        case .university: "graduationcap"
        case .school: "building.columns"
        case .company: "building"
        case .club: "person.3"
        case .team: "person.2"
        case .chapter: "square.stack.3d.up"
        case .track: "point.topleft.down.curvedto.point.bottomright.up"
        case .project: "hammer"
        case .community: "person.3.sequence"
        case .other: "square.dashed"
        }
    }
}

private extension CohortSchemeKind {
    var structuredTitle: String {
        switch self {
        case .numberedGeneration: String(localized: "Numbered Generation")
        case .entryYear: String(localized: "Entry Year")
        case .graduationClass: String(localized: "Graduation Class")
        case .namedIntake: String(localized: "Named Intake")
        case .seasonalIntake: String(localized: "Seasonal Intake")
        case .projectCycle: String(localized: "Project Cycle")
        case .rollingEntry: String(localized: "Rolling Entry")
        case .unorderedGroup: String(localized: "Unordered Group")
        }
    }
}

private extension CohortOrderingMethod {
    var structuredTitle: String {
        switch self {
        case .chronologicalRank: String(localized: "Explicit chronological rank")
        case .unordered: String(localized: "Unordered")
        }
    }
}

private extension CohortSeniorityRule {
    var structuredTitle: String {
        switch self {
        case .earlierIsSenior: String(localized: "Earlier cohorts are senior in this context")
        case .laterIsSenior: String(localized: "Later cohorts are senior in this context")
        case .noSeniority: String(localized: "No seniority meaning")
        }
    }
}

private extension MembershipStatus {
    var structuredTitle: String {
        switch self {
        case .active: String(localized: "Active")
        case .completed: String(localized: "Completed")
        case .withdrawn: String(localized: "Withdrawn")
        case .transferred: String(localized: "Transferred")
        case .suspended: String(localized: "Suspended")
        case .unknown: String(localized: "Unknown")
        }
    }
}

private extension CohortAssignmentKind {
    var structuredTitle: String {
        switch self {
        case .initial: String(localized: "Initial")
        case .transferred: String(localized: "Transferred")
        case .repeated: String(localized: "Repeated")
        case .secondary: String(localized: "Secondary")
        }
    }
}

private extension EducationStatus {
    var structuredTitle: String {
        switch self {
        case .prospective: String(localized: "Prospective")
        case .enrolled: String(localized: "Enrolled")
        case .leaveOfAbsence: String(localized: "Leave of absence")
        case .completed: String(localized: "Completed")
        case .withdrawn: String(localized: "Withdrawn")
        case .graduated: String(localized: "Graduated (explicit)")
        case .unknown: String(localized: "Unknown")
        }
    }
}

private extension PartialDatePrecision {
    var structuredTitle: String {
        switch self {
        case .year: String(localized: "Year")
        case .month: String(localized: "Month")
        case .day: String(localized: "Day")
        }
    }
}

private extension AttributeValueKind {
    var structuredTitle: String {
        switch self {
        case .text: String(localized: "Text")
        case .richText: String(localized: "Long text")
        case .boolean: String(localized: "Yes / no")
        case .number: String(localized: "Number")
        case .partialDate: String(localized: "Partial date")
        case .dateRange: String(localized: "Date range")
        case .singleSelect: String(localized: "Single selection")
        case .multiSelect: String(localized: "Multiple selections")
        case .language: String(localized: "Language")
        case .url: String(localized: "URL")
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

private extension AssertionCertainty {
    var structuredTitle: String {
        switch self {
        case .exact: String(localized: "Exact")
        case .approximate: String(localized: "Approximate")
        case .unknown: String(localized: "Unknown")
        }
    }
}

private extension Sensitivity {
    var structuredTitle: String {
        switch self {
        case .ordinary: String(localized: "Ordinary")
        case .private: String(localized: "Private")
        case .sensitive: String(localized: "Sensitive")
        case .highlySensitive: String(localized: "Highly sensitive")
        }
    }

    var structuredColor: Color {
        switch self {
        case .ordinary: .secondary
        case .private: AppTheme.accent
        case .sensitive: .orange
        case .highlySensitive: .red
        }
    }
}

private extension MentionPolicy {
    var structuredTitle: String {
        switch self {
        case .allow: String(localized: "Allowed")
        case .ask: String(localized: "Ask first")
        case .never: String(localized: "Never mention")
        }
    }
}

private extension AIPolicy {
    var structuredTitle: String {
        switch self {
        case .deny: String(localized: "Do not use with AI")
        case .allowOnDevice: String(localized: "Not authorized for Keepsake AI · legacy on-device setting")
        case .allowPrivateCloudCompute: String(localized: "Not authorized for Keepsake AI · legacy native PCC setting")
        case .allowConfiguredShortcut: String(localized: "Allow my Keepsake ChatGPT Shortcut")
        }
    }
}

private extension SearchUsePolicy {
    var structuredTitle: String {
        switch self {
        case .include: String(localized: "Include")
        case .exclude: String(localized: "Exclude")
        }
    }
}

private extension NotificationUsePolicy {
    var structuredTitle: String {
        switch self {
        case .exclude: String(localized: "Never include")
        case .genericOnly: String(localized: "Generic notification only")
        case .includeValue: String(localized: "May include the value")
        }
    }
}

private extension SharingUsePolicy {
    var structuredTitle: String {
        switch self {
        case .exclude: String(localized: "Never share")
        case .eligibleAfterPreview: String(localized: "Eligible after final preview")
        }
    }
}

private extension Origin {
    var structuredTitle: String {
        switch self {
        case .manual: String(localized: "Manual entry")
        case .imported: String(localized: "Imported source")
        case .remoteSelf: String(localized: "Shared by this person")
        case .deterministic: String(localized: "Deterministic extraction")
        case .model: String(localized: "AI-proposed")
        }
    }

    var structuredIcon: String {
        switch self {
        case .manual: "hand.draw"
        case .imported: "tray.and.arrow.down"
        case .remoteSelf: "person.text.rectangle"
        case .deterministic: "doc.text.magnifyingglass"
        case .model: "sparkles"
        }
    }
}

private extension AssertionReviewStatus {
    var structuredTitle: String {
        switch self {
        case .pending: String(localized: "Pending review")
        case .accepted: String(localized: "Accepted")
        case .rejected: String(localized: "Rejected")
        case .deferred: String(localized: "Deferred")
        case .conflicted: String(localized: "Conflict")
        }
    }
}

private extension SourceArtifactKind {
    var structuredTitle: String {
        switch self {
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
}

private extension TypedValue {
    var structuredDisplay: String {
        switch self {
        case let .text(value), let .richText(value): value
        case let .boolean(value): value ? String(localized: "Yes") : String(localized: "No")
        case let .number(value):
            [NSDecimalNumber(decimal: value.value).stringValue, value.unitCode].compactMap { $0 }.joined(separator: " ")
        case let .partialDate(value): value.description
        case let .dateRange(value): structuredDateRange(value.start, value.end)
        case let .singleSelect(value): String(localized: "Selection \(value.uuidString.prefix(8))")
        case let .multiSelect(values): String(localized: "\(values.count) selections")
        case let .language(value): value
        case let .url(value): value.absoluteString
        case let .email(value): value
        case let .phone(value): value
        case let .location(value): value.label
        case let .address(value):
            [value.street, value.locality, value.administrativeArea, value.postalCode, value.countryCode]
                .compactMap { $0 }.joined(separator: ", ")
        case let .personReference(value): String(localized: "Person \(value.uuidString.prefix(8))")
        case let .contextReference(value): String(localized: "Context \(value.uuidString.prefix(8))")
        case .mediaReference: String(localized: "Media")
        case .structuredJSON: String(localized: "Structured data")
        }
    }
}
