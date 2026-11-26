import SwiftUI
import EpistoliCore
import SealedCrypto

/// Verified / Unverified chip, in the demo's badge colours.
struct VerificationBadge: View {
    let state: VerificationState

    var body: some View {
        switch state {
        case .verified:
            chip("Verified", systemImage: "checkmark.seal.fill", fill: Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255).opacity(0.55))
                .accessibilityIdentifier("badge.verified")
        case .unverified:
            chip("Unverified", systemImage: "questionmark.circle", fill: Color.warning.opacity(0.35))
                .accessibilityIdentifier("badge.unverified")
        }
    }

    private func chip(_ title: String, systemImage: String, fill: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(fill, in: .capsule)
    }
}

/// The persistent banner for a contact whose key changed and hasn't been scanned in person since.
/// It can't be dismissed: only a camera scan of their code removes it (`ContactRules`). It sits
/// under the header of every screen about that contact, and every chat with them in section 4.
struct KeyChangeBanner: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.warning)
            Text("\(name)'s key changed and hasn't been checked in person")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.32), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.warning.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("banner.keychange")
    }
}

/// The full explanation, shown when a key change is offered and on the contact's page.
struct KeyChangeWarning: View {
    let name: String

    var body: some View {
        Card(spacing: 8) {
            Label("\(name)'s key has changed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .labelStyle(WarningLabelStyle())
            Text("This usually means \(name) has a new phone or reinstalled \(Brand.displayName). Keys stay on one device, so a new phone always means a new key.")
                .font(.system(size: 14)).lineSpacing(2)
            Text("Until you scan \(name)'s code again in person, you can't be sure messages are really from \(name). Next time you meet, open the QR button, tap Scan and scan their code.")
                .font(.system(size: 14)).lineSpacing(2).opacity(0.85)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("warning.keychange")
    }
}

private struct WarningLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Color.warning)
            configuration.title
        }
    }
}

/// A small explanatory card: icon and text.
struct Note: View {
    let systemImage: String
    let text: String

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 18)).opacity(0.9)
                Text(text).font(.system(size: 14)).lineSpacing(2).opacity(0.95)
            }
        }
    }
}

struct UnverifiedNote: View {
    let name: String

    var body: some View {
        Note(systemImage: "questionmark.circle",
             text: "Pasted codes are Unverified: you can't be sure this code came from \(name.isEmpty ? "them" : name). Scan their code in person to verify.")
    }
}

/// A row in the chats list (demo layout: avatar, name, status line).
struct ContactRow: View {
    let contact: Contact

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: contact.displayName)
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.displayName).font(.system(size: 16, weight: .semibold))
                Group {
                    if contact.needsKeyChangeWarning {
                        Label("Key changed · not checked in person", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(WarningLabelStyle())
                    } else {
                        Text(contact.verification == .verified ? "Verified in person" : "Unverified · not scanned in person")
                    }
                }
                .font(.system(size: 14)).opacity(0.88).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).opacity(0.6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("contact.\(contact.displayName)")
    }
}

struct ContactDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let contactID: UUID
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false

    var body: some View {
        if let contact = model.contact(id: contactID) {
            ScreenScaffold(title: contact.displayName) {
                if contact.needsKeyChangeWarning {
                    KeyChangeBanner(name: contact.displayName)
                }

                Card(spacing: 12, padding: 20, radius: 28, alignment: .center) {
                    Avatar(name: contact.displayName, size: 64)
                    Text(contact.displayName).font(.system(size: 20, weight: .bold))
                    VerificationBadge(state: contact.verification)
                    FingerprintView(fingerprint: Fingerprint(hex: contact.currentKey.fingerprint), title: "Fingerprint")
                }

                if contact.needsKeyChangeWarning {
                    KeyChangeWarning(name: contact.displayName)
                } else if contact.verification == .unverified {
                    UnverifiedNote(name: contact.displayName)
                }

                VStack(spacing: 8) {
                    Button { router.open(.addContact(.scan)) } label: {
                        Label("Scan \(contact.displayName)'s code in person", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(AccentButtonStyle(height: 48))
                    Button { newName = contact.displayName; renaming = true } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .buttonStyle(SoftButtonStyle())
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Key history").font(.system(size: 13, weight: .semibold)).kerning(0.6).textCase(.uppercase).opacity(0.9)
                        .padding(.horizontal, 6)
                    VStack(spacing: 0) {
                        let keys = Array(contact.keys.reversed())
                        ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                            KeyHistoryRow(key: key)
                            if index < keys.count - 1 { Rectangle().fill(.white.opacity(0.18)).frame(height: 1) }
                        }
                    }
                    .glass(22)
                    Text("Every key \(contact.displayName) has used, newest first.")
                        .font(.system(size: 12)).opacity(0.85).padding(.horizontal, 6)
                }

                Button("Delete contact…") { confirmingDelete = true }
                    .buttonStyle(DestructiveButtonStyle())
            }
            .alert("Rename", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") { try? model.rename(contact, to: newName) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete \(contact.displayName)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete contact", role: .destructive) {
                    try? model.delete(contact)
                    dismiss()
                }
            } message: {
                Text("Their key and key history are removed from this phone. To add them again, scan their code.")
            }
        } else {
            ContentUnavailableView("No contact", systemImage: "person.crop.circle.badge.questionmark").appScreen()
        }
    }
}

struct KeyHistoryRow: View {
    let key: ContactKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.replacedAt == nil ? "Current key" : "Old key").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(key.source == .scannedInPerson ? "Scanned in person" : "Received as text")
                    .font(.system(size: 12)).opacity(0.85)
            }
            Text(Fingerprint(hex: key.fingerprint).grouped)
                .font(.system(size: 12, design: .monospaced))
            Group {
                if let replaced = key.replacedAt {
                    Text("Used \(key.firstSeen.formatted(date: .abbreviated, time: .shortened)) – \(replaced.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Since \(key.firstSeen.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.system(size: 12)).opacity(0.85)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
