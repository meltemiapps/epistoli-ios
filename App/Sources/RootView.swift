import SwiftUI
import UIKit
import EpistoliCore
import Messaging

/// Pages pushed from the chats list. Every page draws its own header (ScreenHeader), as in the demo.
enum Route: Hashable {
    case addContact(KeyExchangeView.Tab)
    case checkCode(OfferedKey)
    case contact(UUID)
    case chat(ConversationID)
    case newGroup
    case settings
    case appearance
    case acknowledgements
    case acknowledgement(Acknowledgement)
}

/// The navigation path, shared so any page can open another or return to the list.
@MainActor @Observable
final class Router {
    var path: [Route] = []

    func open(_ route: Route) { path.append(route) }

    /// After a contact is added or updated: show it, with the list underneath.
    func show(contact id: UUID) { path = [.contact(id)] }

    /// Opens a chat with the list underneath (on iPad, in the detail pane).
    func show(chat id: ConversationID) { path = [.chat(id)] }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Appearance.self) private var appearance

    var body: some View {
        Group {
            switch model.phase {
            case .failed(let message):
                ContentUnavailableView("Can't open your data", systemImage: "lock.trianglebadge.exclamationmark",
                                       description: Text(message))
                    .appScreen()
            case .onboarding:
                OnboardingView()
            case .ready:
                MainView()
            }
        }
        .tint(appearance.accent)
        .preferredColorScheme(.dark)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var router = Router()

    var body: some View {
        content.task { model.startReceiving() }
    }

    @ViewBuilder private var content: some View {
        // iPad: the list stays on the left as a glass sidebar. iPhone: one stack.
        if sizeClass == .regular {
            NavigationSplitView {
                ChatsListView().toolbarVisibility(.hidden, for: .navigationBar)
            } detail: {
                NavigationStack(path: $router.path) {
                    ContentUnavailableView("No chat selected", systemImage: "bubble.left.and.bubble.right")
                        .appScreen()
                        .navigationDestination(for: Route.self) { RouteView(route: $0) }
                }
            }
            .environment(router)
        } else {
            NavigationStack(path: $router.path) {
                ChatsListView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .environment(router)
        }
    }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .addContact(let tab): KeyExchangeView(tab: tab)
        case .checkCode(let offer): ScanResultView(offer: offer)
        case .contact(let id): ContactDetailView(contactID: id)
        case .chat(let id): ChatView(id: id)
        case .newGroup: NewGroupView()
        case .settings: SettingsView()
        case .appearance: AppearanceView()
        case .acknowledgements: AcknowledgementsView()
        case .acknowledgement(let entry): AcknowledgementDetailView(entry: entry)
        }
    }
}

/// The first screen (demo: chats list): every chat, then contacts not written to yet.
struct ChatsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Brand.displayName).font(.system(size: 34, weight: .bold)).kerning(0.2)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(Brand.asciiName) · private family messenger").font(.system(size: 13)).opacity(0.85)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        RoundGlassButton(systemImage: "qrcode", label: "Add contact by QR code") {
                            router.open(.addContact(.myCode))
                        }
                        .accessibilityIdentifier("chats.qr")
                        RoundGlassButton(systemImage: "gearshape", label: "Settings") {
                            router.open(.settings)
                        }
                        .accessibilityIdentifier("chats.settings")
                    }
                }

                let rows = model.chatRows
                if rows.isEmpty {
                    Card(radius: 28) {
                        Text("No contacts yet").font(.system(size: 16, weight: .semibold))
                        Text("Tap the QR button to show your code or scan a family member's.")
                            .font(.system(size: 14)).opacity(0.88)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            Button { open(row) } label: { ChatListRow(row: row) }
                                .buttonStyle(.plain)
                            if index < rows.count - 1 {
                                Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                            }
                        }
                    }
                    .glass(28)

                    HStack {
                        Spacer()
                        Button { router.open(.newGroup) } label: {
                            Label("New group", systemImage: "plus").font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12).frame(height: 30)
                                .glass(15, tint: GlassSurface.nestedTint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chats.newGroup")
                    }
                }

                Text("No accounts, no tracking, no data collected")
                    .font(.system(size: 12)).opacity(0.85)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await model.receiveNow() }
        .appScreen()
    }

    private func open(_ row: ChatRow) {
        switch row {
        case .conversation(let conversation): router.show(chat: conversation.id)
        case .contact(let contact):
            if let id = try? model.openChat(with: contact) { router.show(chat: id) } else { router.open(.contact(contact.id)) }
        }
    }
}

/// Demo row: avatar, name, time, "PGP · last message".
struct ChatListRow: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: name)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let time { Text(time).font(.system(size: 13)).opacity(0.85) }
                }
                Group {
                    if !changed.isEmpty {
                        Label("Key changed · not checked in person", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(WarningLabelStyle())
                    } else {
                        Text(subtitle)
                    }
                }
                .font(.system(size: 14)).opacity(0.88).lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.\(name)")
    }

    private var name: String {
        switch row {
        case .conversation(let c): model.title(of: c)
        case .contact(let c): c.displayName
        }
    }

    private var changed: [Contact] {
        switch row {
        case .conversation(let c): model.keyChangedMembers(of: c)
        case .contact(let c): c.needsKeyChangeWarning ? [c] : []
        }
    }

    private var time: String? {
        guard case .conversation(let c) = row, let last = c.lastMessage else { return nil }
        let date = last.sentAt
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if let days = Calendar.current.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    private var subtitle: String {
        switch row {
        case .contact(let c):
            return (c.verification == .verified ? "Verified in person" : "Unverified · not scanned in person") + " · no messages yet"
        case .conversation(let c):
            let lock = c.pgp ? "PGP" : "TLS"
            guard let last = c.lastMessage else { return "\(lock) · no messages yet" }
            switch last.content {
            case .text(let text): return "\(lock) · \(text)"
            case .attachment(let info): return "\(lock) · \(info.name)"
            case .pgpSetting(let on): return "\(lock) · PGP turned \(on ? "on" : "off")"
            }
        }
    }
}

/// Round 44 pt button filled with the accent (demo: QR and Settings on the chats list).
struct RoundGlassButton: View {
    @Environment(Appearance.self) private var appearance
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 20, weight: .regular))
                .frame(width: 44, height: 44)
                .background(appearance.accentFill, in: .circle)
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The demo's custom headers hide the navigation bar, which also turns off the swipe from the left
/// edge to go back. This turns it back on.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
