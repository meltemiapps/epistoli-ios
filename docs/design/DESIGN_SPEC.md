# Epistoli v1 design spec (approved demo, 25 Nov 2026)

Source of truth: `demo-iphone.html` and `demo-ipad.html` in this folder (the approved demo; HTML/CSS mock, not runnable on its own). Match these screens in SwiftUI. Where SwiftUI's native Liquid Glass differs slightly from the CSS approximation, prefer native `.glassEffect` but keep layout, colours, copy and hierarchy identical.

## Backgrounds (full-screen, behind everything)
Each preset is a layered gradient plus a 18% black dim layer for legibility. Accent colour follows the background.

| Preset | Accent | Gradient (from demo CSS) |
|---|---|---|
| Aegean (default) | #1E88E5 | radial #5fc3e8 at 20%/15%; radial #0d3b66 at 85%/85%; linear 165° #2a86c4 → #0b2d4f |
| Sunset | #E8590C | radial #ffb36b at 70%/20%; radial #5b2a86 at 10%/90%; linear 170° #d9603b → #3b1d5c |
| Olive | #2E7D32 | radial #a5c47a at 25%/25%; radial #243b1c at 90%/85%; linear 170° #5e7f3a → #1e2f17 |
| Night | #5E5CE6 | radial #4b4fa8 at 75%/20%; radial #10162e at 15%/90%; linear 170° #26285e → #0a0d1f |

"Choose from Photos…" uses the picked photo instead of a gradient, with the same dim layer; accent derived from the photo.
Reduce Transparency on: solid dark surface instead of glass, same layout.

## Glass surfaces
Cards, list containers, header bars, composer: white at 16–18% over the background, blur ~28 pt with saturation, 1 pt white border at 35%, large corner radius (lists 28, header 26, composer 28, sheets 30, buttons 16–22). All text white.

## Screens (iPhone)
- Chats list: large title "Επιστολή", subtitle "Epistoli · private family messenger", round glass QR and Settings buttons top right; glass list of chats (avatar initial, name, time, "PGP · last message"); footer "No accounts, no tracking, no data collected". Channels section is v1.2, do not build.
- Chat: floating glass header (back, name, "End-to-end encrypted"/"Encrypted in transit", PGP chip filled with accent when on); dark explanation banner under it; bubbles: mine = accent at 70% opacity, theirs = white 20% glass; attachment card (icon tile, file name, size · source); floating glass composer (+ button, field, accent send button).
- Attach sheet: dark glass sheet, "Attach, encrypted on your phone before it leaves", Photos / Files / iCloud Drive (Google Drive comes in build 2), Cancel.
- Add contact (QR): title "Add contact", segmented My code / Scan in glass; My code card with white QR tile, name, fingerprint, explanation; Scan card with viewfinder.
- Settings › Appearance: background swatches grid (4), selected has white ring, "Choose from Photos…", Privacy card text.
- Apply the same glass treatment to the Checkpoint C screens (Check code, contact detail, key-change warning, Settings, Acknowledgements).

## iPad
NavigationSplitView: glass sidebar with chats, chat pane as on iPhone, Sunset shown in demo.
