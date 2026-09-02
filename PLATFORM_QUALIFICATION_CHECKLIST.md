# Keepsake platform qualification checklist

This checklist records tests that require signing, physical hardware, external
apps/accounts, or assistive-technology observation. A checked item must include
the app version/build, OS/device, result, and evidence link. An automated build
or simulator run does **not** qualify any unchecked item below.

Build: __________  Commit: __________  Tester/date: __________

## Accessibility and appearance (KSP-047, KSP-048, KSP-060)

- [ ] iPhone SE-class device, portrait and landscape, Accessibility XXXL: every onboarding page scrolls; Back, Continue, setup status, and optional first-person controls remain reachable.
- [ ] VoiceOver, English and Japanese: the onboarding language control announces its label, selected language, and immediate language change; setup progress announces “step N of 4.”
- [ ] VoiceOver: both optional-reflection sliders announce distinct labels, values from 1–5, hints, and adjustable actions in a sensible focus order.
- [ ] VoiceOver: tab/compact navigation, navigation-bar buttons, search fields, disclosure rows, Recently Deleted restore actions, and import-review controls are reachable and operable without coordinate taps.
- [ ] VoiceOver: each proposed import fact announces selection separately from its destination picker, editable value, and Open Source action; no nested control steals the parent action.
- [ ] Voice Control and Switch Control: name every actionable control on onboarding, import review, person detail, Settings, and photo recovery; confirm there are no duplicate ambiguous names.
- [ ] Full Keyboard Access (iPhone/iPad) and keyboard navigation (Mac): focus order follows the visual order; Escape dismisses sheets; Return does not create a blank record.
- [ ] Dark Mode, Increase Contrast, Differentiate Without Color, Reduce Motion, and Reduce Transparency: onboarding, App Lock, warning panels, AI setup, diagnostics, and received-file review remain legible.
- [ ] Mac at minimum supported window size and 200% text scaling: AI setup scrolls without clipping Shortcut name, privacy copy, verification, or bottom actions.

## Navigation and windows (KSP-046, KSP-051)

- [ ] iPhone SE-class portrait: scroll every tab to its final row/card and confirm the floating tab bar does not cover content.
- [ ] iPhone compact landscape: the section menu replaces the tab bar and never crosses primary content or controls.
- [ ] iPad portrait/landscape, Split View widths, Stage Manager, rotation, pointer, and hardware keyboard: split navigation remains reachable and preserves the current person route.
- [ ] iPad multiwindow: open independent windows where the OS exposes them; verify App Lock and account-recovery states cover every scene.
- [ ] Mac Command-K searches sections, people, aliases, and opens a selected person; Command-1/2/3 route to Today/People/Add.
- [ ] Mac Shift-Command-I and Shift-Command-P open independent Import Review and Profile Sharing windows; two person windows can remain open simultaneously.
- [ ] Drag text/PDF/image/archive/profile files onto the Mac window and confirm the same locked-safe received-file review used by Open In appears.

## Signed notification qualification (lower defect 15)

- [ ] Signed physical device: test Not Determined → Allow, Not Determined → Deny, Denied, Provisional, and later System Settings changes. The toggle must stay on only after authorization and otherwise show an actionable explanation.
- [ ] Signed physical device: inspect background/APNs registration status in Settings for sync off, registering, registered, and unavailable states.
- [ ] Verify 60-request capacity behavior, every recurrence option, foreground/background delivery, quiet hours, and notification preview names off/on.
- [ ] Tap Today/person reminders while unlocked, App Locked, onboarding incomplete, person active, person Recently Deleted, and person permanently deleted. No deleted-person route may open.

## File receive, import, export, and recovery (KSP-053, KSP-066)

- [ ] Double-click/Open In each declared type: `.relationshipvault` package, encrypted vault, `.keepsakeprofile`, UTF-8/UTF-16 text, PDF, and image. Nothing is read while onboarding or App Lock is active.
- [ ] Share/drag several files in sequence while locked; unlock and confirm each appears exactly once in order.
- [ ] From Photos, Files, Safari, Mail, and Notes, choose “Save to Keepsake”; verify text, links, screenshots, images, PDFs, and documents enter the protected App Group inbox, respect the 20-item/100 MB limits, and are not read until onboarding and App Lock are clear.
- [ ] Kill the Share Extension during transfer, relaunch Keepsake after 24 hours, and verify incomplete staging is removed without creating records; verify a completed share remains durable when iOS does not foreground Keepsake.
- [ ] Text/PDF/image receive: confirm extraction creates only a pending review, then resume it and verify the per-import retention override remains editable.
- [ ] Test Japanese/English scans, mixed embedded-text/OCR PDFs, multi-page and multi-frame sources, protected/corrupt/oversized files, cancellation, and disk-full behavior.
- [ ] Test Files destinations and cancellation for plaintext JSON, media packages, and encrypted archives; verify checksums and encryption round trips and the forgotten-password path.
- [ ] Force local and cloud notebook-open failures. Verify Retry, privacy-safe diagnostic reference, reviewed checkpoint reopening, and separate local-only recovery; no notebook is merged or erased silently.

## Photos and external apps (KSP-068 and platform integrations)

- [ ] Photos permission Allow/Limited/Deny; import multiple, corrupt, and oversized images; verify metadata stripping, primary promotion, and removal.
- [ ] Delete or corrupt a stored portrait file. Confirm initials replace the spinner, Retry is operable, Remove remains available, and the shown diagnostic contains no path or person data.
- [ ] Mail, Messages, Phone, LINE, Instagram, WhatsApp, and Snapchat installed/absent: verify reviewed recipient/body behavior, clipboard-only labels, cancellation, and return guidance without sending during the test.
- [ ] On supported iOS/macOS 26 hardware, run the Keepsake AI Shortcut setup/cancel/resume/error matrix with signed-in and signed-out ChatGPT modes. Record that transport verification does not attest model/account/retention.

## Cloud and data-state matrix

- [ ] Paid-team CloudKit build on two devices: first move, offline edits, conflicts, quota/service errors, account change, protected checkpoint recovery, and eventual deletion delivery.
- [ ] Verify every custom-field editor/filter type and every reminder recurrence/delivery state with active, archived, merged, Recently Deleted, and permanently deleted people.
- [ ] Delete Entire Vault locally and with iCloud enabled. Confirm vault records, portraits, pending record routes, pending person AI handoffs, suggestion history, and scheduled reminders clear; language, App Lock, notification preference, AI setup, and import/name defaults remain.
