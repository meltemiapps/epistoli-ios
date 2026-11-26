import SwiftUI
import EpistoliCore
import SealedCrypto

struct VerificationBadge: View {
    let state: VerificationState

    var body: some View {
        switch state {
        case .verified:
            Label("Verified", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("badge.verified")
        case .unverified:
            Label("Unverified", systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("badge.unverified")
        }
    }
}

/// Shown when a contact's key changes, until the new key is scanned in person.
struct KeyChangeWarning: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(name)'s key has changed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("This usually means \(name) has a new phone or reinstalled \(Brand.displayName). Keys stay on one device, so a new phone always means a new key.")
            Text("Until you scan \(name)'s code again in person, you can't be sure messages are really from \(name). Next time you meet, open the QR button, tap Scan and scan their code.")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("warning.keychange")
    }
}

struct UnverifiedNote: View {
    let name: String

    var body: some View {
        Label("Pasted codes are Unverified: you can't be sure this code came from \(name.isEmpty ? "them" : name). Scan their code in person to verify.",
              systemImage: "questionmark.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

struct ContactRow: View {
    let contact: Contact

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                if contact.needsKeyChangeWarning {
                    Label("Key changed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Image(systemName: contact.verification == .verified ? "checkmark.seal.fill" : "questionmark.circle")
                .foregroundStyle(contact.verification == .verified ? .green : .orange)
                .accessibilityLabel(contact.verification == .verified ? "Verified" : "Unverified")
        }
        .accessibilityIdentifier("contact.\(contact.displayName)")
    }
}

struct ContactDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let contactID: UUID
    @State private var scanning = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        if let contact = model.contact(id: contactID) {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Text(contact.displayName).font(.title2.bold())
                        VerificationBadge(state: contact.verification)
                        FingerprintView(fingerprint: Fingerprint(hex: contact.currentKey.fingerprint))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                if contact.needsKeyChangeWarning {
                    Section { KeyChangeWarning(name: contact.displayName) }
                } else if contact.verification == .unverified {
                    Section { UnverifiedNote(name: contact.displayName) }
                }

                Section {
                    Button("Scan \(contact.displayName)'s code in person", systemImage: "qrcode.viewfinder") { scanning = true }
                    Button("Rename", systemImage: "pencil") { newName = contact.displayName; renaming = true }
                }

                Section {
                    ForEach(Array(contact.keys.enumerated().reversed()), id: \.offset) { _, key in
                        KeyHistoryRow(key: key)
                    }
                } header: {
                    Text("Key history")
                } footer: {
                    Text("Every key \(contact.displayName) has used, newest first.")
                }

                Section {
                    Button("Delete contact", role: .destructive) {
                        try? model.delete(contact)
                        dismiss()
                    }
                }
            }
            .navigationTitle(contact.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $scanning) {
                KeyExchangeView(tab: .scan)
            }
            .alert("Rename", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") { try? model.rename(contact, to: newName) }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("No contact", systemImage: "person.crop.circle.badge.questionmark")
        }
    }
}

struct KeyHistoryRow: View {
    let key: ContactKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.replacedAt == nil ? "Current key" : "Old key").font(.subheadline.bold())
                Spacer()
                Text(key.source == .scannedInPerson ? "Scanned in person" : "Received as text")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(Fingerprint(hex: key.fingerprint).grouped)
                .font(.caption.monospaced())
            Group {
                if let replaced = key.replacedAt {
                    Text("Used \(key.firstSeen.formatted(date: .abbreviated, time: .shortened)) – \(replaced.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Since \(key.firstSeen.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}
