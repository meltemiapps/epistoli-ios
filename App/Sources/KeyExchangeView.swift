@preconcurrency import AVFoundation
import SwiftUI
import UIKit
import EpistoliCore
import KeyExchange
import SealedCrypto

/// The QR button's sheet: "My code" and "Scan".
struct KeyExchangeView: View {
    enum Tab: Hashable { case myCode, scan }

    @Environment(\.dismiss) private var dismiss
    @State var tab: Tab = .myCode
    /// Called with the contact that was added or updated.
    var onDone: (Contact) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $tab) {
                    Text("My code").tag(Tab.myCode)
                    Text("Scan").tag(Tab.scan)
                }
                .pickerStyle(.segmented)
                .padding()
                .accessibilityIdentifier("keyexchange.mode")

                switch tab {
                case .myCode: MyCodeView()
                case .scan: ScanView { contact in dismiss(); onDone(contact) }
                }
            }
            .navigationTitle(tab == .myCode ? "My code" : "Scan a code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}

// MARK: - My code

struct MyCodeView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        ScrollView {
            if let identity = model.identity, let code = try? model.myCode() {
                VStack(spacing: 20) {
                    QRCodeImage(text: code)
                        .padding(16)
                        .background(.white, in: .rect(cornerRadius: 20))
                        .frame(maxWidth: 340)
                        .accessibilityLabel("QR code for \(identity.displayName)")
                        .accessibilityIdentifier("mycode.qr")

                    VStack(spacing: 6) {
                        Text(identity.displayName).font(.title2.bold())
                        Text("Ask your family member to open \(Brand.displayName), tap the QR button, then Scan.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }

                    FingerprintView(fingerprint: identity.fingerprint)

                    Button {
                        UIPasteboard.general.string = code
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy code as text", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("mycode.copy")

                    Text("Someone who adds you from copied text will see you as Unverified until they scan this code in person.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
        }
    }
}

/// A fingerprint in groups of four, two rows of five groups.
struct FingerprintView: View {
    let fingerprint: Fingerprint
    var title: String = "Fingerprint"

    var body: some View {
        let groups = fingerprint.grouped.split(separator: " ").map(String.init)
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            Text(groups.prefix(5).joined(separator: " "))
            Text(groups.dropFirst(5).joined(separator: " "))
        }
        .font(.body.monospaced())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fingerprint")
    }
}

// MARK: - Scan

struct ScanView: View {
    @Environment(AppModel.self) private var model
    var onDone: (Contact) -> Void

    @State private var pasted = ""
    @State private var offer: OfferedKey?
    @State private var error: String?
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Form {
            Section {
                camera
            } footer: {
                Text("Scanning in person marks the contact as Verified.")
            }

            Section {
                TextField("KEY:…", text: $pasted, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("scan.paste.field")
                HStack {
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { pasted = first; check(first, source: .receivedOtherwise) }
                    }
                    Spacer()
                    Button("Check code") { check(pasted, source: .receivedOtherwise) }
                        .disabled(pasted.isEmpty)
                        .accessibilityIdentifier("scan.paste.check")
                }
                .buttonStyle(.borderless)
                if let error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("scan.error")
                }
            } header: {
                Text("Or paste a code")
            } footer: {
                Text("A code you received as text, by message or email, adds the contact as Unverified.")
            }
        }
        .navigationDestination(item: $offer) { offer in
            ScanResultView(offer: offer, onDone: onDone)
        }
    }

    @ViewBuilder private var camera: some View {
        if !QRScannerView.isCameraAvailable {
            ContentUnavailableView("No camera", systemImage: "camera",
                                   description: Text("This device has no camera. Paste a code below instead."))
        } else {
            switch cameraStatus {
            case .authorized:
                QRScannerView { text in check(text, source: .scannedInPerson) }
                    .frame(height: 300)
                    .clipShape(.rect(cornerRadius: 16))
                    .listRowInsets(EdgeInsets())
            case .notDetermined:
                Button("Allow camera to scan codes") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Camera access is off. Turn it on in Settings to scan codes, or paste a code below.")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
        }
    }

    private func check(_ text: String, source: KeySource) {
        do {
            error = nil
            offer = try ContactCodec.read(text, source: source)
        } catch {
            self.error = Self.message(for: error)
        }
    }

    static func message(for error: ContactCodeError) -> String {
        switch error {
        case .notAContactCode: "That isn't a \(Brand.displayName) code."
        case .unsupportedVersion: "This code was made by a newer version of \(Brand.displayName). Update the app and try again."
        case .damaged: "The code is damaged or incomplete. Copy it again, or scan it in person."
        case .invalidKey: "The key in this code can't be used. Ask for a new code."
        case .fingerprintMismatch: "The code doesn't match its key. Don't use it; scan the code in person instead."
        }
    }
}

extension OfferedKey: @retroactive Identifiable, @retroactive Hashable {
    public var id: String { fingerprint + "|" + address.rawValue + "|" + source.rawValue }
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Result

struct ScanResultView: View {
    @Environment(AppModel.self) private var model
    let offer: OfferedKey
    var onDone: (Contact) -> Void
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        Form {
            switch model.preview(offer) {
            case .failure(.ownCode):
                ContentUnavailableView("This is your own code", systemImage: "person.crop.circle",
                                       description: Text("Scan a family member's code instead."))
            case .failure(.keyBelongsToAnotherContact(let other)):
                ContentUnavailableView("Key already in use", systemImage: "exclamationmark.triangle",
                                       description: Text("This key belongs to your contact \(other). Codes can't be shared between people."))
            case .success(let (contact, outcome)):
                result(contact: contact, outcome: outcome)
            }
        }
        .navigationTitle("Check code")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if name.isEmpty { name = offer.displayName } }
    }

    @ViewBuilder
    private func result(contact: Contact, outcome: KeyOfferOutcome) -> some View {
        let existing = model.contacts.first { $0.address == offer.address }
        Section {
            VStack(spacing: 12) {
                Text(existing?.displayName ?? offer.displayName).font(.title2.bold())
                VerificationBadge(state: contact.verification)
                FingerprintView(fingerprint: Fingerprint(hex: offer.fingerprint))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }

        switch outcome {
        case .added:
            Section("Name") {
                TextField("Name", text: $name).accessibilityIdentifier("result.name")
            }
            if offer.source == .receivedOtherwise {
                Section { UnverifiedNote(name: name) }
            }
        case .keyChanged(warning: true):
            Section { KeyChangeWarning(name: existing?.displayName ?? offer.displayName) }
        case .keyChanged(warning: false):
            Section {
                Label("New key scanned in person. The old key is kept in the key history.", systemImage: "checkmark.shield")
            }
        case .verified:
            Section { Label("You scanned this code in person. The contact is now Verified.", systemImage: "checkmark.seal") }
        case .unchanged:
            Section { Label("You already have this key.", systemImage: "checkmark") }
        }

        Section {
            Button(buttonTitle(outcome)) { accept(outcome) }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("result.accept")
            if let error { Text(error).foregroundStyle(.red) }
        }
    }

    private func buttonTitle(_ outcome: KeyOfferOutcome) -> String {
        switch outcome {
        case .added: "Add contact"
        case .keyChanged: "Use new key"
        case .verified: "Mark as Verified"
        case .unchanged: "Done"
        }
    }

    private func accept(_ outcome: KeyOfferOutcome) {
        do {
            let contact = try model.accept(offer, name: name)
            onDone(contact)
        } catch {
            self.error = "Couldn't save: \(error)"
        }
    }
}
