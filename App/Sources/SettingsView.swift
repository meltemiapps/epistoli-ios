import PhotosUI
import SwiftUI

/// Settings: Appearance, your key, About.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var debugMessage: String?

    var body: some View {
        ScreenScaffold(title: "Settings") {
            VStack(spacing: 0) {
                SettingsRow(title: "Appearance", systemImage: "paintpalette") { router.open(.appearance) }
                    .accessibilityIdentifier("settings.appearance")
            }
            .glass(22)

            if let identity = model.identity {
                Card(spacing: 10) {
                    Text("Your key").font(.system(size: 16, weight: .semibold))
                    ValueRow(title: "Name", value: identity.displayName)
                    ValueRow(title: "Protected by", value: model.keyProtection)
                        .accessibilityIdentifier("settings.keyprotection")
                    FingerprintView(fingerprint: identity.fingerprint, title: "Your fingerprint")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    Text("Your key exists only on this device. There is no backup yet.")
                        .font(.system(size: 12)).opacity(0.88)
                }
            }

            #if DEBUG
            Card(spacing: 10) {
                Text("Developer (Debug builds only)").font(.system(size: 16, weight: .semibold))
                Button("Simulate new phone") {
                    do {
                        try model.simulateNewPhone()
                        debugMessage = "New key created. Your name and address are unchanged."
                    } catch {
                        debugMessage = "Failed: \(error)"
                    }
                }
                .buttonStyle(SoftButtonStyle(height: 44))
                .accessibilityIdentifier("settings.debug.newphone")
                if let debugMessage { Text(debugMessage).font(.system(size: 13, weight: .semibold)) }
                Text("Replaces your key but keeps your name and address, as a new phone would. Use it to test the key-change warning on another device.")
                    .font(.system(size: 12)).opacity(0.88)
            }
            #endif

            VStack(spacing: 0) {
                HStack {
                    Text("Version").font(.system(size: 16))
                    Spacer()
                    Text(Self.versionString).font(.system(size: 15)).opacity(0.85)
                }
                .padding(.horizontal, 16).frame(minHeight: 50)
                Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                SettingsRow(title: "Acknowledgements", systemImage: "doc.text") { router.open(.acknowledgements) }
                    .accessibilityIdentifier("settings.acknowledgements")
            }
            .glass(22)
        }
    }

    static var versionString: String {
        let version = Brand.string(for: "CFBundleShortVersionString")
        let build = Brand.string(for: "CFBundleVersion")
        return "\(version) (\(build))"
    }
}

struct SettingsRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 17)).frame(width: 24)
                Text(title).font(.system(size: 16))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).opacity(0.6)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 15)).opacity(0.9)
            Spacer()
            Text(value).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Appearance (demo: the Appearance screen).
struct AppearanceView: View {
    @Environment(Appearance.self) private var appearance
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var photoError: String?

    var body: some View {
        ScreenScaffold(title: "Appearance") {
            Card {
                Text("Background").font(.system(size: 16, weight: .semibold))
                Text("Pick a photo, for example the same one as your wallpaper. The glass and accent colour follow it.")
                    .font(.system(size: 13)).lineSpacing(2).opacity(0.9)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(BackgroundPreset.allCases) { preset in
                        Swatch(preset: preset, selected: appearance.choice == .preset(preset)) {
                            appearance.select(preset)
                        }
                    }
                }
                // PhotosPicker runs outside the app: no photo library permission is needed, and the
                // app only ever sees the one photo picked.
                let photoLabel = appearance.choice == .photo ? "Choose another photo…" : "Choose from Photos…"
                PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                    Text(photoLabel)
                }
                .buttonStyle(SoftButtonStyle())
                .accessibilityIdentifier("appearance.photos")
                if let photoError { Text(photoError).font(.system(size: 13, weight: .semibold)) }
            }

            Card(spacing: 10) {
                Text("Privacy").font(.system(size: 16, weight: .semibold))
                Text("PGP for new chats: on. You can switch it off per chat. Every message also travels over TLS. No accounts, analytics, ads or tracking. Nothing leaves your phone except to the people you message, through your own iCloud or Google Drive.")
                    .font(.system(size: 14)).lineSpacing(3).opacity(0.95)
            }
        }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        try appearance.usePhoto(data)
                        photoError = nil
                    }
                } catch {
                    photoError = "Couldn't use this photo: \(error.localizedDescription)"
                }
                pickedPhoto = nil
            }
        }
    }
}

/// A background swatch: the gradient, label at the bottom, white ring when selected.
struct Swatch: View {
    let preset: BackgroundPreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            Canvas { context, size in preset.gradient.draw(in: &context, size: size) }
                .frame(height: 92)
                .clipShape(shape)
                .overlay(alignment: .bottom) {
                    Text(preset.label).font(.system(size: 11, weight: .semibold)).padding(.bottom, 6)
                }
                .overlay(shape.strokeBorder(.white.opacity(selected ? 1 : 0.4), lineWidth: selected ? 3 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("appearance.\(preset.rawValue)")
    }
}
