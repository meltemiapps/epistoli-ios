import SwiftUI
import Messaging

/// First launch: choose the name shown in "My code" and create the identity key.
/// No demo screen of its own: it uses the chats list header and the demo's form card style.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Brand.displayName).font(.system(size: 34, weight: .bold)).kerning(0.2)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(Brand.asciiName) · private family messenger").font(.system(size: 13)).opacity(0.85)
                }
                .padding(.bottom, 6)

                Card {
                    Text("What should your family see?").font(.system(size: 16, weight: .semibold))
                    TextField("", text: $name, prompt: Text("Your name").foregroundStyle(.white.opacity(0.7)))
                        .font(.system(size: 16))
                        .textContentType(.name)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit(create)
                        .fieldStyle()
                        .accessibilityLabel("Your name")
                        .accessibilityIdentifier("onboarding.name")
                    Text("This name is shown in your code. Your family can rename you on their phones.")
                        .font(.system(size: 13)).opacity(0.9)
                }

                Button(action: create) {
                    HStack(spacing: 8) {
                        if working { ProgressView().tint(.white) }
                        Text("Create my key")
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                .accessibilityIdentifier("onboarding.create")

                Card(spacing: 6) {
                    Text("Your key").font(.system(size: 16, weight: .semibold))
                    Text("Your encryption key is made on this device and never leaves it. There is no backup yet: on a new phone you'll get a new key, and your family will need to scan your new code in person.")
                        .font(.system(size: 14)).lineSpacing(2).opacity(0.95)
                }

                if let error {
                    Text(error).font(.system(size: 14, weight: .semibold))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 120 / 255, green: 20 / 255, blue: 20 / 255).opacity(0.45), in: .rect(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .appScreen()
    }

    private func create() {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await model.createIdentity(name: name)
            } catch TransportError.accountUnavailable {
                error = "Sign in to iCloud in the Settings app first: your messages travel through your own iCloud."
            } catch {
                self.error = "Couldn't create your key: \(error)"
            }
        }
    }
}
