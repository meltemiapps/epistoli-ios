import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import EpistoliCore
import Messaging

/// A chat (demo: floating glass header with the PGP chip, explanation banner, bubbles, composer).
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let id: ConversationID

    @State private var draft = ""
    @State private var attaching = false
    @State private var pickingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var pickingFile = false
    @State private var confirmingPGPOff = false
    /// A send waiting for the key-change warning to be answered.
    @State private var pendingSend: PendingSend?
    /// Set after "Send anyway": the warning is shown before the first send of each visit to the chat.
    @State private var warnedAboutKeyChange = false
    @State private var preview: URL?
    @FocusState private var composing: Bool

    struct PendingSend: Identifiable {
        let id = UUID()
        let names: String
        let action: @MainActor () async -> Void
    }

    var body: some View {
        if let conversation = model.conversation(id) {
            let changed = model.keyChangedMembers(of: conversation)
            VStack(spacing: 0) {
                ChatHeader(conversation: conversation, title: model.title(of: conversation)) {
                    if conversation.pgp { confirmingPGPOff = true } else { Task { await model.setPGP(true, in: id) } }
                } openDetails: {
                    if conversation.kind == .direct, let contact = conversation.members.first.flatMap(model.contact(address:)) {
                        router.open(.contact(contact.id))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)

                VStack(spacing: 8) {
                    PGPBanner(on: conversation.pgp, allVerified: allVerified(conversation))
                    ForEach(changed) { KeyChangeBanner(name: $0.displayName) }
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)

                MessageList(conversation: conversation, messages: model.messages(in: id), preview: $preview)

                if let error = model.sendError {
                    Button { model.sendError = nil } label: {
                        Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(10)
                            .background(.black.opacity(0.45), in: .rect(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.bottom, 6)
                    .accessibilityIdentifier("chat.error")
                }

                Composer(draft: $draft, composing: $composing) {
                    attaching = true
                    composing = false
                } send: {
                    let text = draft
                    guarded(changed) { draft = ""; await model.send(text: text, in: id) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                if attaching {
                    AttachSheet(pgp: conversation.pgp) { source in
                        attaching = false
                        if source == .photos { pickingPhoto = true } else { pickingFile = true }
                    } cancel: {
                        attaching = false
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.25), value: attaching)
            .appScreen()
            .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .any(of: [.images, .videos]))
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task {
                    guard let attachment = await Self.load(item) else { model.sendError = "Couldn't read that photo."; return }
                    guarded(changed) { await model.send(attachment: attachment, in: id) }
                }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                switch Self.load(url) {
                case .success(let attachment): guarded(changed) { await model.send(attachment: attachment, in: id) }
                case .failure(let error): model.sendError = AppModel.describe(error)
                }
            }
            .quickLookPreview($preview)
            .onChange(of: preview) { old, new in
                // The decrypted copy for Quick Look exists only while it's open.
                if new == nil, let old { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
            }
            .confirmationDialog("Turn PGP off for this chat?", isPresented: $confirmingPGPOff, titleVisibility: .visible) {
                Button("Turn PGP off", role: .destructive) { Task { await model.setPGP(false, in: id) } }
                    .accessibilityIdentifier("pgp.confirmOff")
            } message: {
                Text("New messages will be protected in transit (TLS) and by your cloud provider, who could technically read them. Everyone in the chat sees the change.")
            }
            .alert(item: $pendingSend) { pending in
                Alert(title: Text("\(pending.names)'s key changed"),
                      message: Text("It hasn't been checked in person, so you can't be sure who can read this. Scan their code next time you meet."),
                      primaryButton: .default(Text("Send anyway")) {
                          warnedAboutKeyChange = true
                          Task { await pending.action() }
                      },
                      secondaryButton: .cancel())
            }
        } else {
            ContentUnavailableView("No chat", systemImage: "bubble.left.and.exclamationmark.bubble.right").appScreen()
        }
    }

    private func allVerified(_ conversation: Conversation) -> Bool {
        conversation.members.allSatisfy { model.contact(address: $0)?.verification == .verified }
    }

    /// Warns before the first send while a member's key change hasn't been checked in person.
    private func guarded(_ changed: [Contact], _ action: @escaping @MainActor () async -> Void) {
        if changed.isEmpty || warnedAboutKeyChange {
            Task { await action() }
        } else {
            pendingSend = PendingSend(names: ListFormatter.localizedString(byJoining: changed.map(\.displayName)), action: action)
        }
    }

    // MARK: Picking

    private static func load(_ item: PhotosPickerItem) async -> OutgoingAttachment? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first ?? .jpeg
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                                               timeZone: .current, calendar: .current))
        return OutgoingAttachment(data: data, name: "Photo-\(stamp).\(type.preferredFilenameExtension ?? "jpg")",
                                  mime: type.preferredMIMEType ?? "application/octet-stream", source: .photos)
    }

    private static func load(_ url: URL) -> Result<OutgoingAttachment, any Error> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return Result {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= AttachmentLimits.maxBytes else { throw MessagingError.attachmentTooLarge }
            let data = try Data(contentsOf: url)
            let type = UTType(filenameExtension: url.pathExtension)
            // Files in iCloud Drive live under "Mobile Documents"; anything else came from Files.
            let source: AttachmentSource = url.path.contains("/Mobile Documents/") ? .iCloudDrive : .files
            return OutgoingAttachment(data: data, name: url.lastPathComponent,
                                      mime: type?.preferredMIMEType ?? "application/octet-stream", source: source)
        }
    }
}

