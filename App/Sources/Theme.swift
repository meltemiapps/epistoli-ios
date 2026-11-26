import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import SwiftUI
import UIKit

// The look from docs/design (DESIGN_SPEC.md, demo-iphone.html): a full-screen background with an
// 18% black dim layer, white glass surfaces over it, white text, and an accent that follows the
// background.

/// One of the four built-in backgrounds. Values copied from the demo CSS.
enum BackgroundPreset: String, CaseIterable, Identifiable, Sendable {
    case aegean, sunset, olive, night

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aegean: "Aegean"
        case .sunset: "Sunset"
        case .olive: "Olive"
        case .night: "Night"
        }
    }

    /// The demo's accent for this background.
    var accentHex: UInt32 {
        switch self {
        case .aegean: 0x1E88E5
        case .sunset: 0xE8590C
        case .olive: 0x2E7D32
        case .night: 0x5E5CE6
        }
    }

    var accent: UIColor { UIColor(hex: accentHex) }

    var gradient: LayeredGradient {
        switch self {
        case .aegean:
            LayeredGradient(radials: [.init(0x5fc3e8, size: (0.9, 0.6), at: (0.20, 0.15)),
                                      .init(0x0d3b66, size: (0.8, 0.6), at: (0.85, 0.85))],
                            angle: 165, from: 0x2a86c4, to: 0x0b2d4f)
        case .sunset:
            LayeredGradient(radials: [.init(0xffb36b, size: (0.8, 0.5), at: (0.70, 0.20)),
                                      .init(0x5b2a86, size: (0.9, 0.6), at: (0.10, 0.90))],
                            angle: 170, from: 0xd9603b, to: 0x3b1d5c)
        case .olive:
            LayeredGradient(radials: [.init(0xa5c47a, size: (0.8, 0.5), at: (0.25, 0.25)),
                                      .init(0x243b1c, size: (0.9, 0.6), at: (0.90, 0.85))],
                            angle: 170, from: 0x5e7f3a, to: 0x1e2f17)
        case .night:
            LayeredGradient(radials: [.init(0x4b4fa8, size: (0.7, 0.45), at: (0.75, 0.20)),
                                      .init(0x10162e, size: (0.9, 0.6), at: (0.15, 0.90))],
                            angle: 170, from: 0x26285e, to: 0x0a0d1f)
        }
    }
}

/// CSS `radial-gradient(W% H% at X% Y%, color 0%, transparent 70%), …, linear-gradient(Adeg, from, to)`.
struct LayeredGradient: Sendable {
    struct Radial: Sendable {
        var color: UInt32
        /// Ellipse radii as fractions of the width and height.
        var size: (CGFloat, CGFloat)
        /// Centre as fractions of the width and height.
        var center: (CGFloat, CGFloat)

        init(_ color: UInt32, size: (CGFloat, CGFloat), at center: (CGFloat, CGFloat)) {
            self.color = color
            self.size = size
            self.center = center
        }
    }

    /// Listed top layer first, as in CSS.
    var radials: [Radial]
    /// CSS angle: 0 points up, 90 right, 180 down.
    var angle: Double
    var from: UInt32
    var to: UInt32

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let rect = CGRect(origin: .zero, size: size)

        // Linear layer. CSS makes the gradient line just long enough to reach the corners.
        let a = angle * .pi / 180
        let dir = CGVector(dx: sin(a), dy: -cos(a))
        let length = abs(w * sin(a)) + abs(h * cos(a))
        let mid = CGPoint(x: w / 2, y: h / 2)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color(hex: from), Color(hex: to)]),
            startPoint: CGPoint(x: mid.x - dir.dx * length / 2, y: mid.y - dir.dy * length / 2),
            endPoint: CGPoint(x: mid.x + dir.dx * length / 2, y: mid.y + dir.dy * length / 2)))

        // Radial layers, bottom first. An ellipse is a circle squashed vertically.
        for r in radials.reversed() {
            var ctx = context
            let cx = r.center.0 * w, cy = r.center.1 * h
            let rx = r.size.0 * w, squash = (r.size.1 * h) / rx
            ctx.translateBy(x: cx, y: cy)
            ctx.scaleBy(x: 1, y: squash)
            let cover = CGRect(x: -cx - 1, y: -cy / squash - 1, width: w + 2, height: h / squash + 2)
            let color = Color(hex: r.color)
            ctx.fill(Path(cover), with: .radialGradient(
                Gradient(stops: [.init(color: color, location: 0), .init(color: color.opacity(0), location: 1)]),
                center: .zero, startRadius: 0, endRadius: rx * 0.7))
        }
    }
}

