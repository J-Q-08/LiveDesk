import CoreText
import SwiftUI

enum GalleryStyle {
    static let background = Color(rgb: 0x100925)
    static let violet = Color(rgb: 0x5D34D0)
    static let magenta = Color(rgb: 0xFF006E)
    static let accent = Color(rgb: 0x00F0FF)
    static let sidebar = Color(rgb: 0x160D32)
    static let surface = Color(rgb: 0x251546)
    static let border = Color.white.opacity(0.17)

    static let selection = LinearGradient(colors: [violet, magenta.opacity(0.85)],
                                          startPoint: .leading, endPoint: .trailing)
    static let glass = LinearGradient(colors: [surface.opacity(0.82), background.opacity(0.62)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)

    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("InterVariable", size: size, relativeTo: style).weight(.heavy)
    }

    static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "InterVariable", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

struct AuroraMesh: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let radius = max(width, geometry.size.height)
            ZStack {
                GalleryStyle.background
                RadialGradient(colors: [GalleryStyle.violet, .clear], center: .init(x: 0.23, y: 0.37),
                               startRadius: width * 0.04, endRadius: radius * 0.62)
                RadialGradient(colors: [GalleryStyle.magenta.opacity(0.74), .clear],
                               center: .init(x: 0.95, y: 0.45), startRadius: 0, endRadius: radius * 0.52)
                RadialGradient(colors: [GalleryStyle.accent.opacity(0.57), .clear],
                               center: .init(x: 0.65, y: 1.1), startRadius: 0, endRadius: radius * 0.58)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct AuroraActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(GalleryStyle.background)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(GalleryStyle.accent, in: Capsule())
            .contentShape(Capsule())
            .shadow(color: GalleryStyle.accent.opacity(0.5), radius: 14)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255,
                  blue: Double(rgb & 255) / 255)
    }
}