// MARK: Header and banners

/// Floating glass header: back, name, encryption state, PGP chip.
private struct ChatHeader: View {
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    let title: String
    let togglePGP: () -> Void
    let openDetails: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to chats")
            .accessibilityIdentifier("header.back")

            Button(action: openDetails) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Text(conversation.pgp ? "End-to-end encrypted" : "Encrypted in transit")
                        .font(.system(size: 12)).opacity(0.9)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.title")

            Button(action: togglePGP) {
                Label(conversation.pgp ? "PGP on" : "PGP off", systemImage: conversation.pgp ? "lock" : "lock.open")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(conversation.pgp ? AnyShapeStyle(appearance.accentFill) : AnyShapeStyle(.black.opacity(0.25)), in: .capsule)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(conversation.pgp ? "PGP on" : "PGP off")
            .accessibilityHint("Turns PGP on or off for this chat")
            .accessibilityIdentifier("chat.pgp")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glass(26)
    }
}

/// The dark explanation banner under the header.
struct PGPBanner: View {
    let on: Bool
    let allVerified: Bool

    var text: String {
        if !on { return "PGP off: protected in transit (TLS) and by your cloud provider, who could technically read it." }
        return allVerified
            ? "PGP on: only the people in this chat can read it. Keys checked by QR code."
            : "PGP on: only the people in this chat can read it. Scan their code in person to check their key."
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12)).lineSpacing(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.32), in: .rect(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("banner.pgp")
    }
}

// MARK: Messages

private struct MessageList: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let messages: [ChatMessage]
    @Binding var preview: URL?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if messages.isEmpty {
                        Text("No messages yet").font(.system(size: 14)).opacity(0.85).padding(.top, 24)
                    }
                    ForEach(messages) { message in
                        MessageRow(message: message, showSender: conversation.kind == .group, preview: $preview)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) { _, last in
                if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
    }
}

private struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let showSender: Bool
    @Binding var preview: URL?

    var body: some View {
        switch message.content {
        case .pgpSetting(let on):
            Text("\(model.name(of: message.sender)) turned PGP \(on ? "on" : "off") for this chat")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.32), in: .capsule)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("chat.setting")
        case .text, .attachment:
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 3) {
                if showSender && !message.outgoing {
                    Text(model.name(of: message.sender)).font(.system(size: 12, weight: .semibold)).opacity(0.9).padding(.horizontal, 8)
                }
                bubble
                if !message.pgp {
                    Label("Encrypted in transit only", systemImage: "lock.open").font(.system(size: 11)).opacity(0.85).padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: message.outgoing ? .trailing : .leading)
        }
    }

    @ViewBuilder private var bubble: some View {
        switch message.content {
        case .text(let text):
            Text(text)
                .font(.system(size: 16)).lineSpacing(1.5)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .bubble(mine: message.outgoing)
                .containerRelativeFrame(.horizontal, alignment: message.outgoing ? .trailing : .leading) { width, _ in width * 0.76 }
                .accessibilityIdentifier(message.outgoing ? "bubble.mine" : "bubble.theirs")
        case .attachment(let info):
            Button { open(info) } label: {
                HStack(spacing: 10) {
                    AttachmentTile(info: info)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info.name).font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(info.detail).font(.system(size: 12)).opacity(0.9)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .bubble(mine: message.outgoing)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 300, alignment: message.outgoing ? .trailing : .leading)
            .accessibilityIdentifier(message.outgoing ? "attachment.mine" : "attachment.theirs")
        case .pgpSetting:
            EmptyView()
        }
    }

    /// Writes a decrypted copy for Quick Look, in its own folder, removed when the preview closes.
    private func open(_ info: AttachmentInfo) {
        guard let data = model.attachmentData(info) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Preview-\(UUID().uuidString)", isDirectory: true)
        let safeName = info.name.replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: [.completeFileProtection])
            preview = url
        } catch {
            model.sendError = "Couldn't open \(info.name)."
        }
    }
}

/// The icon tile of an attachment card; a thumbnail for photos.
private struct AttachmentTile: View {
    @Environment(AppModel.self) private var model
    let info: AttachmentInfo
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: info.mime.hasPrefix("image/") ? "photo" : info.mime.hasPrefix("video/") ? "film" : "doc")
                    .font(.system(size: 20))
            }
        }
        .frame(width: 44, height: 44)
        .background(.white.opacity(0.3))
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
        .task(id: info.blob) {
            guard info.mime.hasPrefix("image/"), let data = model.attachmentData(info) else { return }
            thumbnail = await Task.detached { UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 132, height: 132)) }.value
        }
    }
}

