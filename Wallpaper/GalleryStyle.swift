import AppKit
import CoreText
import SwiftUI

enum GalleryStyle {
    static let background = Color(red: 0.07, green: 0.09, blue: 0.15)
    static let sidebar = Color(red: 0.15, green: 0.18, blue: 0.26)
    static let surface = Color.white.opacity(0.09)
    static let accent = Color(red: 0.70, green: 0.83, blue: 1)
    static let blue = Color(red: 0.22, green: 0.43, blue: 0.90)
    static let border = Color.white.opacity(0.14)

    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("InterVariable", size: size, relativeTo: style).weight(.semibold)
    }

    static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "InterVariable", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

struct GalleryBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            let radius = max(geometry.size.width, geometry.size.height)
            ZStack {
                WindowMaterial()
                GalleryStyle.background.opacity(0.53)
                RadialGradient(colors: [Color(red: 0.20, green: 0.43, blue: 0.59).opacity(0.44), .clear],
                               center: .topLeading, startRadius: 0, endRadius: radius * 0.65)
                RadialGradient(colors: [Color(red: 0.49, green: 0.16, blue: 0.17).opacity(0.38), .clear],
                               center: .bottomLeading, startRadius: 0, endRadius: radius * 0.72)
                RadialGradient(colors: [Color(red: 0.28, green: 0.24, blue: 0.52).opacity(0.30), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: radius * 0.52)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = BackdropView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private final class BackdropView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
            window?.titlebarAppearsTransparent = true
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return background(.regularMaterial, in: shape)
            .background(GalleryStyle.background.opacity(0.24), in: shape)
            .overlay { shape.strokeBorder(GalleryStyle.border).allowsHitTesting(false) }
    }
}

struct GlassActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(GalleryStyle.blue.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
    }
}
