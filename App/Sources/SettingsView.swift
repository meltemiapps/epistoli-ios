import SwiftUI

/// Settings. Section 4 adds Appearance; for now: About.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    LabeledContent("Version", value: Self.versionString)
                    NavigationLink("Acknowledgements") {
                        AcknowledgementsView()
                    }
                    .accessibilityIdentifier("settings.acknowledgements")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    static var versionString: String {
        let version = Brand.string(for: "CFBundleShortVersionString")
        let build = Brand.string(for: "CFBundleVersion")
        return "\(version) (\(build))"
    }
}
