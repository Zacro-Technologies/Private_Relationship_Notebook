# Keepsake whole-app product, UX, accessibility, and defect audit

Audit date: 2026-08-30  
App: Keepsake — Private Relationship Notebook  
Platforms exercised: macOS and iOS Simulator  
Overall verdict: Not release-ready

Build provenance: macOS 27.0 (26A5421a), Xcode 26.6 (17F113), isolated audit bundle com.zacrotech.RelationshipNotebook.UXAudit 0.1.0 (4). The report applies to the current workspace snapshot. The app tree is largely untracked/modified relative to Git HEAD 7324cb822fdc, so that commit is not an immutable identifier for the tested sources.

## Executive summary

Keepsake has a thoughtful privacy-first foundation, unusually careful provenance language, strong local-first positioning, and a broad canonical data model. The current product, however, exposes several serious mismatches between what the interface promises and what it actually does.

The release blocker is App Lock: a user can enable it before the app proves that device authentication is usable, potentially stranding the user until device authentication works again. Other high-risk findings include unclear retention controls around “Metadata only,” structured records that are described as recoverable but have no recovery UI, non-transactional received-profile imports, reminder states that look enabled even when no notification can fire, and deleted-person profiles that keep stale controls—some still effective.

The largest product-coherence problem is that several subsystems are parallel rather than connected:

- Free-text person contexts and canonical Contexts/Cohorts are separate.
- Interaction follow-ups and commitment text do not become Reminders or Commitments.
- Additional interaction participants affect some recency data but do not receive a complete timeline.
- Saved import reviews increase a “pending” count but cannot be resumed.
- Saved profile-card versions are counted but cannot be reopened after leaving the studio.
- Custom-field capability switches are exposed even where no product surface consumes them.

The iPhone experience is usable at normal text sizes, but it fails important accessibility and compact-layout cases. At the largest Dynamic Type size, onboarding page 3 has no scroll path and places both navigation actions below the screen. In landscape on an iPhone SE, the floating tab bar crosses the middle of the person-detail content. Several controls also expose generic or incomplete accessibility semantics.

Recommendation: block release on the critical and P0 remediation items below, especially authentication, accessibility, deletion/recovery, notification truthfulness, import atomicity, and privacy-policy enforcement. Resolve the workflow disconnects before expanding the feature set.

## Evidence labels

- UI—Mac: reproduced through the running macOS app using Computer Use.
- UI—iPhone: reproduced through the running iPhone SE simulator using Computer Use.
- UI + code: reproduced in the interface and traced to the implementation.
- Code-confirmed: implementation defect or limit found while explaining a UI behavior; the large-data or failure condition was not forced through the UI.
- Qualification gap: requires signing, a physical device, an account, an installed destination app, or a destructive external action.

## Test method and data

The app was built and run as an isolated audit bundle so the user's normal notebook was not used. Testing used:

- A fresh empty macOS notebook.
- A populated macOS notebook with the three example people plus Alex Rivera and an imported Jordan record.
- Duplicate tags, duplicate legacy contexts, two preferred contacts, a group interaction, a follow-up, commitment text, a canonical Context/Cohort/Role/Membership, two custom fields with the same name, two import reviews, an explicit reminder, and a saved profile-card version.
- A fresh iPhone SE (3rd generation) simulator on iOS 26.5 with example data.
- Default and accessibility-extra-extra-extra-large Dynamic Type.
- Portrait and landscape.
- Full Keyboard Access for keyboard-only traversal.
- English and Japanese app-language paths.

No external message, call, email, social handoff, profile share, or destructive real-user deletion was completed. Destructive tests were confined to the isolated notebook and used recoverable records where possible.

“Whole-app” here means every navigation-reachable entry point was inventoried. A “Yes” means the named state/action was observed on the listed platform, not that every field type, recurrence, permission, failure, or state combination was exercised. Deep CRUD testing was primarily on macOS; several iPhone entries were route/layout checks only. Code-only findings are not counted as Computer Use reproductions. Unreachable legacy PeopleView, FlattenedContextsView, and ImportReviewView implementations were excluded from UI coverage because they have no current navigation call site.

## Coverage matrix

| Surface | Empty | Populated | Create/edit | Failure/edge | Accessibility/layout | Result |
|---|---:|---:|---:|---:|---:|---|
| Launch and onboarding | Yes | N/A | Yes | AI setup cancel/allow, lock | Max text, narrow Mac sheet | Issues found |
| Today and suggestions | Yes | Yes | Snooze/dismiss/draw | Exhausted pool, no eligible person | iPhone SE, keyboard | Issues found |
| People discovery | Yes | Yes | Filters, saved-view UI, add | No results, duplicate values | iPhone list and tab overlap | Issues found |
| Person detail/editor | Yes | Yes | Primary person fields, private note, contacts | Delete, restore, credential check | iPhone portrait/landscape | Issues found |
| Contact draft | No contact | Yes | Draft/copy inspected | Preferred/contact ordering | Accessibility inspected | Issues found |
| Interactions | Yes | Yes | Group interaction, follow-up | Blank metadata, secondary participant | Slider semantics, iPhone form | Issues found |
| Activity | Yes | Yes | Filters and add | Inert saved row | iPhone empty state | Issues found |
| Contexts/Cohorts/Roles | Yes | Yes | Created Context, scheme, cohort, role, and membership; deleted membership | Structured deletion | Mobile route, keyboard | Issues found |
| Memberships/education/facts | Yes | Yes | Membership and fact add; education viewed | Credential value bypass | Semantics inspected | Issues found |
| Reminders/commitments | Yes | Yes | Create/delete | Past/unscheduled risks | Mobile route | Issues found |
| Custom fields | Yes | Yes | Two identical definitions | Policy/default mismatch | Mobile route | Issues found |
| Guided import | Yes | Yes | Paste, review, defer, commit | Instruction-like source, evidence | Add Hub entry visible on iPhone | Issues found |
| Archive import/export | N/A | Yes | Formats/scopes/password UI | Preview limitations | Mac and mobile routes | Issues found |
| Profile sharing | Yes | Yes | Preview/save/continue | Saved-version reopen | Add Hub entry visible on iPhone | Issues found |
| Recently Deleted | Yes | Yes | Person restore | Structured records absent | Mac and mobile routes | Issues found |
| Person merge / Merge Recovery | Empty route | No committed merge | Merge preview only | Commit/Undo not exercised; raw deleted-source routing code-reviewed | Mac route | Partial / issues found |
| Deletion Conflict Recovery | Yes | No generated conflict draft | Empty state and privacy/export copy inspected | Populated export/remove flow not exercised | Mac route; mobile entry visible | Partial |
| Received-profile import | Entry/code path only | Not exercised end-to-end | Review/import implementation inspected | No exchanged file, conflict, injected write failure, or rollback test | Mac/iPhone entry | Code-confirmed / qualification gap |
| App lifecycle routing | Launch/lock exercised | N/A | Onboarding/lock transitions | Privacy curtain, notification deep links, stale/deleted-person notification not deliberately exercised | N/A | Qualification gap |
| Settings/privacy | Yes | Yes | Core settings controls and nested entry points traversed | Delete-vault and lock | Full iPhone scroll, Japanese | Issues found |
| Photos | Empty state | Not qualified | Picker entry inspected | Permission/device matrix | Semantics inspected | Qualification gap |
| CloudKit/APNs/Shortcut | UI only | Not qualified | Setup/status UI | Signing/account/device required | N/A | Qualification gap |