/// The chosen background, kept in UserDefaults (not secret). A chosen photo is copied into the
/// app's own container, so it stays even if it is deleted from Photos.
@MainActor @Observable
final class Appearance {
    enum Choice: Equatable {
        case preset(BackgroundPreset)
        case photo
    }

    static let defaultsKey = "appearance.background"

    private(set) var choice: Choice
    private(set) var photo: UIImage?
    private(set) var photoAccent: UIColor = BackgroundPreset.aegean.accent
    private let defaults: UserDefaults
    private let photoURL: URL?

    init(defaults: UserDefaults = .standard, photoURL: URL? = Appearance.defaultPhotoURL) {
        self.defaults = defaults
        self.photoURL = photoURL
        let saved = defaults.string(forKey: Self.defaultsKey) ?? BackgroundPreset.aegean.rawValue
        if saved == "photo", let url = photoURL, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            choice = .photo
            photo = image
            photoAccent = Self.accent(from: image) ?? BackgroundPreset.aegean.accent
        } else {
            choice = .preset(BackgroundPreset(rawValue: saved) ?? .aegean)
        }
    }

    /// The accent exactly as the demo specifies it.
    var accentUIColor: UIColor {
        switch choice {
        case .preset(let preset): preset.accent
        case .photo: photoAccent
        }
    }

    var accent: Color { Color(uiColor: accentUIColor) }

    /// The accent for everything white sits on (buttons, the selected segment, glass tint): the
    /// same hue, darkened only as much as needed for at least 4.5:1 contrast with white.
    var accentFill: Color { Color(uiColor: Contrast.darkened(accentUIColor)) }

    func select(_ preset: BackgroundPreset) {
        choice = .preset(preset)
        defaults.set(preset.rawValue, forKey: Self.defaultsKey)
    }

    /// Uses `data` (an image picked in Photos) as the background.
    func usePhoto(_ data: Data) throws {
        guard let image = UIImage(data: data), let url = photoURL,
              let jpeg = Self.downscaled(image).jpegData(compressionQuality: 0.85) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: [.atomic, .completeFileProtection])
        photo = UIImage(data: jpeg)
        photoAccent = Self.accent(from: image) ?? BackgroundPreset.aegean.accent
        choice = .photo
        defaults.set("photo", forKey: Self.defaultsKey)
    }

    static var defaultPhotoURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("background.jpg")
    }

    /// Backgrounds never need more than a screen's worth of pixels.
    private static func downscaled(_ image: UIImage, maxSide: CGFloat = 2400) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let scale = maxSide / side
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// The photo's average colour, made saturated and dark enough to carry white text.
    static func accent(from image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: max(s, 0.65), brightness: min(max(b, 0.55), 0.8), alpha: 1)
    }
}

/// Full-screen background: the gradient or photo, then the dim layer.
struct AppBackground: View {
    @Environment(Appearance.self) private var appearance
    static let topScrim = 0.40

    var body: some View {
        ZStack {
            switch appearance.choice {
            case .preset(let preset):
                Canvas { context, size in preset.gradient.draw(in: &context, size: size) }
            case .photo:
                if let photo = appearance.photo {
                    Color.clear.overlay { Image(uiImage: photo).resizable().scaledToFill() }.clipped()
                }
            }
            Color.black.opacity(0.18)
            // The demo's backgrounds are brightest near the top, where titles and the first cards
            // sit. This keeps white text there at 4.5:1 or more (scripts/contrast_check.swift).
            LinearGradient(colors: [.black.opacity(Self.topScrim), .black.opacity(0)],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Glass

/// Native Liquid Glass (regular, not clear) with the demo's 1 pt white border, tinted 30% with the
/// background's accent (its text-safe shade). That keeps the vivid colour of the demo's
/// saturate(180%) glass with white text at 4.5:1 or more (scripts/contrast_check.swift).
/// With Reduce Transparency on: a solid dark surface, same shape.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Double
    @Environment(Appearance.self) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Cards, lists, the segmented track.
    static let accentTint = 0.30
    /// Glass buttons inside glass cards: nested glass renders lighter, so they need more tint.
    static let nestedTint = 0.45

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tint = appearance.accentFill.opacity(self.tint)
        Group {
            if reduceTransparency {
                content.background(Color(white: 0.16), in: shape)
            } else {
                // A thin dark layer inside the glass keeps white text at 4.5:1 where the glass sits
                // over the brightest part of a background.
                content
                    .background(.black.opacity(self.tint > Self.accentTint ? 0.15 : 0.12), in: shape)
                    .glassEffect(.regular.tint(tint), in: shape)
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(0.35), lineWidth: 1))
    }
}

extension View {
    func glass(_ cornerRadius: CGFloat = 26, tint: Double = GlassSurface.accentTint) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tint: tint))
    }

    /// A screen of the app: the background behind it and white text on it.
    func appScreen() -> some View {
        self
            .foregroundStyle(.white)
            .background { AppBackground() }
            .toolbarVisibility(.hidden, for: .navigationBar)
    }
}

