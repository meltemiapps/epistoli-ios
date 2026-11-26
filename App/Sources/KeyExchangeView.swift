@preconcurrency import AVFoundation
import SwiftUI
import UIKit
import EpistoliCore
import KeyExchange
import SealedCrypto

/// The QR button's page (demo: "Add contact"): "My code" and "Scan".
struct KeyExchangeView: View {
    enum Tab: Hashable { case myCode, scan }

    @State var tab: Tab

    init(tab: Tab = .myCode) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        ScreenScaffold(title: "Add contact") {
            SegmentedGlass(selection: $tab, options: [(.myCode, "My code"), (.scan, "Scan")])
                .accessibilityIdentifier("keyexchange.mode")
            switch tab {
            case .myCode: MyCodeView()
            case .scan: ScanView()
            }
        }
    }
}

/// The demo's two-option switch: a glass track with a white 32% thumb.
struct SegmentedGlass<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    Text(label).font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(selection == value ? Color.white.opacity(0.32) : .clear, in: .rect(cornerRadius: 18, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(4)
        .glass(22, tint: 0.14)
    }
}

// MARK: - My code

struct MyCodeView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        if let identity = model.identity, let code = try? model.myCode() {
            Card(spacing: 14, padding: 20, radius: 28, alignment: .center) {
                QRCodeImage(text: code, label: "QR code for \(identity.displayName)")
                    .padding(12)
                    .background(.white, in: .rect(cornerRadius: 20, style: .continuous))
                    .frame(maxWidth: 300)
                    .accessibilityIdentifier("mycode.qr")
                Text(identity.displayName).font(.system(size: 17, weight: .semibold))
                FingerprintView(fingerprint: identity.fingerprint)
                Text("Holds your public key, its fingerprint and how to reach you. Never your private key. Let the other person scan it, then scan theirs.")
                    .font(.system(size: 13)).lineSpacing(2).multilineTextAlignment(.center).opacity(0.92)
            }

