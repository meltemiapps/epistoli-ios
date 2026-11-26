import SwiftUI

/// Settings › Acknowledgements: every third-party component and its licence text.
struct AcknowledgementsView: View {
    @Environment(Router.self) private var router
    let entries: [Acknowledgement]

    init(entries: [Acknowledgement]? = nil) {
        self.entries = entries ?? ((try? Acknowledgements.bundled()) ?? [])
    }

    var body: some View {
        ScreenScaffold(title: "Acknowledgements") {
            if entries.isEmpty {
                Card { Text("Notices unavailable").font(.system(size: 16, weight: .semibold)) }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button { router.open(.acknowledgement(entry)) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.name).font(.system(size: 16, weight: .semibold))
                                    Text("\(entry.version) · \(entry.licence)").font(.system(size: 13)).opacity(0.88)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).opacity(0.6)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("ack.\(entry.name)")
                        if index < entries.count - 1 { Rectangle().fill(.white.opacity(0.18)).frame(height: 1) }
                    }
                }
                .glass(28)
            }
            Text("This app is free software under the GNU General Public License v3.0. It includes these components, each under its own licence.")
                .font(.system(size: 12)).lineSpacing(2).opacity(0.85).padding(.horizontal, 6)
        }
    }
}

struct AcknowledgementDetailView: View {
    let entry: Acknowledgement

    var body: some View {
        ScreenScaffold(title: entry.name) {
            Card(spacing: 10) {
                ValueRow(title: "Version", value: entry.version)
                ValueRow(title: "Licence", value: entry.licence)
                ValueRow(title: "Source", value: entry.source)
                ValueRow(title: "Used for", value: entry.use)
            }
            Card {
                Text(entry.licenceText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}
