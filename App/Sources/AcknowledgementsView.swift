import SwiftUI

/// Settings › Acknowledgements: every third-party component and its licence text.
struct AcknowledgementsView: View {
    let entries: [Acknowledgement]

    init(entries: [Acknowledgement]? = nil) {
        self.entries = entries ?? ((try? Acknowledgements.bundled()) ?? [])
    }

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    NavigationLink(value: entry) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.body)
                            Text("\(entry.version) · \(entry.licence)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("ack.\(entry.name)")
                }
            } footer: {
                Text("This app is free software under the GNU General Public License v3.0. It includes these components, each under its own licence.")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationDestination(for: Acknowledgement.self) { entry in
            AcknowledgementDetailView(entry: entry)
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("Notices unavailable", systemImage: "doc.questionmark")
            }
        }
    }
}

struct AcknowledgementDetailView: View {
    let entry: Acknowledgement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Version", value: entry.version)
                LabeledContent("Licence", value: entry.licence)
                LabeledContent("Source", value: entry.source)
                LabeledContent("Used for", value: entry.use)
                Divider()
                Text(entry.licenceText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding()
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
