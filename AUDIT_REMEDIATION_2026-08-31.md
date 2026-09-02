# Keepsake audit remediation — 2026-08-31

This document is the item-by-item disposition of `APP_UX_AUDIT_2026-08-30.md`. “Implemented” means the app and/or core invariant is present in this repository. It does not substitute for the signed-device and external-service qualification explicitly listed in `PLATFORM_QUALIFICATION_CHECKLIST.md`.

## Verification

| Check | Result |
|---|---|
| Swift package test suite | Passed: 287 tests, 0 issues |
| macOS Keepsake Debug build, signing disabled | Passed on the final integrated remediation snapshot |
| iOS Simulator Keepsake Debug build, signing disabled | Passed; embedded `KeepsakeShare` was built and validated |
| iOS Simulator `KeepsakeShare` build, signing disabled | Passed standalone and as an embedded app extension |
| Swift source parse and Xcode source membership | Passed for app, core, tests, and Share Extension |
| Project, entitlements, Info plists, and localization syntax | Passed |
| English/Japanese localization parity and source-literal coverage | Passed; 604 newly covered keys received genuine Japanese translations |
| Signed/physical-device and external-app matrix | Must be completed from `PLATFORM_QUALIFICATION_CHECKLIST.md` |

## Numbered findings

| Finding | Disposition | Primary evidence |
|---|---|---|
| KSP-001 | Implemented — enabling App Lock now authenticates first and commits only after success; disabling/recovery cannot strand the owner. | `SecurityViews.swift`; `ProductionAppSafetyArchitectureTests.swift` |
| KSP-002 | Implemented — onboarding content scrolls, navigation remains in a safe-area inset, and controls stack at accessibility sizes. | `RootAndOnboarding.swift`; `ProductionAppSafetyArchitectureTests.swift` |
| KSP-003 | Implemented — Recently Deleted restores supported structured entities with explicit row actions, not just people. | `CaptureAndSettingsViews.swift`; `RecoverableDeletionReferenceClosure.swift`; recovery tests |
| KSP-004 | Implemented — recap, commitment, transcript, reflection, final content, and generated draft retention are separately disclosed and enforced. | `CaptureAndSettingsViews.swift`; `Domain.swift`; storage inventory tests |
| KSP-005 | Implemented — received-profile review plans and all accepted writes commit transactionally or not at all. | `ProfileSnapshotStudioView.swift`; `CanonicalVaultStore.swift`; `ReceivedProfileSnapshotImportPlannerTests.swift` |
| KSP-006 | Implemented — tombstoned/merged people immediately lose edit/contact/add actions and stale routes resolve or close. | `TodayAndPeopleViews.swift`; `NotebookStore.swift`; lifecycle tests |
| KSP-007 | Implemented — interaction follow-ups and commitments project to first-class actionable planning records. | `RelationshipWorkflow.swift`; `RelationshipWorkflowTests.swift` |
| KSP-008 | Implemented — one group interaction is attributed consistently to primary and additional participants without contradictory duplicates. | `NotebookStore.swift`; participant conflict tests |
| KSP-009 | Implemented — interaction detail supports correction history, retention review, and recoverable deletion. | `CaptureAndSettingsViews.swift`; `RelationshipWorkflow.swift` |
| KSP-010 | Implemented — stable cursor paging exposes records beyond the first 500 and shows the visible range/total. | `PeopleDiscoveryView.swift`; `LocalSearchTests.swift` |
| KSP-011 | Implemented — quick/legacy context strings reconcile to canonical contexts and dated memberships, preserving unmatched values explicitly. | `NotebookStore.swift`; `CanonicalVaultStore.swift`; `AuditIdentityAndLifecycleTests.swift` |
| KSP-012 | Implemented — past one-time reminders are rejected or shown as unscheduled instead of appearing enabled. | `PlanningAndCustomFieldsViews.swift`; `NotificationScheduler.swift`; notification tests |
| KSP-013 | Implemented — the request budget is prioritized and reported; rows expose capacity/scheduling truth and reconcile errors surface. | `NotificationScheduler.swift`; `AppSessionController.swift`; notification tests |
| KSP-014 | Implemented — “save for later” persists a resumable review and exposes it in Imports and Today. | `DeterministicTextImport.swift`; `GuidedImportReviewView.swift`; import lifecycle tests |
| KSP-015 | Implemented — completed/cancelled reviews leave the pending count while retained provenance remains accessible. | `CanonicalVaultStore.swift`; `AuditImportProfileArchiveTests.swift` |
| KSP-016 | Implemented — immutable profile publications have a durable saved-version browser and detail route. | `ProfileSnapshotStudioView.swift`; `ProfileCardSnapshots.swift` |
| KSP-017 | Implemented — contact normalization enforces at most one preferred, non-avoided route and handoff selects by preference/channel. | `Domain.swift`; `CommunicationHandoff.swift`; workflow tests |
| KSP-018 | Implemented — future completed-interaction dates are blocked and approximate dates no longer silently masquerade as exact recency. | `CaptureAndSettingsViews.swift`; `NotebookStore.swift` |
| KSP-019 | Implemented — credential-like values are detected at the model boundary regardless of field label and excluded from mention/AI use. | `SensitiveFieldPolicy.swift`; sensitive-policy tests |
| KSP-020 | Implemented — fact creation loads and validates the chosen definition’s sensitivity and use-policy defaults. | `CanonicalPlanningAndFilters.swift`; `StructuredRelationshipViews.swift`; fact-policy tests |
| KSP-021 | Implemented — saved criteria are the single visible query state; ignored manual controls lock until “custom filters” is chosen. | `PeopleDiscoveryView.swift` |
| KSP-022 | Implemented — saved-view export uses the exact reviewed archived scope visible in People. | `ArchiveExportScope.swift`; `ArchiveExportScopeTests.swift` |
| KSP-023 | Implemented — whole-vault deletion names the exact vault/transient reset boundary and preserves app-level preferences. | `CaptureAndSettingsViews.swift`; platform architecture tests |
| KSP-024 | Implemented — retained PDF/image originals, source units, page/frame indexes, OCR confidence, and evidence regions are checksum-bound. | `DocumentTextExtractor.swift`; `DeterministicTextImport.swift`; import tests |
| KSP-025 | Implemented — manual random history is separate from proactive cadence, allow-repeat is explicit, and exclusion explanations are specific. | `NudgeEngine.swift`; `TodayAndPeopleViews.swift`; workflow tests |
| KSP-026 | Implemented — onboarding can capture an optional context/channel and previews the first deterministic local suggestion. | `RootAndOnboarding.swift`; platform architecture tests |
| KSP-027 | Implemented — examples are marked as sample data, visibly badged, excluded from accidental ambiguity, and removable together. | `Domain.swift`; `TodayAndPeopleViews.swift`; identity tests |
| KSP-028 | Implemented — reminder/commitment rows open management actions for complete, snooze, edit, disable, and delete. | `PlanningAndCustomFieldsViews.swift`; `RelationshipWorkflow.swift` |
| KSP-029 | Implemented — Today includes one next-actions inbox spanning reminders, commitments, follow-ups, pending reviews, and unresolved outcomes. | `TodayAndPeopleViews.swift`; `RelationshipWorkflowTests.swift` |
| KSP-030 | Implemented — empty Activity and planning states offer direct, valid creation routes. | `CaptureAndSettingsViews.swift`; `PlanningAndCustomFieldsViews.swift` |
| KSP-031 | Implemented — same-name pickers add stable portrait/initial, alias, context, contact, and identifier disambiguation. | `Theme.swift`; import/archive/profile/workflow pickers |
| KSP-032 | Implemented — changing an interaction’s primary person removes that identity from additional participants. | `CaptureAndSettingsViews.swift`; interaction tests |
| KSP-033 | Implemented — alternate call/meeting outcomes record the correct kind, channel, and evidence state instead of claiming a sent message. | `InteractionEvidenceTests.swift`; `RelationshipWorkflow.swift` |
| KSP-034 | Implemented — tags/contexts are normalized and previewed as chips; duplicate contacts collapse and preference invariants are enforced. | `Domain.swift`; `TodayAndPeopleViews.swift` |
| KSP-035 | Implemented — create/edit title derives from persisted identity and successful creation offers clear completion/open-profile feedback. | `TodayAndPeopleViews.swift` |
| KSP-036 | Implemented — custom definitions use stable unique keys and support edit, reorder, archive, restore, delete, validation, options, and cardinality. | `PlanningAndCustomFieldsViews.swift`; lifecycle tests |
| KSP-037 | Implemented — capability switches are enforced by real search/filter/sort/reminder/profile consumers and incompatible combinations are rejected. | `CanonicalPlanningAndFilters.swift`; fact-policy tests |
| KSP-038 | Implemented — assertions expose detail, confidence/certainty, sources, validity, review history, supersession, and conflict resolution. | `StructuredRelationshipViews.swift`; assertion tests |
| KSP-039 | Implemented — raw context/membership routes resolve merged identities before navigation. | `CanonicalVaultStore.swift`; `StructuredRelationshipViews.swift`; merge tests |
| KSP-040 | Implemented — guided import now covers files, OCR, retained originals, resumable decisions, reviewed Shortcut AI proposals, confirmed portraits, and linked conversation interactions. | `GuidedImportReviewView.swift`; `DeterministicTextImport.swift`; audit import tests |
| KSP-041 | Implemented — archive review is per-record with scope decisions, same-name choices, diffs, conflicts, identity/reference errors, and preserved-extension review. | `ArchiveImportReview.swift`; `CaptureAndSettingsViews.swift`; archive tests |
| KSP-042 | Implemented — profile exchange supports an explicitly selected sanitized portrait and bounded exact QR/file transfer. | `ProfileSnapshotStudioView.swift`; profile snapshot tests |
| KSP-043 | Implemented — Me is an optional self identity landing page; self uniqueness and relative-cohort search are enforced. | `RootAndOnboarding.swift`; `NotebookStore.swift`; identity tests |
| KSP-044 | Implemented — typed multilingual name variants preserve script, language, kana, romanization, validity, preferred form, and display order. | `Domain.swift`; `TodayAndPeopleViews.swift`; identity tests |
| KSP-045 | Implemented — canonical Contexts is adjacent to People in iPhone navigation instead of buried in Settings. | `RootAndOnboarding.swift`; `PeopleDiscoveryView.swift` |
| KSP-046 | Implemented — compact landscape uses non-overlay navigation and reserves content clearance for the phone tab bar. | `RootAndOnboarding.swift`; platform architecture tests |
| KSP-047 | Implemented and verified — onboarding switches its live locale and all app and Share Extension catalogs have English/Japanese key, format-token, duplicate-key, and source-literal parity. | `RootAndOnboarding.swift`; localization catalogs/tests |
| KSP-048 | Implemented — AI setup is scrollable, resizable, contrast-safe, and given a safe Mac minimum size. | `ShortcutPCCBridge.swift`; `Theme.swift` |
| KSP-049 | Implemented — empty vault, no matches, filtered-out, indexing, and search-error states are distinct. | `PeopleDiscoveryView.swift` |
| KSP-050 | Implemented — Add covers person, interaction, private note, reminder, commitment, photo/screenshot, document/text, archives, and profile/QR jobs. | `CaptureAndSettingsViews.swift` |
| KSP-051 | Implemented — Mac has Command-K navigation, capture shortcuts, drag/drop review, and independent person/import/profile scenes. | `RelationshipNotebookApp.swift`; `PlatformReliabilityViews.swift` |
| KSP-052 | Implemented — saved views support preview, rename/edit, duplicate, reorder, nudge-pool toggle, archive/restore, and delete. | `PeopleDiscoveryView.swift`; lifecycle tests |
| KSP-053 | Implemented — fatal open failure offers Retry, checkpoint review, privacy-safe diagnostics, and separate local-only recovery. | `RelationshipNotebookApp.swift`; `AppSessionController.swift`; platform tests |
| KSP-054 | Implemented — persistence/export/import/scheduling failures surface actionable messages while editors retain their drafts. | app editors/exporters; `AppSessionController.swift`; workflow tests |
| KSP-055 | Implemented — the app uses a checksummed file-backed search index with persistence and corruption fallback. | `LocalSearchIndex.swift`; `PeopleDiscoveryView.swift`; search tests |
| KSP-056 | Implemented — stable revision tokens and incremental/background updates replace broad UI hashing/rebuilds; indexing exposes progress/cancel. | `NotebookStore.swift`; `CanonicalVaultStore.swift`; `PeopleDiscoveryView.swift` |
| KSP-057 | Implemented — avatar color derives from a stable digest of stable identity, not randomized `hashValue`. | `Theme.swift`; platform tests |
| KSP-058 | Implemented — archived people have an empty-state recovery action and dedicated browser. | `PeopleDiscoveryView.swift`; `TodayAndPeopleViews.swift` |
| KSP-059 | Implemented — storage inventory separates all sensitive payload families and provides scoped review/removal/export actions. | `VaultStorageInventory.swift`; `StorageInventoryView.swift`; inventory tests |
| KSP-060 | Implemented in source; physical qualification remains — controls have explicit labels, hints, values, traits, focusable actions, adaptive layout, and no nested interactive Toggle labels. | app views; accessibility/platform tests; qualification checklist |
| KSP-061 | Implemented — symmetric include/exclude facets cover time zone, language, channel, tag, value-level custom types, and relative cohort position/distance. | `PeopleDiscoveryView.swift`; `LocalSearchModels.swift`; search tests |
| KSP-062 | Implemented — supported handoffs carry the reviewed recipient/body; clipboard-only fallbacks are explicit and evidence remains truthful. | `CommunicationHandoff.swift`; `TodayAndPeopleViews.swift`; workflow tests |
| KSP-063 | Implemented — Settings exposes default source/transcript retention, name display order, notification diagnostics, and per-import overrides. | `CaptureAndSettingsViews.swift`; `Theme.swift`; platform tests |
| KSP-064 | Implemented — person detail shows names, routes/preferences, cadence, boundaries, snooze/unsnooze, and eligibility explanation. | `TodayAndPeopleViews.swift` |
| KSP-065 | Implemented — Add Hub is a normal Mac sidebar/Command-3 destination. | `RootAndOnboarding.swift`; `RelationshipNotebookApp.swift` |
| KSP-066 | Implemented — declared document types route through a locked/onboarding-safe review; archives and profile files reach their dedicated reviewed importer. | `Keepsake-Info.plist`; `PlatformReliabilityViews.swift`; platform tests |
| KSP-067 | Implemented — reminder projection excludes deleted/missing people, deletion reconciles notifications, and stale taps cannot open tombstones. | `NotificationScheduler.swift`; `AppSessionController.swift`; notification tests |
| KSP-068 | Implemented — portrait loading has explicit loading/success/failure states, initials fallback, retry/remove actions, and a privacy-safe diagnostic code. | `PortraitViews.swift`; platform tests |