## Release-blocking and high-severity findings

### KSP-001 — Critical — App Lock can be enabled before authentication succeeds

Evidence: UI—Mac + code.

Reproduction:

1. Open Settings & Privacy.
2. Enable “Require device authentication.”
3. The app locks immediately without first confirming that Local Authentication can be evaluated.
4. If the policy is unavailable or repeatedly fails, the lock preference is already committed and there is no way inside the locked app to turn it back off.

Actual: the preference is committed and the app enters the locked state before capability is proven. In the audited environment the unlock attempt did not resolve through the UI and the isolated process/preference had to be reset. The implementation can surface an authentication error, but App Lock remains enabled.

Expected: preflight canEvaluatePolicy, authenticate once, and commit App Lock only after success. A failed or unavailable policy must leave App Lock off.

Impact: the user can be stranded until device authentication is restored. This is especially dangerous on Macs without an enrolled usable policy or after authentication configuration changes.

Recommendation: make setup transactional in Settings and onboarding, show the exact unavailable reason, authenticate successfully before enabling, and provide system-recovery guidance without creating an unauthenticated bypass.

Code: CaptureAndSettingsViews.swift 1315–1319; RootAndOnboarding.swift around 262 and 361–365; SecurityViews.swift 10–47.

### KSP-002 — High — Maximum Dynamic Type makes onboarding impossible to complete

Evidence: UI—iPhone + code.

Reproduction:

1. Set text size to accessibility-extra-extra-extra-large.
2. Launch a fresh install on iPhone SE.
3. Continue to “Connect Keepsake AI.”

Actual: titles and body copy are truncated on the first pages. On the AI/setup page, the lower controls and both Back and Continue are below the visible screen. There is no scroll container, so a sighted touch user cannot proceed.

Expected: the complete page scrolls, text wraps without truncation, and navigation actions remain reachable.

Impact: onboarding is a hard accessibility blocker.

Recommendation: use a ScrollView with safe-area-aware persistent actions or allow the actions to scroll into view; verify every page at all accessibility sizes and in landscape.

Code: RootAndOnboarding.swift 208–321.

### KSP-003 — High — “Recently Deleted” promises recovery for structured records but only restores people

Evidence: UI—Mac + code.

Reproduction:

1. Create a canonical Context, cohort scheme, cohort, role, and membership.
2. On the person profile, choose “Move membership to Recently Deleted.”
3. Accept the confirmation that says records remain recoverable.
4. Open Recently Deleted.

Actual: the membership disappears, while Recently Deleted still says it is empty. The screen only lists deleted people. The same problem affects memberships, assignments, education records, facts, reminders, and other canonical tombstones.

Expected: every record described as recoverable appears in a typed recovery surface, with restore and permanent-delete behavior.

Impact: users are told that data is recoverable but cannot recover it through the product.

Recommendation: either implement a typed recycle bin for every soft-deleted entity or change deletion semantics/copy before release.

Code: StructuredRelationshipViews.swift around 614; CanonicalVaultStore.swift around 255; CaptureAndSettingsViews.swift around 2680.

### KSP-004 — Medium — “Metadata only” does not clearly disclose reflection/draft retention

Evidence: Code-confirmed from the visible interaction form and save path.

Reproduction:

1. Log an interaction.
2. Choose Transcript retention → Metadata only.
3. Enter a Private reflection and save.

Actual: the mode clears recap, commitment, transcript, and final-content fields, but the reflection editor remains available and its value can persist. Generated draft material is controlled separately. The specification may intend those as independent categories, but the visible “Metadata only” label/copy does not explain the exception.

Anticipated hesitation, post-action difficulty, and felt-worthwhile values are also retained because normalization clears the recap/transcript fields but not those reflection metrics.

Expected: reflection and generated-draft retention should have independent, explicit controls, or the mode copy must precisely disclose that they remain stored.

Impact: a reasonable user can believe less private content is retained than is actually stored.

Recommendation: clarify the product decision, expose independent controls where necessary, centralize retention enforcement, and test every retained field against the visible disclosure.

Code: CaptureAndSettingsViews.swift 120–191 and 800–813; Domain.swift 329–370.

### KSP-005 — High — Received-profile import is not transactional

Evidence: Code-confirmed from the user-facing import flow.

Actual: importing a received profile creates the Person before all assertions and links are validated/written. A later failure can leave a partial person behind even though the overall import reports failure.

Expected: stage and validate the entire received profile, then commit the person and all accepted fields atomically.

Impact: a reported failure can leave undisclosed partial state and require confusing duplicate cleanup.

Recommendation: wrap the complete operation in one store transaction or use a staged reviewed-import object with rollback.

Code: ProfileSnapshotStudioView.swift around 687; CanonicalVaultStore.swift 231–252; RecordRepository.swift 69–100 and 103–148.

### KSP-006 — High — A deleted person's open profile retains stale actions

Evidence: UI—Mac.

Reproduction:

1. Open Jordan's profile.
2. Move Jordan to Recently Deleted.
3. Stay on the existing detail view.

Actual: the full deleted profile remains visible with Contact, Log interaction, Add Fact, and Edit controls. Contact can still open externally, and canonical fact writes lack a clear active-person guard. Interaction save does reject deleted participants, but only after the user enters the flow and attempts the write.

Expected: immediately dismiss the route or replace it with a tombstone screen containing only Restore and Back.

Impact: some actions remain effective while others fail only after user effort, so the visible state is stale and untrustworthy.

Recommendation: resolve person state on every action, invalidate open routes after deletion, and block writes for deleted/merged identities.

Code: TodayAndPeopleViews.swift around 1397; NotebookStore.swift 331–342 and 386–394.

### KSP-007 — High — Interaction follow-ups and commitments never become actionable planning records

Evidence: UI—Mac + code.

Reproduction:

1. Log an interaction with “Commitment or next step.”
2. Enable “Schedule a follow-up” and choose a date.
3. Save, then open Today and Reminders & Commitments.

Actual: both values are visible only as text on the Activity row. No Reminder or canonical Commitment is created, and neither item appears on Today.

Expected: the interaction should create or link editable Reminder/Commitment records, with clear due/completed/snoozed state.

Impact: the UI solicits planning data that cannot drive the promised follow-through workflow.

Recommendation: make planning records first-class, bidirectionally linked to the interaction, and expose them on Today.

Code: CaptureAndSettingsViews.swift 140–148, 183, 939; PlanningAndCustomFieldsViews.swift 3–116.

### KSP-008 — High — Group interactions produce incomplete and contradictory participant histories

Evidence: UI—Mac + code.

Reproduction:

1. Log an interaction with Alex as primary and Maya as an additional participant.
2. Open Alex, Maya, and Activity.

Actual: Alex receives the timeline item. Maya's last-contact value changes, but Maya's Timeline says “No moments logged yet.” Activity names only Alex. The first deletion-confirmation count is also primary-only. Activity's person/context filters do include additionalParticipantIDs, so the defect is attribution/presentation rather than every filter.

Expected: every participant should have an attributable timeline entry and Activity should display all participants, while preserving a primary organizer if needed.

Impact: the notebook tells two different stories about the same relationship event.