            Button {
                UIPasteboard.general.string = code
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy code as text", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(SoftButtonStyle())
            .accessibilityIdentifier("mycode.copy")

            Text("Someone who adds you from copied text will see you as Unverified until they scan this code in person.")
                .font(.system(size: 12)).multilineTextAlignment(.center).opacity(0.85)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A fingerprint in groups of four, two rows of five groups. Always the full fingerprint: a
/// shortened one would be easier to forge.
struct FingerprintView: View {
    let fingerprint: Fingerprint
    var title: String?

    var body: some View {
        let groups = fingerprint.grouped.split(separator: " ").map(String.init)
        VStack(spacing: 3) {
            if let title {
                Text(title).font(.system(size: 11, weight: .semibold)).kerning(0.6).textCase(.uppercase).opacity(0.85)
            }
            Text(groups.prefix(5).joined(separator: " "))
            Text(groups.dropFirst(5).joined(separator: " "))
        }
        .font(.system(size: 13, design: .monospaced))
        .kerning(0.5)
        .opacity(0.95)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fingerprint \(fingerprint.grouped)")
        .accessibilityIdentifier("fingerprint")
    }
}

// MARK: - Scan

struct ScanView: View {
    @Environment(Router.self) private var router
    @State private var pasted = ""
    @State private var error: String?
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Card(spacing: 14, padding: 20, radius: 28, alignment: .center) {
            camera
            Text("Point at the other person's \(Brand.displayName) code")
                .font(.system(size: 14)).multilineTextAlignment(.center).opacity(0.95)
            Text("Scanning in person marks the contact as Verified.")
                .font(.system(size: 13)).multilineTextAlignment(.center).opacity(0.85)
        }

        Card {
            Text("Or paste a code").font(.system(size: 16, weight: .semibold))
            TextField("", text: $pasted, prompt: Text("KEY:…").foregroundStyle(.white.opacity(0.7)), axis: .vertical)
                .lineLimit(3...6)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .fieldStyle()
                .accessibilityLabel("Code")
                .accessibilityIdentifier("scan.paste.field")
            HStack(spacing: 8) {
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { pasted = first; check(first, source: .receivedOtherwise) }
                }
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .tint(.white.opacity(0.24))
                .labelStyle(.titleAndIcon)
                Button("Check code") { check(pasted, source: .receivedOtherwise) }
                    .buttonStyle(AccentButtonStyle(height: 44))
                    .disabled(pasted.isEmpty)
                    .accessibilityIdentifier("scan.paste.check")
            }
            if let error {
                Text(error).font(.system(size: 13, weight: .semibold))
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 120 / 255, green: 20 / 255, blue: 20 / 255).opacity(0.45), in: .rect(cornerRadius: 14))
                    .accessibilityIdentifier("scan.error")
            }
            Text("A code you received as text, by message or email, adds the contact as Unverified.")
                .font(.system(size: 12)).opacity(0.88)
        }
        .toolbar {
            // The keyboard covers the card's button once a long code is pasted.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Check code") { check(pasted, source: .receivedOtherwise) }
                    .disabled(pasted.isEmpty)
                    .accessibilityIdentifier("scan.paste.check.keyboard")
            }
        }
    }

    /// The demo's viewfinder: 250 pt dark tile with a white square.
    @ViewBuilder private var camera: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.45))
            if QRScannerView.isCameraAvailable && cameraStatus == .authorized {
                QRScannerView { text in check(text, source: .scannedInPerson) }
                    .clipShape(.rect(cornerRadius: 24, style: .continuous))
            }
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                .frame(width: 170, height: 170)
            VStack {
                Spacer()
                cameraMessage.padding(.bottom, 14).padding(.horizontal, 12)
            }
        }
        .frame(width: 250, height: 250)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var cameraMessage: some View {
        if !QRScannerView.isCameraAvailable {
            Text("No camera on this device").font(.system(size: 13)).opacity(0.9)
        } else {
            switch cameraStatus {
            case .authorized:
                Text("Camera").font(.system(size: 13)).opacity(0.9)
            case .notDetermined:
                Button("Allow camera") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    }
                }
                .buttonStyle(AccentButtonStyle(height: 40))
                .frame(width: 160)
            default:
                Button("Turn on camera in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(SoftButtonStyle(height: 40))
            }
        }
    }

    private func check(_ text: String, source: KeySource) {
        do {
            error = nil
            router.open(.checkCode(try ContactCodec.read(text, source: source)))
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
    @Environment(Router.self) private var router
    let offer: OfferedKey
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        ScreenScaffold(title: "Check code") {
            switch model.preview(offer) {
            case .failure(.ownCode):
                refusal("This is your own code", systemImage: "person.crop.circle",
                        detail: "Scan a family member's code instead.")
            case .failure(.keyBelongsToAnotherContact(let other)):
                refusal("Key already in use", systemImage: "exclamationmark.triangle",
                        detail: "This key belongs to your contact \(other). Codes can't be shared between people.")
            case .success(let (contact, outcome)):
                result(contact: contact, outcome: outcome)
            }
        }
        .onAppear { if name.isEmpty { name = offer.displayName } }
    }

    private func refusal(_ title: String, systemImage: String, detail: String) -> some View {
        Card(spacing: 10, padding: 24, radius: 28, alignment: .center) {
            Image(systemName: systemImage).font(.system(size: 44)).opacity(0.9).padding(.bottom, 4)
            Text(title).font(.system(size: 20, weight: .bold))
            Text(detail).font(.system(size: 15)).multilineTextAlignment(.center).opacity(0.9)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("result.refused")
    }

    @ViewBuilder
    private func result(contact: Contact, outcome: KeyOfferOutcome) -> some View {
        let existing = model.contacts.first { $0.address == offer.address }
        let shownName = existing?.displayName ?? offer.displayName
        Card(spacing: 12, padding: 20, radius: 28, alignment: .center) {
            Text(shownName).font(.system(size: 20, weight: .bold))
            VerificationBadge(state: contact.verification)
            FingerprintView(fingerprint: Fingerprint(hex: offer.fingerprint), title: "Fingerprint")
        }

        switch outcome {
        case .added:
            Card {
                Text("Name").font(.system(size: 13, weight: .semibold))
                TextField("", text: $name, prompt: Text("Name").foregroundStyle(.white.opacity(0.7)))
                    .font(.system(size: 16))
                    .fieldStyle()
                    .accessibilityIdentifier("result.name")
            }
            if offer.source == .receivedOtherwise {
                UnverifiedNote(name: name)
            } else {
                Note(systemImage: "checkmark.seal.fill",
                     text: "Verified in person. If \(name.isEmpty ? "their" : name + "'s") key ever changes, you'll be warned before sending.")
            }
        case .keyChanged(warning: true):
            KeyChangeWarning(name: shownName)
        case .keyChanged(warning: false):
            Note(systemImage: "checkmark.shield", text: "New key scanned in person. The old key is kept in the key history.")
        case .verified:
            Note(systemImage: "checkmark.seal.fill", text: "You scanned this code in person. The contact is now Verified.")
        case .unchanged:
            Note(systemImage: "checkmark", text: "You already have this key.")
        }

        Button(buttonTitle(outcome)) { accept(outcome) }
            .buttonStyle(AccentButtonStyle())
            .accessibilityIdentifier("result.accept")
        if let error { Text(error).font(.system(size: 14, weight: .semibold)) }
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
            router.show(contact: contact.id)
        } catch {
            self.error = "Couldn't save: \(error)"
        }
    }
}