## Confirmed lower-severity defects

| Audit item | Disposition |
|---|---|
| 1. Exhausted suggestion explanation | Implemented with reason-specific eligibility reporting for cooldown, route, frequency, never-suggest, archive, and snooze. |
| 2. Blank interaction | Implemented with concrete-detail validation before save. |
| 3. Recently Deleted accessibility | Implemented as explicit labeled Restore/Delete buttons. |
| 4. Additional participants missing in Activity | Implemented; rows and detail identify every participant. |
| 5. Incomplete deletion counts | Implemented; confirmation counts interactions, reminders, commitments, facts, sources, profile versions, portraits, and structured memberships/education. |
| 6. Overlong People filters | Implemented with common filters first and advanced structure/provenance/custom facets behind disclosure. |
| 7. Overloaded Profile Sharing form | Implemented as Create Card, Received Profiles, and Saved Versions workspaces. |
| 8. Contacts cannot be removed | Implemented with explicit per-route removal and Contacts unlink/relink. |
| 9. Preference hidden on detail | Implemented in the How to Reach card. |
| 10. Comma-list errors | Implemented with normalized chip previews and duplicate removal before save. |
| 11. CRM-like Today metrics | Replaced by an actionable inbox and nongamified private weekly reflection. |
| 12. Onboarding indicator/forced light | Implemented with progress and adaptive semantic colors. |
| 13. Mixed Japanese/English statuses | Centralized EN/JA catalogs and parity test; final sweep is part of verification. |
| 14. Ambiguous protected/plaintext wording | Copy now distinguishes encrypted archives, file protection, and plaintext exports precisely. |
| 15. Unsigned notification failure | App now explains authorization/build state; actual delivery remains a signed-device qualification item. |

