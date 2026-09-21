# App Store Review Preflight — Phorganize 1.1.2

- App / platform: Phorganize Photo Organizer / macOS
- Version / build: **1.1.2 / 6**, update
- App Store Connect ID: `6780316718`; production bundle ID: `st.rio.phorganize`
- Guidelines checked: 2026-09-21; Apple displayed Last Updated June 8, 2026
- Readiness: **NOT READY** — archive prepared, but binary upload blocked by Xcode account authentication.
- Findings: **BLOCKER 1 / WARNING 2 / MANUAL 1**. Passing and inapplicable categories are identified in the coverage table; these counts describe actionable findings, not a compliance score.
- Current live observation: **1.1.1 (5), 配信準備完了**. New draft: **1.1.2, 提出準備中**.
- No submission action was performed. No Add for Review, Submit for Review, or public release action was taken.

## Actionable findings

### BLOCKER — build upload and selection

Xcode successfully archived the release but failed during App Store export/upload with `exportArchive Failed to Use Accounts`. The next message required App Store Connect access for the configured developer team. The browser's App Store Connect session works independently. No API key was found in the standard local private-key folders; no credentials were extracted or changed.

Action: reauthenticate the developer Apple Account in Xcode Settings, retry the existing archive export/upload, wait for Apple processing, resolve the build's export-compliance questionnaire, then select **1.1.2 (6)** in the draft. Upload success, processing, and selection are **not** yet verified. No distributable App Store package has been successfully exported.