private struct BubbleSurface: ViewModifier {
    let mine: Bool
    @Environment(Appearance.self) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if mine {
            if reduceTransparency {
                content.background(appearance.accentFill, in: shape)
            } else {
                // Demo: the accent at 70% over the background, as glass.
                content
                    .background(.black.opacity(0.12), in: shape)
                    .glassEffect(.regular.tint(appearance.accentFill.opacity(0.7)), in: shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.35), lineWidth: 1))
            }
        } else {
            content.glass(22)
        }
    }
}

private extension View {
    func bubble(mine: Bool) -> some View { modifier(BubbleSurface(mine: mine)) }
}

// MARK: Composer and attach sheet

private struct Composer: View {
    @Environment(Appearance.self) private var appearance
    @Binding var draft: String
    var composing: FocusState<Bool>.Binding
    let attach: () -> Void
    let send: () -> Void

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button(action: attach) {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.22), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add attachment")
            .accessibilityIdentifier("chat.attach")

            TextField("Message", text: $draft, axis: .vertical)
                .font(.system(size: 16))
                .lineLimit(1...5)
                .focused(composing)
                .tint(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 11)
                .accessibilityIdentifier("chat.field")

            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(appearance.accentFill, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.6)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("chat.send")
        }
        .padding(6)
        .glass(28)
    }
}

/// Demo: dark glass sheet with the three sources. Google Drive comes in build 2.
struct AttachSheet: View {
    let pgp: Bool
    let pick: (AttachmentSource) -> Void
    let cancel: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static var sources: [AttachmentSource] { AttachmentSource.allCases }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        VStack(spacing: 8) {
            Text(pgp ? "Attach, encrypted on your phone before it leaves"
                     : "Attach. PGP is off for this chat: protected in transit only")
                .font(.system(size: 13)).opacity(0.95)
                .multilineTextAlignment(.center)
                .padding(.bottom, 2)
            ForEach(Self.sources, id: \.self) { source in
                Button(source.label) { pick(source) }
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(.white.opacity(0.16), in: .rect(cornerRadius: 16, style: .continuous))
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("attach.\(source.rawValue)")
            }
            Button("Cancel", action: cancel)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(.white.opacity(0.26), in: .rect(cornerRadius: 16, style: .continuous))
                .buttonStyle(.plain)
                .accessibilityIdentifier("attach.cancel")
        }
        .padding(14)
        .foregroundStyle(.white)
        .background {
            if reduceTransparency {
                shape.fill(Color(white: 0.12))
            } else {
                shape.fill(Color(red: 30 / 255, green: 30 / 255, blue: 40 / 255).opacity(0.55))
                    .glassEffect(.regular, in: shape)
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 25, y: 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attach.sheet")
    }
}

// MARK: New group

struct NewGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var title = ""
    @State private var selected: Set<UUID> = []
    @State private var error: String?

    private var limitReached: Bool { selected.count + 1 >= ConversationLimits.maxGroupMembers }

    var body: some View {
        ScreenScaffold(title: "New group") {
            Card(spacing: 8) {
                Text("Group name").font(.system(size: 13, weight: .semibold)).opacity(0.9)
                TextField("For example, Family", text: $title)
                    .font(.system(size: 16))
                    .fieldStyle()
                    .accessibilityIdentifier("group.name")
            }

            Text("Members").font(.system(size: 13, weight: .semibold)).kerning(0.6).textCase(.uppercase).opacity(0.9)
                .padding(.horizontal, 6)
            VStack(spacing: 0) {
                ForEach(Array(model.contacts.enumerated()), id: \.element.id) { index, contact in
                    let isOn = selected.contains(contact.id)
                    Button {
                        if isOn { selected.remove(contact.id) } else if !limitReached { selected.insert(contact.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(name: contact.displayName, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.displayName).font(.system(size: 16, weight: .semibold))
                                Text(contact.verification == .verified ? "Verified in person" : "Unverified")
                                    .font(.system(size: 13)).opacity(0.88)
                            }
                            Spacer()
                            Image(systemName: isOn ? "checkmark.circle.fill" : "circle").font(.system(size: 22))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityIdentifier("group.member.\(contact.displayName)")
                    if index < model.contacts.count - 1 { Rectangle().fill(.white.opacity(0.18)).frame(height: 1) }
                }
            }
            .glass(28)

            Text("Up to \(ConversationLimits.maxGroupMembers) people, including you. Everyone in the group can read every message in it. Members can't be changed after the group is created.")
                .font(.system(size: 12)).opacity(0.85).padding(.horizontal, 6)

            if let error {
                Text(error).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.warning)
            }

            Button("Create group") {
                do {
                    let members = model.contacts.filter { selected.contains($0.id) }
                    router.show(chat: try model.createGroup(title: title, members: members))
                } catch {
                    self.error = AppModel.describe(error)
                }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selected.isEmpty)
            .accessibilityIdentifier("group.create")
        }
    }
}