## Missing-feature and improvement list

### Relationship workflow

- Implemented: unified next-actions inbox; weekly private reflection; reasoned nudge feedback; true random/allow-repeat Surprise mode; custom snooze; cadence and exclusion controls.
- Implemented: preferred/avoided routes, recipient time zone, and communication preference affect eligibility and handoff.
- Implemented: Contacts permission, link, refresh/relink, unlink, and manual fallback.
- Implemented: bulk cadence, tags, canonical contexts, contact boundary/privacy, archive/restore, and assertion source-review policy.

### People, identity, and structure

- Implemented: optional unique self identity, typed multilingual names/history/display order, canonical quick contexts, relative cohort filters/labels, full saved-view lifecycle/pagination, and archived browser.
- Implemented: deterministic on-device natural/local query builder with an exact interpretation preview; no notebook data leaves the device.

### Capture and provenance

- Implemented: standalone notes/reminders/commitments/photos; interaction detail/correction/delete; exact assertion provenance/history/conflict review.
- Implemented: a localized iOS Share Extension with complete-file-protected App Group staging, 20-item/100 MB bounds, no direct record creation, and locked-safe explicit review.
- Implemented: double-click/Open In/drag/drop routing; retained originals and page/frame/region evidence; reviewed Shortcut AI and portrait proposals; conversation-to-Interaction review.

### Profile exchange

- Implemented: sanitized portrait transfer, QR display/scan, nearby first-meeting flow, saved-version browse/compare/reshare/archive/expiry state, split workspaces, and transactional field-level conflict review.
- A previously distributed static file/QR copy cannot be remotely revoked; the app labels this honestly. Live remotely revocable sharing remains a separately gated product capability, not a defect in static export.

### Platform quality

- Implemented in source: Mac Command-K, drag/drop, person/import/profile windows and shortcuts; compact-landscape safe navigation; Japanese catalogs; adaptive accessibility semantics.
- Requires external qualification: iPad split view/Stage Manager/multiwindow, physical-device VoiceOver/Voice Control/Switch Control, signed notifications, Photos permissions, external communication apps, CloudKit, Shortcuts/ChatGPT, and real Files/share-provider behavior. No source-only result is represented as proof of those environments.

## External qualification

Every item from the audit’s external/device matrix is retained, expanded with exact setup, expected evidence, and failure cases in `PLATFORM_QUALIFICATION_CHECKLIST.md`. Release sign-off must attach device/OS/build identifiers and artifacts to that checklist rather than changing these boxes based on simulator or static inspection alone.