Sources: [Guideline 2.1](https://developer.apple.com/app-store/review/guidelines/#app-completeness), [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds), [Choose a build](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit).

### WARNING — runtime qualification remains incomplete

The native computer-use connection failed before post-change interactive validation. Unit tests and actual SwiftUI/AppKit rendering passed, but live keyboard/menu routing, folder-sheet focus, drag/drop, move-confirmation interaction, VoiceOver, Intel hardware, and macOS 13 runtime were not qualified. Neither screenshots nor a Universal archive establish these outcomes.

Action: complete the interaction checklist in [the GUI review](hig-gui-review-2026-09-21.md) before submission, including a copy/move flow with disposable media. No user media was copied, moved or deleted during this release preparation.

Sources: [Guidelines 2.1 and 2.4](https://developer.apple.com/app-store/review/guidelines/#performance).

### WARNING — EU trader verification remains in review

Business → Compliance shows the Digital Services Act trader verification for 27 regions as **審査中** (last updated September 15, 2026). App availability shows 27 unavailable regions; no distribution settings were changed. Release readiness for those regions is not established by this preparation.

Action: wait for Apple's trader verification and confirm availability before claiming EU distribution. Existing available-region release preparation can continue.

Source: [Apple DSA trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements).

### MANUAL — existing legal declarations

The existing content-rights declaration, standard Apple EULA and trader declaration were observed and retained. Technical inspection does not independently certify ownership or regional legal compliance. No new legal claims or agreements were accepted.

Source: [Guidelines 5.2 and 5.6](https://developer.apple.com/app-store/review/guidelines/#legal).

## Coverage

| Family | Result | Evidence and applicability |
| --- | --- | --- |
| Safety | PASS / N/A | Local file organizer, no hosted UGC, messaging, children-specific category, medical claims, hardware control or criminal reporting. Support URL reachable. User-selected file access; no network entitlement. |
| Performance | BLOCKER / WARNING | Archive and 61 tests pass; binary upload/selection and broader runtime checks remain open. Public frameworks only; self-contained, sandboxed app. Source scanner camera signal is AVFoundation file metadata handling, not camera capture. |
| Business | PASS / N/A | No StoreKit, subscriptions, advertising, payment flow or IAP configuration in source. Existing price/distribution settings retained; 148 regions available, 27 unavailable. Paid/free app agreements, banking and tax statuses displayed active; no financial details copied into this record. |
| Design | PASS with runtime limits | Native macOS organizer with copy/move, metadata naming and duplicate handling. New screenshots match the updated view source. No web wrapper, downloaded code, extensions, mini apps, login services, or Game Center enabled. |
| Legal | PASS / MANUAL | Published Data Collection: None matches source and signed entitlements. Privacy policy reachable publicly and linked from Help. Manifest contains CA92.1 and 3B52.1; no tracking/collected-data types. No VPN, MDM or gambling functionality. Rights/trader declarations retained. |

## Build evidence

Toolchain: Xcode 27.0 (27A266a), macOS 27 SDK; host macOS 27.0 (26A428). Minimum target remains macOS 13. Archive uses the project production identity, not the isolated GUI-preview bundle ID.

- Release archive: **success**; binary contains **x86_64 and arm64**.
- Strict deep code signature verification: **success**.
- Signed entitlements: App Sandbox, user-selected read/write, app-scoped security bookmarks only.
- Archived Info.plist: version **1.1.2**, build **6**, bundle **st.rio.phorganize**, minimum **13.0**.
- Tests: **61 passed**, zero failures (47 core + 14 app).
- Distribution export/upload: **failed**, account authentication required.
- Local inspection script output includes unrelated older ignored build directories. Decisions above use the explicitly inspected new archive and current source; old build IDs and fixture-only signals were excluded.

Ignored evidence directory: `build/app-store/2026-09-21/` containing `Phorganize-1.1.2-6.xcarchive`, `archive.log`, `tests.log`, `upload.log`, `inspection-source.json`, `inspection-archive.json`, and `ExportOptions.plist`.

## App Store Connect preparation

- Created version **1.1.2** and saved English/Japanese What's New.
- Saved review instructions for the GUI changes, shortcuts, folder workflow, and move confirmation.
- Replaced inherited old-layout screenshots in the draft with **2 English and 2 Japanese** new-layout images. Previous released version was not edited.
- Screenshot assets are tracked in [app-store/1.1.2](app-store/1.1.2/), alongside exact release/review text.
- Screenshots are **1440 × 900 RGB JPEGs**, no transparency. They were captured from an offscreen native `NSHostingView` using the actual updated view source, fixture model initialization and disclosure state. The folder summary was calculated from 12 locally generated JPEG fixtures. No synthetic progress/results, user photos, private directories, or retouched controls appear in these store images. These are rendered product UI, not evidence of interactive archive execution.
- The native rendered images were individually opened for visual inspection; the Japanese uploads were also visually confirmed in the browser. Apple accepted both localized image sets without a size/format error.
- App Review login requirement remains off. Existing name, phone and email were confirmed visually and retained; sensitive contact values are omitted from this record. DOM-only reads incorrectly appeared blank again.
- App Information retained: English primary language; Utilities primary / Photo & Video secondary; age rating 4+ with regional equivalents; standard Apple EULA; existing third-party-content and trader declarations.
- App Privacy: published Data Collection: None; public bilingual policy at the existing GitHub URL.
- Pricing/availability retained: 148 available / 27 unavailable; public distribution. Business agreements, banking and tax status are active. DSA trader verification remains in review for 27 regions.
- Release options retained: automatic after approval, no phased rollout, preserve ratings.
- No build selected because this upload failed. No export-compliance answer was changed for an unavailable build.

Sources: [current App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

## Resume upload

After Xcode reauthentication, from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -exportArchive \
  -archivePath build/app-store/2026-09-21/Phorganize-1.1.2-6.xcarchive \
  -exportPath build/app-store/2026-09-21/export \
  -exportOptionsPlist build/app-store/2026-09-21/ExportOptions.plist \
  -allowProvisioningUpdates
```

The export options use `app-store-connect`, destination `upload`, automatic signing, and preserve version/build numbers. Update this record only after observing upload, processing and selection separately. Then complete the remaining runtime/manual checks. The current task requests release preparation; final review submission has not been requested.
