import SwiftUI
import EpistoliCore

/// iPad (regular width) uses a split view, iPhone a stack. Chats arrive in section 4; for now the
/// list shows contacts added with the QR button.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .failed(let message):
            ContentUnavailableView("Can't open your data", systemImage: "lock.trianglebadge.exclamationmark",
                                   description: Text(message))
        case .onboarding:
            OnboardingView()
        case .ready:
            MainView()
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingSettings = false
    @State private var showingKeyExchange = false
    @State private var selection: UUID?
    @State private var path: [UUID] = []

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                list
            } detail: {
                if let selection {
                    ContactDetailView(contactID: selection).id(selection)
                } else {
                    ContentUnavailableView("No chat selected", systemImage: "bubble.left.and.bubble.right")
                }
            }
        } else {
            NavigationStack(path: $path) {
                list.navigationDestination(for: UUID.self) { ContactDetailView(contactID: $0) }
            }
        }
    }

    private var list: some View {
        List(selection: sizeClass == .regular ? $selection : nil) {
            Section("Chats") {
                Text("Chats arrive in the next build.").foregroundStyle(.secondary)
            }
            Section("Contacts") {
                if model.contacts.isEmpty {
                    Text("No contacts yet. Tap the QR button to show your code or scan a family member's.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.contacts) { contact in
                    NavigationLink(value: contact.id) { ContactRow(contact: contact) }
                }
            }
        }
        .navigationTitle(Brand.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("QR code", systemImage: "qrcode") { showingKeyExchange = true }
                    .accessibilityIdentifier("chats.qr")
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    .accessibilityIdentifier("chats.settings")
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingKeyExchange) {
            KeyExchangeView { contact in show(contact.id) }
        }
    }

    private func show(_ id: UUID) {
        if sizeClass == .regular { selection = id } else { path = [id] }
    }
}