/// A demo-style card: glass, radius 26, 16 pt padding, content leading.
struct Card<Content: View>: View {
    var spacing: CGFloat = 12
    var padding: CGFloat = 16
    var radius: CGFloat = 26
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: alignment, spacing: spacing) { content }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .padding(padding)
            .glass(radius)
    }
}

/// Screen header: round glass back button and a 28 pt bold title, as in the demo.
struct ScreenHeader: View {
    @Environment(Appearance.self) private var appearance
    let title: String
    var subtitle: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(appearance.accentFill, in: .circle)
                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
            }
            .accessibilityLabel("Back")
            .accessibilityIdentifier("header.back")
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 28, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                if let subtitle { Text(subtitle).font(.system(size: 13)).opacity(0.9) }
            }
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
    }
}

/// A demo page: header, then content in a scroll view with the demo's 16 pt margins.
struct ScreenScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                ScreenHeader(title: title, subtitle: subtitle)
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .appScreen()
    }
}

// MARK: - Buttons and fields

/// Filled accent button (demo: "Create channel and keys", "Simulate a scan").
struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = 50
    @Environment(Appearance.self) private var appearance
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(appearance.accentFill, in: .rect(cornerRadius: 18, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

/// Secondary button (demo: "Start chat", white 24%). Accent glass instead of white, which keeps
/// white text at 4.5:1 on every background.
struct SoftButtonStyle: ButtonStyle {
    var height: CGFloat = 46
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, 12)
            .glass(16, tint: GlassSurface.nestedTint)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

/// Red-tinted button for destructive actions (demo: "Regenerate keypair…").
struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Color(red: 179 / 255, green: 38 / 255, blue: 30 / 255).opacity(configuration.isPressed ? 0.5 : 0.35), in: shape)
            .overlay(shape.strokeBorder(Color(red: 1, green: 140 / 255, blue: 130 / 255).opacity(0.7), lineWidth: 1))
    }
}

extension View {
    /// Demo text field: 44 pt, radius 14, dark fill, white border.
    func fieldStyle(minHeight: CGFloat = 44) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: minHeight)
            .background(.black.opacity(0.2), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .tint(.white)
    }
}

/// Avatar: the name's first letter on the accent (the demo's white 28% left white letters at
/// under 3:1 on the brighter backgrounds).
struct Avatar: View {
    @Environment(Appearance.self) private var appearance
    let name: String
    var size: CGFloat = 46

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.39, weight: .semibold))
            .frame(width: size, height: size)
            .background(appearance.accentFill, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Accent-tinted glass button (demo: "Choose from Photos…").
struct GlassButtonStyle: ButtonStyle {
    var height: CGFloat = 46

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, 12)
            .glass(16, tint: GlassSurface.nestedTint)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// WCAG 2 contrast: relative luminance and ratio, and the darkest-needed shade of a colour.
enum Contrast {
    static func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func ratio(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `color` scaled towards black in small steps until white on it reaches `target`.
    /// Colours that already pass are returned unchanged.
    static func darkened(_ color: UIColor, toContrast target: CGFloat = 4.6) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        var factor: CGFloat = 1
        var result = color
        while ratio(.white, result) < target, factor > 0.3 {
            factor -= 0.01
            result = UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
        }
        return result
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }

    /// The demo's warning yellow (rgba(255,204,0)).
    static let warning = Color(red: 1, green: 204 / 255, blue: 0)

    /// Solid badge fills, with `badgeText` on them (contrast tested in ThemeTests).
    static let badgeAmber = Color(uiColor: .badgeAmber)
    static let badgeGreen = Color(uiColor: .badgeGreen)
    static let badgeText = Color(uiColor: .badgeText)
}

extension UIColor {
    static let badgeAmber = UIColor(hex: 0xFFB020)
    static let badgeGreen = UIColor(hex: 0x34C759)
    static let badgeText = UIColor(hex: 0x1C1C1E)
}
