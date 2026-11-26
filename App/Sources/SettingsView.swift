import SwiftUI

/// Settings. Section 4 adds Appearance; for now: About.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var debugMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let identity = model.identity {
                    Section {
                        LabeledContent("Name", value: identity.displayName)
                        LabeledContent("Protected by", value: model.keyProtection)
                            .accessibilityIdentifier("settings.keyprotection")
                        FingerprintView(fingerprint: identity.fingerprint, title: "Your fingerprint")
                            .frame(maxWidth: .infinity)
                    } header: {
                        Text("Your key")
                    } footer: {
                        Text("Your key exists only on this device. There is no backup yet.")
                    }
                }
                #if DEBUG
                Section {
                    Button("Simulate new phone") {
                        do {
                            try model.simulateNewPhone()
                            debugMessage = "New key created. Your name and address are unchanged."
                        } catch {
                            debugMessage = "Failed: \(error)"
                        }
                    }
                    .accessibilityIdentifier("settings.debug.newphone")
                    if let debugMessage { Text(debugMessage).font(.footnote) }
                } header: {
                    Text("Developer (Debug builds only)")
                } footer: {
                    Text("Replaces your key but keeps your name and address, as a new phone would. Use it to test the key-change warning on another device.")
                }
                #endif
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
