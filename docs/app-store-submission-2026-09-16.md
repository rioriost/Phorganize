# Phorganize 1.1.1 App Store submission

- App / platform: Phorganize Photo Organizer / macOS
- Version / build: 1.1.1 / 5
- App Store Connect ID: 6780316718
- Bundle ID: st.rio.phorganize
- Source baseline: 52546fa (plus the local Help menu and build-number changes listed below)
- Toolchain: Xcode 27.0 (27A266a), macOS 27 SDK
- Guidelines: checked 2026-09-16; Apple page displays Last Updated June 8, 2026
- Status: SUBMITTED — Apple displayed “1項目が提出されました” and Waiting for Review guidance after submitting 1.1.1 (5).

- Submission ID: c45aeaba-fdf0-4634-b1ca-fd51edf3a7a4
- Review URL: https://appstoreconnect.apple.com/apps/6780316718/distribution/reviewsubmissions/details/c45aeaba-fdf0-4634-b1ca-fd51edf3a7a4
- Final technical blockers: 0. One runtime-qualification warning remains; existing legal declarations were retained and are not independently certified by this audit.

## Build and validation

- Release archive succeeded for arm64 and x86_64.
- 58 tests passed (47 Core, 11 AppModel), including rerun after the Help menu change.
- Strict deep signature validation succeeded.
- Sandboxed; only user-selected read/write access and app-scoped bookmarks are enabled.
- Archived PrivacyInfo.xcprivacy has CA92.1 and 3B52.1, no collected data, no tracking.
- Archive app launched on this Apple Silicon Mac. Missing saved external folders produced an access-restoration message and disabled execution. The Japanese Help menu displayed Privacy Policy and Support.
- No user media was copied, moved, or deleted during this release task.
- Intel hardware, oldest supported macOS 13, external-media reconnect, and reboot tests were not performed.
- Upload succeeded at 17:01:18 JST. Build 4 was also uploaded earlier, but is superseded by build 5 and must not be selected for this submission.

## Release-specific change

The app lacked an in-app privacy-policy link. Added localized Privacy Policy and Support links to the standard Help menu, then increased the build number from 4 to 5. The user-authored file-organization changes were preserved. See [Guideline 5.1.1(i)](https://developer.apple.com/app-store/review/guidelines/#privacy).

## Preflight coverage

| Family | Result | Evidence |
| --- | --- | --- |
| Safety | PASS | Local user-selected file processing; no hosted content, posting, messaging, medical, or child-focused features. No network entitlement. |
| Performance | WARNING | Archive, signatures, 58 regression tests, and native launch passed. Broader hardware/OS/media qualification remains untested. |
| Business | PASS / NOT APPLICABLE | Existing public App Store distribution; no StoreKit, IAP, subscriptions, ads, or purchase UI in the source. Pricing and regional availability preserved. |
| Design | PASS | Native folder organizer with useful copy/move, metadata, naming, and duplicate handling. Existing English/Japanese screenshots depict the app. No extensions, web wrapper, or downloaded code. |
| Legal | PASS after remediation | Data Collection: None matches local-only source and entitlements. Public bilingual privacy policy is reachable, now linked in Help. Existing content-rights declaration and trader declaration inspected. |

## Actionable findings

- RESOLVED: The accessibility/DOM readout omitted contact values and initially suggested empty fields. A screenshot confirmed the existing telephone and email are populated. They were retained without modification. Apple accepted Add for Review with 1.1.1 (5).
- WARNING: Intel hardware, macOS 13, external-media reconnect/reboot are not qualified in this run. Universal architecture coverage and regression tests do not establish those runtime outcomes. [Guidelines 2.1 and 2.4](https://developer.apple.com/app-store/review/guidelines/#performance).
- MANUAL: No new rights/trader claims were introduced. Existing developer declarations were retained; this technical check does not establish legal ownership or regional compliance. [Guidelines 5.2 and 5.6](https://developer.apple.com/app-store/review/guidelines/#legal).

## App Store Connect evidence

- Prior delivered version: 1.1.0 (3).
- Created 1.1.1 and saved specific English/Japanese release notes.
- Saved review steps and description of file-protection changes plus Help links.
- Screenshots retained: three English and three Japanese.
- Review login requirement: off. Existing review contact phone and email visually confirmed; no values copied into this report. No special backend/hardware is needed.
- App Information: bundle ID matches; age rating 4+; Utilities primary and Photo & Video secondary; standard Apple EULA; existing declaration says no third-party content; trader declaration present.
- App Privacy: published Data Collection: None; policy URL points to the repository PRIVACY.md.
- Availability: 148 available, 27 unavailable; unchanged.
- Release: automatic after approval; no phased release; retain ratings.
- Export compliance: selected none of the listed algorithms; source uses Apple CryptoKit SHA-256 for file comparison, with no custom encryption. TestFlight changed to Ready to Submit. Version form has processed 1.1.1 (5) selected and saved. Build ID: 67faaf81-1ee2-43c5-9112-e9443b9b36f9.

## Local evidence

Archive and logs are stored in `build/app-store/2026-09-16/` (ignored build artifacts):

- `Phorganize-1.1.1-5.xcarchive`
- `archive-build5.log`
- `upload-build5.log`
- `tests-build5.log`
- `inspection.json`
- `ExportOptions.plist`