Recommendation: query participant membership rather than only personID; show group chips/names in Activity and deletion previews.

Code: CaptureAndSettingsViews.swift around 81 and 905; TodayAndPeopleViews.swift around 1497 and 1567.

### KSP-009 — High — Saved interactions cannot be opened, corrected, or deleted

Evidence: UI—Mac + code.

Reproduction: click a populated Activity row.

Actual: the row is inert. There is no detail view, edit/correct action, evidence downgrade, participant correction, follow-up update, or soft delete.

Expected: saved interactions should have a detail surface and an auditable correction workflow.

Impact: an accidental “sent,” wrong date, wrong person, private transcript, or blank log becomes effectively permanent in the UI and can distort cadence.

Recommendation: add interaction detail, correction history, safe retention changes, and soft deletion.

Code: CaptureAndSettingsViews.swift around 892.

### KSP-010 — Medium — Each broad People result set is capped at its first 500 rows

Evidence: Code-confirmed.

Actual: the People UI requests one 500-row page. It shows totalCount in the section header but provides no next-page/infinite-scroll path and no “showing 500 of N” warning.

Expected: stable pagination through the complete matching set.

Impact: records after row 500 are unavailable within that broad result. A user may reach one by narrowing the query, but cannot browse or audit the full set, conflicting with the documented 50,000-person target.

Recommendation: cursor pagination, visible total/range, stable selection, and large-vault UI tests.

Code: PeopleDiscoveryView.swift 719–735.

### KSP-011 — High — Legacy person contexts and canonical Contexts/Cohorts are disconnected

Evidence: UI—Mac + code.

Reproduction:

1. Add a person with free-text “Book Club” in Context.
2. Open the Contexts sidebar: it remains empty.
3. Create a canonical Book Club context and membership.
4. Compare Today pools and Activity filters.

Actual: person editing writes comma-separated strings, while Contexts/Cohorts/Memberships use a separate graph. Today and Activity still rely largely on the legacy strings.

Expected: one canonical context system with inline create/match/membership.

Impact: duplicate concepts, incorrect member counts, filters that disagree, and cohorts/roles that do not reliably drive suggestions.

Recommendation: migrate legacy strings to explicitly matched/unmatched canonical references and use the canonical graph everywhere.

Code: TodayAndPeopleViews.swift 1045 and 1715; StructuredRelationshipViews.swift 3; CaptureAndSettingsViews.swift around 858.

### KSP-012 — High — Past one-time reminders look enabled but can never fire

Evidence: UI shape + code-confirmed scheduling behavior.

Reproduction:

1. Create a one-time reminder with a past due date.
2. Save it.

Actual: the editor accepts the date and the list displays a filled bell/enabled reminder. The scheduler explicitly skips non-recurring fire dates that are not in the future.

Expected: reject the date, mark the item overdue with recovery actions, or immediately disable it with an explanation.

Impact: false confidence that an important reminder is active.

Recommendation: validate at edit time and surface delivery/scheduling state on every row.

Code: PlanningAndCustomFieldsViews.swift 123–160; NotificationScheduler.swift 541–542.

### KSP-013 — High — Notification scheduling silently truncates after 60 requests

Evidence: Code-confirmed.

Actual: the scheduler stops adding owned requests at 60, AppSessionController suppresses reconcile errors with try?, and the reminder list still displays every enabled record with the same filled bell.

Expected: no reminder should claim enabled delivery without a scheduled request; capacity should be allocated predictably and visibly.

Impact: requests outside the prioritized 60-request budget silently do not notify. Explicit reminders are prioritized before proactive nudges and then by fire date, but the UI exposes none of that allocation.

Recommendation: expose scheduled/queued/unscheduled/error state, prioritize near-term fires, reconcile deterministically, and show capacity guidance.

Code: NotificationScheduler.swift 447–450 and 524–571; AppSessionController.swift 1126–1167; PlanningAndCustomFieldsViews.swift 20–44.

### KSP-014 — High — “Save review for later” creates an invisible, non-resumable import

Evidence: UI—Mac + code.

Reproduction:

1. Paste a source with multiple candidates.
2. Edit decisions and attach one candidate to an existing person.
3. Choose “Save review for later.”
4. Leave and return to Imports & Review.

Actual: the completion view says the review was saved, but Imports has no pending-review inbox or Resume action. Candidate decisions persist in sanitized form, but targetPersonID is lost. The conversation transcript-retention picker is only global AppStorage: it is not persisted per review and no later Interaction attachment consumes it.

Expected: a durable pending-review list that restores candidate decisions, selected facts, evidence, retention choice, and target-person links.

Impact: work appears saved but cannot be resumed; a carefully chosen match must be recreated.

Recommendation: add a Pending Reviews screen and persist the complete review state.

Code: GuidedImportReviewView.swift 11–12, 234–250, 354–410, and 491–528.

### KSP-015 — Medium — Completed imports continue to inflate “Pending import reviews”

Evidence: UI—Mac.

Reproduction:

1. Save one review for later.
2. Complete and commit a second review.
3. Open Settings.

Actual: Settings reports two pending reviews even though one is committed. There is no way to inspect either counted item.

Expected: only genuinely resumable, uncommitted reviews count as pending.

Impact: phantom backlog and an untrustworthy status dashboard.

Recommendation: give review records explicit lifecycle states and derive the count from resumable states only.

Code: CaptureAndSettingsViews.swift around 1257.

### KSP-016 — Medium — Saved profile-card versions cannot be reopened after leaving the studio

Evidence: UI—Mac.

Reproduction:

1. Create and preview a profile card.
2. Save version 1 locally.
3. While the temporary state is still present, “Open saved copy” works.
4. Navigate away and reopen Profile Sharing.

Actual: the series shows only “Continue this series.” The exact saved version cannot be opened, inspected, shared again, or exported. Continuing starts a new draft/version.

Expected: a saved-version browser with exact payload preview, reopen, share/export, compare, and revoke/archive actions.

Impact: the app counts snapshots that the owner cannot later inspect, undermining the purpose of immutable publication versions.

Recommendation: persist and expose a saved-version detail route independent of temporary editor state.

### KSP-017 — Medium — Preferred contact is ignored and multiple contacts can all be “Preferred”

Evidence: UI—Mac + code.

Reproduction:

1. Add two contacts to a person.
2. Mark both Preferred.
3. Put the intended contact second.
4. Open Contact.

Actual: both rows remain Preferred, but the handoff always uses contacts.first. There is no channel chooser.

Expected: at most one preferred method per channel/person, with an explicit handoff selector and remembered choice.

Impact: the app can open or copy the wrong address/handle/phone number.

Recommendation: enforce preference invariants and select by preference plus requested channel, not array order.

Code: TodayAndPeopleViews.swift around 1721; CaptureAndSettingsViews.swift around 309, 763, and 785.

### KSP-018 — High — Future interaction dates corrupt recency and suggestions

Evidence: UI editor + code-confirmed.

Actual: the interaction editor permits future dates. Saving updates lastInteractionAt, which affects People sorting, cadence, due calculations, and nudge eligibility. Approximate dates also store a full hidden instant and use it for these calculations.

Expected: reject accidental future interactions or explicitly model scheduled events separately. Approximate dates should use documented interval semantics.

Impact: a typo can suppress contact suggestions for months or years.

