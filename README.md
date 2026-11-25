# Επιστολή (Epistoli)

An open-source, serverless family messenger for iPhone and iPad.

There is no Epistoli server. Messages travel through the user's own cloud storage (iCloud in v1). Each chat can use OpenPGP end-to-end encryption, which is on by default. With PGP off, messages are still protected in transit by TLS and stored by the user's own cloud provider. Without PGP that provider can read them, and the app says so.

- iOS and iPadOS 26 or later, Swift 6, SwiftUI
- No analytics, crash reporting, ads or tracking. App Store privacy label: Data Not Collected.

## Availability

v1 is not available in France. See `docs/TRADEMARK_AUDIT.md`.

## Building

```sh
brew install xcodegen
xcodegen generate
open Epistoli.xcodeproj
```

The `.xcodeproj` is generated and not committed. Brand strings live only in `Config/Base.xcconfig`; `scripts/brand_check.sh` enforces this.

## Licence

GPL-3.0-only. See `LICENSE`. Contributions need a DCO sign-off; see `CONTRIBUTING.md`.

Επιστολή™ and Epistoli™ are trademarks of Meltemi Apps. The GPL covers the code, not the name.
