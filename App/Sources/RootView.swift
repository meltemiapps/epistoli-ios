import SwiftUI
import EpistoliCore

/// Placeholder shell. iPad (regular width) uses a split view, iPhone a stack.
/// The real chats list arrives in section 4.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingSettings = false

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                chatsList
            } detail: {
                ContentUnavailableView("No chat selected", systemImage: "bubble.left.and.bubble.right")
            }
        } else {
            NavigationStack {
                chatsList
            }
        }
    }

    private var chatsList: some View {
        List {
            ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
        }
        .navigationTitle(Brand.displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    .accessibilityIdentifier("chats.settings")
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}