Recommendation: date validation, explicit scheduled-event type, and uncertainty-aware recency logic.

Code: CaptureAndSettingsViews.swift 105 and 171–218; NotebookStore.swift around 326 and 342–361.

### KSP-019 — High — Credential protection checks fact names, not sensitive values

Evidence: UI—Mac + code.

Reproduction:

1. Add a fact named “Wi-Fi details.”
2. Enter “password: hunter2” as the value.

Actual: Save remains enabled with no warning. Private-note scanning blocks similar content, but manual fact values and Safe to mention can bypass the guard.

Expected: block credential-oriented fields and block secret values from mentionable/AI-eligible use. For ambiguous private-only values, show a strong warning and redirect the user to an appropriate secure store.

Impact: credentials can be stored in broadly searchable, exportable, mentionable, or AI-eligible data.

Recommendation: value-based detection at the model boundary, strict mention/AI policy for secrets, and an explicit private-only warning path where the specification permits one.

Code: StructuredRelationshipViews.swift 2002–2009.

### KSP-020 — High — Custom-field privacy and capability defaults are not enforced when creating facts

Evidence: UI + code.

Actual: the fact editor does not load the selected custom-field definition's sensitivity or allowed-use defaults. Newly created facts can therefore have broader search/reminder/profile-sharing policies than the field definition implies.

Expected: the definition is the authoritative default and restrictive policy changes cascade or require explicit review.

Impact: privacy configuration appears to protect a field but does not reliably protect its values.

Recommendation: bind fact creation to the selected definition and validate policy compatibility in the store.

Code: StructuredRelationshipViews.swift 1986–1995 and 2274–2306.

### KSP-021 — Medium — A saved view leaves editable manual filters/sort that are ignored

Evidence: Code-confirmed from the visible saved-view/filter workflow.

Actual: the picker and “Saved: …” chip identify the active saved view, but most populated manual filters and the sort remain editable while being ignored. searchText and includeArchived still apply, creating a mixed query model.

Expected: selecting a saved view should visibly replace/reset ignored controls or show its criteria as the active read-only state, while clearly labeling any allowed overlays.

Impact: users cannot tell why a person is included or excluded.

Recommendation: one visible query state, with an explicit “Edit as custom filters” action.

Code: PeopleDiscoveryView.swift around 157 and 569.

### KSP-022 — High — Saved-view export does not match the visible saved-view result

Evidence: Code-confirmed.

Actual: saved-view export evaluates with includeArchived hardcoded to true even when the People view excluded archived records.

Expected: export exactly the reviewed visible scope, or show and confirm any expansion.

Impact: private archived people can be included unexpectedly in an export.

Recommendation: serialize the exact evaluated query/scope and preview the record count before export.

Manual Selected People export has a related risk: it offers every non-deleted person, including archived people, and the selector distinguishes entries only by display name.

Code: CaptureAndSettingsViews.swift around 1417–1420, 1617, and 2020–2036; PeopleDiscoveryView.swift around 569.

### KSP-023 — Low — “Delete Entire Vault” could state its reset boundary more explicitly

Evidence: UI wording + code-confirmed.

Actual: the dialog promises deletion of every “setting-backed record in this vault,” not a factory reset, so preserving language, App Lock, and other application preferences is reasonable. The remaining ambiguity is which transient vault-linked IDs/history/caches count as vault state.

Expected: document and test the vault-scoped reset boundary, clear transient state that refers to deleted record IDs, and explicitly say that application preferences remain. A separate “Reset Keepsake” action can perform a true factory reset.

Impact: primarily copy/support ambiguity unless a stale vault-linked identifier is shown to survive.

Recommendation: define and test separate “Delete this vault” and optional “Reset Keepsake” contracts.

### KSP-024 — High — Import provenance is not exact for PDFs and images

Evidence: UI for pasted-text provenance + code-confirmed PDF/image behavior. Real PDF/image ingestion was not executed in this pass.

Actual: evidence preview can show exact line/UTF-16 offsets for pasted text, but selected PDF/image originals are not retained. OCR evidence is only extracted text, without an original page/region artifact. Mixed-content PDFs skip OCR when embedded text reaches a small threshold, and multi-frame images process only the first frame.

Expected: optional original retention, page/frame and region coordinates, visible OCR uncertainty, and hybrid OCR for incomplete embedded text.

Impact: users cannot verify a fact against the actual source and can silently miss content.

Recommendation: preserve a sanitized local source artifact when requested and store page/frame/region evidence.

Code: DocumentTextExtractor.swift 69–77 and 101–117; GuidedImportReviewView.swift 647–664.

### KSP-025 — Medium — “Surprise Me” exhausts small notebooks and then gives the wrong explanation

Evidence: UI—Mac and UI—iPhone + code.

Reproduction: with three example people, use Surprise Me three times.

Actual: every manual draw enters the same hard cooldown. The pool is quickly exhausted, after which Today says “Your boundaries and snoozes are being respected,” even when cooldown is the only reason.

Expected: manual surprise should allow a separate randomized mode or soft repeat policy, and the empty state should name the real exclusion reason.

Impact: the headline feature appears broken after a few taps and falsely implies user-created boundaries.

Recommendation: separate manual-random history from proactive cadence, expose exclusion counts, and add “allow repeats.”

Code: TodayAndPeopleViews.swift around 260 and 918; NudgeEngine.swift around 213.

### KSP-026 — Medium — Name-only onboarding produces no actionable first suggestion

Evidence: UI + code.

Actual: onboarding offers an optional name but no contact route or context. The nudge engine excludes a person who has neither, and Today then uses the generic boundaries/snoozes explanation.

Expected: onboarding should either collect one route/context or explain the next required step and link directly to it.

Impact: the first-run promise ends in an empty Today screen.

Recommendation: add optional context/channel/import/self setup and a first suggestion preview.

Code: RootAndOnboarding.swift around 269 and 361; NudgeEngine.swift around 221.

### KSP-027 — Medium — Example people are indistinguishable from real data

Evidence: UI—Mac and UI—iPhone + code.

Actual: “Explore with three example people” creates Aiko, Maya, and Kenji as normal records with realistic notes, handles, cadence, and phone data. They can sync, export, appear in suggestions, and be edited individually. There is no sample badge or “Remove all examples.”

Expected: an isolated demo mode or clearly marked samples with one-tap cleanup before sync/export.

Impact: sample content can be mistaken for real private data and contaminate exports/statistics.

Recommendation: add a sample badge, export preview, and one-tap bulk removal. Do not silently change normal portability scope.

Code: NotebookStore.swift around 1358–1405.

## Additional defects and product-coherence problems

Some entries below are labeled “P0 specification gap.” That label reflects required v1 feature completeness in the product specification, not proof of a higher-severity runtime defect.

### KSP-028 — Reminder and Commitment rows are not manageable

Evidence: UI—Mac + code.

An explicit reminder can be created and deleted, but it cannot be opened, edited, disabled, completed, snoozed, dismissed, rescheduled, or reopened. Commitment rows are effectively read-only. The core ReminderEvent and CommitmentEvent types are not wired into the app workflow.

Recommendation: add detail/edit and a complete state machine: active, completed, snoozed, dismissed, disabled, overdue, and delivery error.

### KSP-029 — Today ignores the user's actual outstanding work

Evidence: UI—Mac.

