import SwiftUI

/// First launch: choose the name shown in "My code" and create the identity key.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                        .submitLabel(.done)
                        .onSubmit(create)
                        .accessibilityIdentifier("onboarding.name")
                } header: {
                    Text("What should your family see?")
                } footer: {
                    Text("This name is shown in your code. Your family can rename you on their phones.")
                }

                Section {
                    Button(action: create) {
                        HStack {
                            Text("Create my key")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    .accessibilityIdentifier("onboarding.create")
                } footer: {
                    Text("Your encryption key is made on this device and never leaves it. There is no backup yet: on a new phone you'll get a new key, and your family will need to scan your new code in person.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(Brand.displayName)
        }
    }

    private func create() {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try model.createIdentity(name: name)
        } catch {
            self.error = "Couldn't create your key: \(error)"
        }
    }
}
