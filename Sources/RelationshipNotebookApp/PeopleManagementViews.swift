import SwiftUI

struct PersonMergeView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @Environment(\.dismiss) private var dismiss
    let source: Person

    @State private var destinationID: UUID?
    @State private var preview: PersonMergePreview?
    @State private var understands = false
    @State private var errorMessage: String?

    private var destinations: [Person] {
        store.people
            .filter { $0.id != source.id && $0.deletedAt == nil && $0.mergedIntoPersonID == nil }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Merging is never automatic. Choose the destination record, inspect exactly what changes, then confirm.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                    LabeledContent("Source record", value: source.displayName)
                    Picker("Keep as destination", selection: $destinationID) {
                        Text("Choose a person").tag(nil as UUID?)
                        ForEach(destinations) { person in
                            Text(destinationLabel(person)).tag(person.id as UUID?)
                        }
                    }
                }

                if let preview {
                    Section("Preview") {
                        comparison("Preferred name", from: preview.source.displayName, to: preview.resultingPerson.displayName)
                        comparison("Aliases", from: preview.source.aliases.joined(separator: ", "), to: preview.resultingPerson.aliases.joined(separator: ", "))
                        comparison("Contexts", from: preview.source.contexts.joined(separator: ", "), to: preview.resultingPerson.contexts.joined(separator: ", "))
                        comparison("Contacts", from: "\(preview.source.contacts.count)", to: "\(preview.resultingPerson.contacts.count)")
                        LabeledContent(
                            "Surviving archive state",
                            value: preview.resultingPerson.isArchived
                                ? String(localized: "Archived — hidden from default People")
                                : String(localized: "Active")
                        )
                        LabeledContent("Interactions reassigned", value: "\(preview.interactionsToMove)")
                        structuredImpact(for: preview)
                    }
                    if !preview.warnings.isEmpty {
                        Section("Review carefully") {
                            ForEach(preview.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    Section("Recovery") {
                        Text("The source record remains as a recoverable merge tombstone for 30 days. Undo restores both records and every moved interaction exactly as they were.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                        Toggle("I reviewed the destination and understand the merge", isOn: $understands)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Merge People")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge", role: .destructive) { commit() }
                        .disabled(preview == nil || !understands)
                }
            }
            .onChange(of: destinationID) { _, newValue in
                understands = false
                guard let newValue else { preview = nil; return }
                do {
                    preview = try store.mergePreview(sourceID: source.id, destinationID: newValue)
                    errorMessage = nil
                } catch {
                    preview = nil
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Merge unavailable", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .keepsakeSheetSize(minWidth: 560, minHeight: 560)
    }

    @ViewBuilder
    private func comparison(_ label: LocalizedStringKey, from: String, to: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.secondaryText)
            if !from.isEmpty { Text("Source: \(from)").foregroundStyle(AppTheme.secondaryText) }
            Text("Result: \(to.isEmpty ? String(localized: "Not set") : to)")
        }
    }

    private func commit() {
        guard let destinationID else { return }
        do {
            _ = try store.mergePeople(sourceID: source.id, into: destinationID)
            canonical.reload()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func destinationLabel(_ person: Person) -> String {
        var details: [String] = []
        if person.isArchived { details.append(String(localized: "Archived")) }
        if let alias = person.aliases.first { details.append(alias) }
        if let context = canonical.contexts(for: person.id).first?.names.fallback
            ?? person.contexts.first {
            details.append(context)
        }
        return details.isEmpty
            ? person.displayName
            : "\(person.displayName) — \(details.joined(separator: " · "))"
    }

    private func structuredImpact(for preview: PersonMergePreview) -> some View {
        let sourceID = preview.source.id
        let destinationID = preview.destination.id
        let IDs: Set<UUID> = [sourceID, destinationID]
        let membershipCount = canonical.memberships.filter { IDs.contains($0.personID) }.count
        let factCount = canonical.assertions.filter { IDs.contains($0.subjectID) }.count
        let portraitCount = canonical.portraitMedia.filter { IDs.contains($0.personID) }.count
        let reminderCount = canonical.reminders.filter {
            if case .person(let id) = $0.subject { return IDs.contains(id) }
            return false
        }.count
        return VStack(alignment: .leading, spacing: 4) {
            Text("Structured records retained on the surviving identity")
                .font(.caption.weight(.semibold))
            Text("\(membershipCount) memberships · \(factCount) facts · \(portraitCount) photos · \(reminderCount) reminders")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }
}

struct MergeRecoveryView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var canonical: CanonicalVaultStore
    @State private var undoing: PersonMergeEvent?
    @State private var errorMessage: String?

    private var events: [PersonMergeEvent] {
        canonical.personMergeEvents
            .filter { $0.undoneAt == nil }
            .sorted { $0.mergedAt > $1.mergedAt }
    }

    var body: some View {
        Group {
            if events.isEmpty {
                EmptyNotebookView(
                    icon: "arrow.triangle.merge",
                    title: "No recoverable merges",
                    message: "Confirmed person merges appear here during their recovery period."
                )
            } else {
                List(events) { event in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(event.sourcePersonBeforeMerge.displayName) → \(event.destinationPersonBeforeMerge.displayName)")
                                    .font(.headline)
                                Text("Merged \(event.mergedAt, format: .relative(presentation: .named)) · \(event.movedInteractionIDs.count) interactions")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            Spacer()
                            if event.canUndo {
                                Button("Undo…") { undoing = event }
                            } else {
                                Text("Recovery expired").font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Merge Recovery")
        .confirmationDialog(
            "Restore both people?",
            isPresented: Binding(get: { undoing != nil }, set: { if !$0 { undoing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Undo Merge") {
                guard let event = undoing else { return }
                do {
                    try store.undoMerge(event)
                    canonical.reload()
                } catch {
                    errorMessage = error.localizedDescription
                }
                undoing = nil
            }
            Button("Cancel", role: .cancel) { undoing = nil }
        } message: {
            Text("Both records and their interaction links will be restored to the exact pre-merge snapshots. Later conflicting edits are never overwritten.")
        }
        .alert("Merge could not be undone", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}