Today shows one relationship suggestion and database counters, but not explicit reminders, overdue interaction follow-ups, commitment text, pending import reviews, or contact outcomes that still need confirmation. In the populated audit notebook, Today displayed five people and two moments but none of those pending actions.

Recommendation: add a small, prioritized “Needs attention” section and replace vanity-like counters with actionable status.

### KSP-030 — Empty Activity and Reminder creation are dead ends

Evidence: UI—Mac.

From an empty vault, “Log Interaction” and “New Reminder” open editors whose Person picker has no choices and whose Save action is disabled. Neither editor offers Add Person or explains the prerequisite.

Recommendation: inline “Add a person first,” then return to the original draft after creation.

### KSP-031 — Same-name and duplicate pickers are ambiguous

Evidence: UI + code.

Person pickers generally display only a name. With two people named Alex Rivera, import attachment, merge, interaction, reminder, and context membership choices are indistinguishable.

Recommendation: include portrait/initials, aliases, primary context, contact hint, and stable disambiguation text in every picker.

### KSP-032 — Changing the primary interaction person can leave that person in Additional participants

Evidence: Code-confirmed from the interaction editor.

The editor prevents adding the current primary to the additional list at selection time, but switching the primary does not reliably remove an already-selected duplicate.

Recommendation: normalize participant IDs whenever the primary changes and enforce uniqueness in the model.

### KSP-033 — Contact outcome choices allow impossible evidence/channel combinations

Evidence: Code-confirmed from the visible post-handoff outcome design.

The specification intentionally permits “I called” or “We met elsewhere” after a handoff. The defect is in the resulting evidence: a call/meeting can retain the original email/social channel and userConfirmedSent state, while “destination opened; outcome unknown” is recorded as a message regardless of the destination.

Recommendation: keep the cross-channel outcomes, but record the correct interaction kind, an explicit or blank alternate channel, and an evidence state appropriate to what the user confirmed.

### KSP-034 — Tags, legacy contexts, and Preferred contacts accept duplicates

Evidence: UI—Mac.

Alex was saved with “Book Club, Book Club,” “Neighbor, Neighbor,” and two Preferred contacts. All duplicates rendered. There is no normalization, de-duplication prompt, or invariant enforcement.

Recommendation: canonicalize comma-separated entries, show chips before save, and enforce contact preference rules.

### KSP-035 — New-person editor changes title before the record exists

Evidence: UI—Mac.

Typing the first character into “New Person” immediately changes the title to “Edit Person,” although the record has not been saved. After saving a new person from another profile, the app returned to the previous profile with little confirmation.

Recommendation: derive create/edit state from persisted identity, show a clear save confirmation, and offer “Open profile” versus “Done.” Returning to the prior quick-flow screen can remain valid.

### KSP-036 — Custom fields are add-only and exact duplicates are accepted

Evidence: UI—Mac + code.

Two identical “Anniversary” definitions were created with no warning and appear as indistinguishable rows. Duplicate labels generate the same predicateID. People filters then reuse the same SwiftUI identity; projection keeps the first definition while FilterSchema can overwrite duplicate keys. Different types/capabilities under one label can therefore produce inconsistent projection and validation. Existing definitions also cannot be edited, archived, deleted, reordered, or given options/validation/cardinality.

Recommendation: require a unique stable key independent of label, block/migrate collisions, and add definition lifecycle/versioning.

Code: PlanningAndCustomFieldsViews.swift 339–359; PeopleDiscoveryView.swift 80–109; LocalSearchModels.swift 249–252; CanonicalPlanningAndFilters.swift 725–733.

### KSP-037 — Custom-field capability switches overpromise

Evidence: UI + code.

The create form exposes Search, Filters, Reminders, and Self-profile cards. “Reminders” and “Self-profile cards” have no meaningful consumers. Search and Filters appear independent, but filtering is gated by search/indexability. The field's policy defaults are also not applied by the fact editor.

Recommendation: hide unsupported capabilities, explain dependencies, and add end-to-end tests for every enabled switch.

### KSP-038 — Fact provenance cannot be fully reviewed

Evidence: UI + code.

Manual Fact exposes certainty but no confidence or review-status control. Fact rows show source/date/review state but omit confidence and certainty. Corrected/superseded versions and conflict resolution are not visible, despite copy saying editing creates history.

Recommendation: add an assertion detail/history view with confidence, certainty, review state, sources, validity range, superseded versions, and conflict resolution.

Code: StructuredRelationshipViews.swift around 884–924 and 1903–2112.

### KSP-039 — Merge resolution is canonical internally but raw context links can open the deleted source

Evidence: Code-confirmed; important correction to avoid overstating data loss.

The canonical store resolves merged IDs, so structured data is not physically lost. However, Context detail and some raw-reference UI can still use the original membership personID and navigate to the deleted source tombstone. Reminders and commitments are explicitly retargeted, while these views are not.

The destination picker also includes archived people without an archive badge. Because the surviving record starts from the destination, merging an active person into an archived destination can make the result disappear from default People. The preview does not disclose destination archive state or enumerate structured memberships, facts, and photos.

Recommendation: resolve every displayed/navigated identity through the canonical merge map, badge archived destinations, disclose the surviving archive state and structured-data implications, and label historical source identity only in an audit view.

Code: CanonicalVaultStore.swift 287–351; StructuredRelationshipViews.swift 189–191 and 372–399; PeopleManagementViews.swift 14–42; PersonMerge.swift 182–220.

### KSP-040 — P0 specification gap — Guided import lacks several promised end-to-end paths

Evidence: UI—Mac + code.

The implemented path supports paste/text/PDF/image review, candidate decisions, split/combine, and evidence preview. Missing pieces include a Share Extension, configured-Shortcut AI extraction, portrait proposal/confirmation, creation of an Interaction from a conversation source, original binary retention, and a resumable review inbox.

Recommendation: prioritize resumability and exact provenance first. AI extraction and portrait proposal should remain optional per import and explicitly reviewed, while still being implemented as required v1 capabilities.

### KSP-041 — High / P0 specification gap — Archive import “review” is counts-only and commits all accepted categories

Evidence: UI—Mac + code.

The preview shows counts and same-name warnings, but there is no per-record selection, field diff, match choice, conflict resolution, or scope control. “Commit Reviewed Import” automatically applies every category the importer classified as acceptable.

For an incomingIsNewer stable-ID Person, the planner accepts and commits the whole object. Names, notes, contacts, boundaries, and other person fields can therefore be replaced based on timestamp without a field-level diff or checkbox.

Recommendation: expandable create/update/conflict groups, checkboxes, exact field diff, explicit same-name decisions, and a downloadable import report.

Code: CaptureAndSettingsViews.swift 2340–2452; ArchiveImportPlanner.swift 420–445; NotebookStore.swift 420–422.

### KSP-042 — P0 specification gap — Profile sharing cannot include a portrait or QR exchange

Evidence: UI—Mac + code.

The editor supports name, pronunciation, languages, time zone, contact, affiliation, cohort, role, interests, and communication preference. It has no portrait row and no QR display/scan workflow. Core can represent portrait metadata but no image bytes are transferred through this editor.

Recommendation: add an explicitly selected sanitized portrait asset and compact QR/file exchange with exact preview.

### KSP-043 — P0 specification gap — The “Me” tab is Settings, not a self identity

