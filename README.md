# Επιστολή (Epistoli)

An open-source, serverless family messenger for iPhone and iPad.

There is no Epistoli server. Messages travel through the user's own cloud storage (iCloud in v1). Each chat can use OpenPGP end-to-end encryption, which is on by default. With PGP off, messages are still protected in transit by TLS and stored by the user's own cloud provider. Without PGP that provider can read them, and the app says so.

- iOS and iPadOS 26 or later, Swift 6, SwiftUI
- No analytics, crash reporting, ads or tracking. App Store privacy label: Data Not Collected.

## Availability

v1 is not available in France. See `docs/TRADEMARK_AUDIT.md`.

## Building

Needs Xcode 26 or later, Go 1.27.4 and XcodeGen:

```sh
brew install go xcodegen
scripts/bootstrap.sh     # fetch GRDB+SQLCipher, build the GopenPGP xcframework, generate the project
open Epistoli.xcodeproj
```

`Vendor/` and the `.xcodeproj` are generated and not committed. `scripts/build_gopenpgp.sh` builds GopenPGP reproducibly and checks the result against `scripts/gopenpgp.lock`. Brand strings live only in `Config/Base.xcconfig`; `scripts/brand_check.sh` enforces this.

## Licence

GPL-3.0-only. See `LICENSE`. Third-party components and their licences are listed in `docs/THIRD_PARTY_NOTICES.md`. Contributions need a DCO sign-off; see `CONTRIBUTING.md`.

Επιστολή™ and Epistoli™ are trademarks of Meltemi Apps. The GPL covers the code, not the name.