Evidence: UI—iPhone + code.

Opening Me shows “Settings & Privacy.” There is no optional self-person, own memberships, or comparison basis for the core RelativeCohortCalculator. Users cannot ask “people two cohorts after me.”

Recommendation: add an optional private self identity, own dated memberships, and relative cohort filters/labels.

Code: CanonicalRelationships.swift around 562; PeopleDiscoveryView.swift around 815.

### KSP-044 — P0 specification gap — The name model cannot faithfully represent Japanese/English names

Evidence: UI + code.

Person stores one display name, one pronunciation string, and untyped aliases. It cannot separately preserve preferred/original script, kana, romanization, type, validity date, or locale-specific order.

Recommendation: typed name variants with script/language, explicit preferred form, kana and romanization, and display-order preferences.

Code: Domain.swift around 59; TodayAndPeopleViews.swift around 1690.

### KSP-045 — P0 specification gap — Canonical Contexts are buried on iPhone

Evidence: UI—iPhone.

The five tabs are Today, People, Add, Activity, and Me. Contexts is not within People; it is under Me → Settings & Privacy → Notebook Structure → Contexts & Cohorts. This is especially confusing because profiles visibly use context-like free text.

Recommendation: put People/Contexts in a segmented top-level area or add a prominent Contexts entry beside People search.

### KSP-046 — The floating iPhone tab bar obscures content

Evidence: UI—iPhone.

In portrait on iPhone SE, the tab bar covers the last list row or lower card content. In landscape person detail, the tab bar crosses the middle of the Current context card because the vertical safe area is extremely short.

Expected: scroll content should include sufficient bottom inset, and compact landscape should use a side rail, compact toolbar, or hidden-on-scroll tab treatment.

### KSP-047 — Localization is incomplete and does not update onboarding consistently

Evidence: UI—Mac.

Selecting Japanese during onboarding did not update that page. In Settings, section content changed to Japanese while the sidebar, window title, several values, and subtitles remained English.

Recommendation: use one observable locale source across navigation chrome, forms, alerts, accessibility labels, and current onboarding; add screenshot/localization tests for both languages.

### KSP-048 — Mac AI setup sheet clips critical text and controls

Evidence: UI—Mac.

At its presented size, the AI setup sheet clipped the left side of “Shortcut name,” truncated lower privacy copy, and cut content at the bottom. Orange explanatory text also had weak contrast against the background.

Recommendation: make the sheet resizable/scrollable, set a safe minimum size, and verify contrast in light/dark/high-contrast modes.

### KSP-049 — Search empty states do not distinguish empty vault from no matches

Evidence: UI—Mac.

Typing a query in an empty People vault still shows the generic “add your first person” state rather than “No results for …,” making it unclear whether search is active.

Recommendation: separate no-data, no-query-results, filtered-out, index-building, and search-error states.

### KSP-050 — Add Hub omits common capture jobs

Evidence: UI—iPhone + code.

The entire Add Hub contains four cards: Person, Interaction, Paste or document, and Profile sharing. It has no standalone Note, quick reminder/commitment, photo/screenshot-specific capture, profile-card scan/QR, or direct JSON/media archive import. Archive import is buried in Settings.

Recommendation: add Note and Reminder as lightweight first-class capture, route files by detected type, and keep advanced archive restore visibly separate.

### KSP-051 — P0 specification gap — Mac productivity support is minimal

Evidence: UI—Mac + code.

File → New Window opens another root window, but there are no dedicated person/import window scenes, global-search command, keyboard-first route navigator, or drag-and-drop import. Two profiles and an import review cannot be opened as independent documents.

The shared four-card Add Hub is also unreachable from normal Mac navigation; see KSP-065.

Recommendation: person/import windows, Command-K global search/navigation, drag/drop import, and documented keyboard shortcuts.

Code: RelationshipNotebookApp.swift 21–79.

### KSP-052 — Saved views have no lifecycle management

Evidence: UI—Mac + code.

A saved view can be created and selected, but there is no edit, rename, duplicate, reorder, archive, or delete surface.

Recommendation: add Saved View management and show the exact criteria, sort, nudge-pool eligibility, and last modified time.

### KSP-053 — Fatal notebook-open failure has no Retry action

Evidence: Code-confirmed.

The fatal session-loading state can explain failure but provides no retry/reopen/recover action.

Recommendation: Retry, open diagnostics, restore checkpoint, and safe local-only recovery where appropriate.

### KSP-054 — Important save/export/scheduling errors are swallowed

Evidence: Code-confirmed.

Several reminder, custom-field, saved-view, export, and notification reconcile paths use optional try or otherwise discard errors. The UI can remain unchanged with no explanation.

Recommendation: surface actionable errors, preserve the user's draft, and log a privacy-safe diagnostic identifier.

Code: CanonicalVaultStore.swift 358–364; PlanningAndCustomFieldsViews.swift 184–195 and 359–360; CaptureAndSettingsViews.swift 1396–1415.

### KSP-055 — People search index is rebuilt in memory and not persisted

Evidence: Code-confirmed.

The UI constructs LocalSearch with persistence nil and rebuilds from all people on projection changes. The persistence/checksum capability described by core/README is not used by the app.

Impact: slow reopen/update behavior at scale, paired with the 500-result cap.

Recommendation: use the persistent index backend, incremental updates, progress/cancel, and corruption fallback.

Code: PeopleDiscoveryView.swift around 23 and 618–633; LocalSearchIndex.swift 90–113 and 291–303.

### KSP-056 — Large-vault changes trigger broad hashing/rebuild work

Evidence: Code-confirmed performance risk.

Several projection/search paths hash or rebuild across the complete vault. The documented 50,000-person target needs dedicated performance and memory measurement; the current UI provides little progress or cancellation.

Recommendation: incremental projections, stable change tokens, background work, and 50k acceptance instrumentation.

### KSP-057 — Initial-avatar colors can change across launches

Evidence: Code-confirmed.

Color selection relies on Swift hashValue, which is intentionally randomized between process launches.

Impact: a person can appear with a different color later, weakening visual recognition.

Recommendation: stable cryptographic/non-random hash of the person's stable ID.

### KSP-058 — Archived people can become effectively undiscoverable

Evidence: UI structure + code.

If all people are archived, the default People view looks empty. The recovery control is buried in the long Filters sheet rather than the empty state.

Recommendation: an “Archived people” shortcut and count in the empty state, plus a dedicated archive browser.

### KSP-059 — P0 specification gap — Storage inventory is incomplete

Evidence: UI—Mac and UI—iPhone.

Settings reports People, Interactions, Sources, portrait bytes, pending reviews, and profile snapshots. It does not report retained extracted source text, transcript/draft payload storage, or deleted structured-record counts. Guided PDF/image import does not retain the original binary. “Recently deleted” counts only people.

Recommendation: a typed privacy/storage inventory with size, retention, export inclusion, and deletion controls.

### KSP-060 — Accessibility semantics need physical-device qualification; layout failures are confirmed

Evidence: confirmed Computer Use layout failures plus accessibility-tree observations/qualification gap.

- Confirmed: at maximum Dynamic Type, Back and Continue truncate to fragments before disappearing; the third onboarding screen is not scrollable.
- Observation requiring VoiceOver confirmation: the two reflection sliders appeared as generic slider elements while their visible labels were separate siblings.
- Observation requiring VoiceOver confirmation: the iPhone language selector appeared as an unlabeled tab group in the Computer Use accessibility snapshot.
- Several iPhone navigation-bar controls and search fields were absent from that snapshot even though Full Keyboard Access could eventually focus them, so this is not equivalent to a confirmed VoiceOver failure.
- Some disclosure rows required coordinate activation on Mac because the Computer Use accessibility action was inert; physical assistive-technology behavior remains to be tested.
- Each proposed import fact nests a Picker, TextField, and “Open source” Button inside a Toggle label, creating potentially ambiguous focus and activation semantics that require VoiceOver qualification.

Recommendation: explicit labels, values, hints, traits, focus order, and actions; test with VoiceOver on a physical device in addition to Full Keyboard Access.

Code observation: GuidedImportReviewView.swift 954–995.

### KSP-061 — P0 specification gap — Search facets are incomplete and asymmetric

Evidence: UI filter review + code-confirmed.

Custom select, multiselect, date-range, and reference fields fall back to known/unknown instead of value-level filtering. Time zone, language, channel, and tag filters lack symmetric exclusion. Relative cohort position/distance is absent even though the canonical model can calculate it.

Impact: documented “full facets/include-exclude” and compound-search jobs cannot be expressed.

Recommendation: implement value-aware typed facets, symmetric include/exclude, relative cohort filters, and an exact active-query summary.

Code: PeopleDiscoveryView.swift around 236–336, 815–846, and 1238–1251.

### KSP-062 — P0 specification gap — Contact handoff often omits the draft or recipient

Evidence: Code-confirmed from the user-facing Contact Draft flow; external apps were not opened.

Email, Messages, and WhatsApp URLs do not include the visible draft body/text. LINE and Snapchat only launch the destination app without targeting the saved recipient. Copy-to-clipboard remains a useful fallback, but the primary “Copy & open destination” contract does not consistently carry what the user reviewed.

Recommendation: prefill recipient and body where platform URL schemes safely allow it, label destinations that cannot, and keep an explicit clipboard fallback with return guidance.

### KSP-063 — Settings omits important defaults

Evidence: UI—Mac and UI—iPhone + code.

There is no Settings control for default source retention, conversation/transcript retention, or name display order. The import transcript default exists only as an internal AppStorage value in the importer.

Recommendation: expose privacy-safe defaults with “ask every time,” explain export/sync effects, and retain per-import override.

### KSP-064 — Person detail hides relationship-operating state

Evidence: UI—Mac and UI—iPhone.

Saved contacts, cadence, priority, snooze state, never-suggest, do-not-contact, aliases, and current nudge eligibility are largely hidden behind Edit. A snoozed person has no obvious Unsnooze action from detail or Today.

Recommendation: add concise Names, How to reach, and Suggestion settings cards with direct Unsnooze and eligibility explanation.

### KSP-065 — Add Hub is not reachable from normal Mac navigation

Evidence: UI—Mac + code.

AppSection.add is handled by the Mac destination switch, but the sidebar has no Add entry. The only global command is Shift-Command-N for Add Person; Interaction, Paste/document, and Profile Sharing must be found through other screens.

Recommendation: add an Add sidebar/toolbar entry or a complete global Add command menu that exposes the same four capture routes as iPhone.

### KSP-066 — File types are declared, but the app has no document-opening route

Evidence: Code-confirmed + qualification gap.

Keepsake declares exported vault/profile UTTypes, but registers no document-opening role and the root scene has no inbound onOpenURL/document handler. Users can select files only from nested file importers. Double-click, Open In, and Share-to-Keepsake behavior were not available to qualify.

Recommendation: register the intended imported document roles, route files into a review screen, handle locked/onboarding states safely, and retain nested pickers as an explicit alternative.

Code: Resources/Keepsake-Info.plist 27–90; RelationshipNotebookApp.swift 21–68.

### KSP-067 — High — Deleting a person does not disable that person's reminders

Evidence: Code-confirmed; notification delivery/tap requires signed-device qualification.

The scheduler creates requests for every enabled person reminder without checking the person's deletedAt state. Notification routing accepts any non-nil Person, including a tombstone. A reminder can therefore fire after its person was moved to Recently Deleted and can route back to deleted content.

Reproduction for signed-device qualification:

1. Create a future enabled reminder for a person.
2. Move the person to Recently Deleted.
3. Reconcile notification requests.
4. Inspect and tap the pending notification.

Expected: deleting/merging/archiving behavior is explicit; deleted-person reminders are disabled or removed, and stale notification taps show a safe tombstone/recovery state.

Recommendation: filter active canonical people during scheduling, cancel requests on deletion/merge, and validate the route again when a notification is opened.

Code: NotificationScheduler.swift 117–150; RootAndOnboarding.swift 135–147.

### KSP-068 — Medium — A missing or corrupt portrait can remain an infinite spinner

Evidence: Code-confirmed.

Portrait loading converts file/decode failure to nil with try? but has no failed state, fallback transition, error message, or retry. A missing, unreadable, or corrupt portrait can therefore display a perpetual progress indicator.

Recommendation: explicit loading/success/failure states, initials fallback, retry/remove actions, and a privacy-safe diagnostic.

Code: PortraitViews.swift 390–414.

## Confirmed lower-severity UX defects

1. The Today exhausted-pool message always blames boundaries/snoozes instead of naming cooldown, missing contact/context, frequency budget, never-suggest, or archive state.
2. Activity's blank interaction row can be created with almost no meaningful metadata; accidental Return activation produced a blank Kenji “Message.”
3. Recently Deleted's Restore affordance was not a distinct Mac accessibility element; clicking the row was inert and a coordinate click was required.
4. Activity rows omit additional participant names even when those participants affected recency.
5. Person deletion confirmation counts linked interactions but does not summarize facts, sources, memberships, reminders, photos, or profile links.
6. The People filter sheet is extremely long and mixes common relationship filters with advanced assertion/provenance rules without progressive disclosure.
7. Profile Sharing combines inbound import, version history, template choice, field editing, expiry, retention, preview, and export in one very long form.
8. Manual contacts have no visible remove control in the tested Mac accessibility hierarchy.
9. Contact preference is not visible on person detail; users must enter Edit to discover available routes.
10. The person editor's comma-separated entry makes duplicates and whitespace errors easy and gives no chip-level review before save.
11. Today emphasizes “people remembered” and “moments logged,” which reads like CRM accumulation rather than a calm relationship aid.
12. Onboarding has no page indicator and forcibly uses light appearance.
13. Japanese/English status values such as “Local only” remain mixed in localized screens.
14. Settings' protected/deletion-recovery copy refers to “protected JSON” while the underlying artifact is plaintext in some paths; wording should precisely identify encryption and file protection.
15. Notification enablement in the unsigned audit build remained off without an explanatory error. This exact result needs a signed-build qualification before classifying it as an app defect.

## Missing features and improvements

These are not all release blockers, but they close important user jobs or documented product promises.

### Relationship workflow

- A unified “next actions” inbox for reminders, follow-ups, commitments, pending reviews, and unresolved contact outcomes.
- Weekly/private reflection that summarizes relationship health without gamifying contact volume.
- Nudge feedback: too soon, wrong context, prefer another channel, adjust cadence, custom snooze, exclude, and explain why selected/excluded.
- A true random/allow-repeat Surprise mode separate from proactive cadence.
- Per-person preferred and avoided channels, recipient time zone, and communication preferences that actually affect suggestions and handoff.
- Contacts app linking and explicit update/relink behavior.
- Bulk edit for cadence, tags, contexts, privacy policy, archive, and source review.

### People, identity, and structure

- Optional self identity and relative cohort labels/filters.
- Typed multilingual names, histories, and display-order settings.
- Canonical context picker in quick person creation with migration of legacy strings.
- Natural-language/local query builder in addition to the advanced filter sheet.
- Saved-view management, criteria preview, and pagination.
- A dedicated archived browser.

### Capture and provenance

- Standalone notes and quick reminders from Add.
- Interaction detail/correction/deletion.
- Exact source/history/review/conflict UI for assertions.
- Share Extension for text, screenshots, images, and documents.
- Safe inbound document routing for double-click/Open In, including locked/onboarding states.
- Original-source retention with page/frame/region evidence.
- Optional reviewed AI extraction through the configured Shortcut.
- Portrait proposal with explicit confirmation.
- Conversation imports that can create a linked Interaction.

### Profile exchange

- Portrait transfer, QR display/scan, and nearby first-meeting flow.
- Saved-version browser, compare, reshare/export, revoke/archive, and expiry status.
- Clear split between Create Card, Received Profiles, and Saved Versions.
- Transactional import with per-field conflict review.

### Platform quality

- Mac Command-K search/navigation, drag/drop, person/import windows, and richer shortcuts.
- iPhone compact-landscape navigation that does not overlay content.
- iPad-specific split-view and multiwindow qualification.
- Complete Japanese localization and physical-device VoiceOver testing.

## External/device qualification matrix

The following were inspected at the UI entry points but not fully exercised because doing so requires external state or a signed/physical environment:

| Capability | What was inspected | Still required |
|---|---|---|
| CloudKit migration/sync | Toggles, status, migration copy, account-change architecture | Paid-team signed build, two devices, offline conflict, Apple Account change, quota/error cases |
| Push and local notifications | Permission toggle UI, quiet hours, reminder model/scheduler | Signed device, allow/deny/provisional states, background/APNs delivery, 60-request behavior, recurring-reminder delivery, locked/unlocked Today/person deep links, stale/deleted-person routes |
| Keepsake AI Shortcut/ChatGPT | Privacy disclosure, setup/cancel/allow UI, deterministic fallback | iOS/macOS 26 capable device, configured Shortcut, ChatGPT account modes, cancel/resume/error matrix |
| Photos | Add/manage entry and empty-state UI | Allow/limited/deny, multi-photo, corrupt/oversized, metadata stripping, primary/remove promotion |
| External contact apps | Draft and destination mapping inspected without opening/sending | Installed/absent Mail, Messages, Phone, LINE, Instagram, WhatsApp, Snapchat; return-outcome behavior |
| File receive/share/export | Format/scope/password/preview UI; no external share committed | Double-click/Open In/Share-to-Keepsake, received-profile import, Files destinations, cancellation, corrupt files, disk full, encryption round trip, forgotten password, exact saved-version reshare |
| PDF/image import and OCR | Picker/types and pasted-text evidence UI inspected; parser/OCR code reviewed | Real PDFs, mixed embedded/OCR pages, Japanese/English scans, multi-frame images, protected/corrupt/oversized files |
| iPad | Code/IA review only in this pass | Full iPad split-view, Stage Manager, keyboard, pointer, rotation, multitasking, and multiwindow |
| Accessibility settings | Confirmed max-Dynamic-Type and compact-landscape failures; Computer Use tree and Full Keyboard Access inspected | Physical-device VoiceOver rotor/focus/announcements/escape, Voice Control, Switch Control, Dark Mode, Increase Contrast, Differentiate Without Color, Reduce Motion, Reduce Transparency |
| Data-type/state matrix | Common person, interaction, context, membership, reminder, and custom-field paths | Every reminder recurrence/delivery state and every custom-field value/editor/filter type |

## Prioritized remediation plan

### P0 — Before another release candidate

1. Make App Lock transactional with authentication preflight and recovery.
2. Fix onboarding scrolling and all maximum Dynamic Type clipping.
3. Stop promising structured recovery until every deleted entity is restorable.
4. Make received-profile import atomic.
5. Invalidate deleted-person routes and block writes to tombstones.
6. Make reminder state truthful for past dates, the 60-request budget, and deleted people.
7. Enforce secret/custom-field privacy policy and exact reviewed export scope.

### P0 specification completeness

1. Replace counts-only archive review with per-record match, diff, conflict, and scope decisions.
2. Complete resumable import, optional reviewed AI/portrait proposals, exact source retention, and Share Extension entry.
3. Add portrait/QR profile exchange and a saved-version browser.
4. Add optional self identity, multilingual names, relative cohort filters, and complete search facets.
5. Complete the documented Mac capture/navigation workflow and privacy/storage inventory.
6. Make contact handoff carry the reviewed recipient/body where platform capabilities allow it.

### P1 — Data/workflow integrity

1. Unify canonical and legacy contexts.
2. Make group-interaction attribution complete.
3. Add interaction detail/correction/delete.
4. Convert follow-ups/commitments to real planning records and show them on Today.
5. Make reminder delivery status truthful, including past dates and scheduler capacity.
6. Add pending-import resume and correct lifecycle counts.
7. Expose immutable saved profile versions.
8. Enforce preferred contact and custom-field policy invariants.
9. Validate future dates and approximate-date semantics.
10. Fix export scope parity and define/test the vault-delete versus app-reset contract.

### P2 — Discoverability, accessibility, and scale

1. Put Contexts beside People on iPhone and replace landscape tab overlay.
2. Complete localization and explicit accessibility semantics.
3. Add saved-view lifecycle/pagination and persistent search indexing.
4. Simplify Add, Filters, and Profile Sharing with progressive disclosure.
5. Add self identity, multilingual names, notes, and archive recovery.

## Acceptance criteria for the next audit

- App Lock cannot be enabled unless a real authentication succeeds; no configuration can strand the user.
- Every onboarding page is completable at all Dynamic Type sizes in portrait and landscape.
- Retention copy and controls enumerate recap, commitment, transcript, reflection, final content, and generated draft independently, and the save layer enforces the selected choices.
- Every UI that says “Recently Deleted” offers an actual restore route for that entity.
- A received-profile import either commits every reviewed item or commits nothing.
- A deleted person immediately becomes non-actionable in every open route.
- Every interaction participant sees the same event with correct attribution.
- Follow-ups and commitments appear, can be completed/snoozed, and are visible on Today.
- Every enabled reminder shows an honest scheduled/delivery state.
- Deleting or merging a person cancels/retargets reminders and stale notification routes safely.
- Saved import reviews and profile versions are reopenable after app relaunch.
- People result 501 is reachable and the visible/exported saved-view scopes match.
- Preferred channel/contact and custom-field policies are enforced, not advisory.
- Archive import supports per-record scope and same-name/conflict decisions.
- Contact handoff carries the reviewed recipient/body where supported and clearly labels clipboard-only fallbacks.
- The iPhone SE landscape tab bar never covers primary content.
- VoiceOver and Full Keyboard Access can reach, identify, and operate every control.
