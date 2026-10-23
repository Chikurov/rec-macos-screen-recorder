import AppKit
import SwiftUI

enum BarSkin: String, CaseIterable {
    case dark
    case metal

    var title: String {
        switch self {
        case .dark: return "Тёмный"
        case .metal: return "Белый металл"
        }
    }
}

struct BarTheme {
    let icon: Color
    let iconMuted: Color
    let accent: Color
    let hover: Color
    let border: Color
    let badgeText: Color

    init(skin: BarSkin) {
        switch skin {
        case .dark:
            icon = Color.white.opacity(0.88)
            iconMuted = Color.white.opacity(0.45)
            accent = Color(red: 0.36, green: 0.62, blue: 1.0)
            hover = Color.white.opacity(0.08)
            border = Color.white.opacity(0.08)
            badgeText = Color(red: 0.067, green: 0.075, blue: 0.094)
        case .metal:
            icon = Color(red: 0.17, green: 0.19, blue: 0.22)
            iconMuted = Color(red: 0.17, green: 0.19, blue: 0.22).opacity(0.45)
            accent = Color(red: 0.12, green: 0.45, blue: 0.95)
            hover = Color.black.opacity(0.07)
            border = Color.black.opacity(0.14)
            badgeText = .white
        }
    }
}

private struct BarThemeKey: EnvironmentKey {
    static let defaultValue = BarTheme(skin: .dark)
}

extension EnvironmentValues {
    var barTheme: BarTheme {
        get { self[BarThemeKey.self] }
        set { self[BarThemeKey.self] = newValue }
    }
}

struct BarBackground: View {
    let skin: BarSkin
    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        switch skin {
        case .dark:
            shape
                .fill(Color(red: 0.067, green: 0.075, blue: 0.094))
                .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
        case .metal:
            ZStack {
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.97, green: 0.97, blue: 0.98),
                            Color(red: 0.89, green: 0.90, blue: 0.92),
                            Color(red: 0.83, green: 0.85, blue: 0.87),
                            Color(red: 0.92, green: 0.93, blue: 0.94)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                BrushedMetalTexture()
                    .clipShape(shape)
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white.opacity(0)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.95), Color.black.opacity(0.22)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
        }
    }
}

private struct BrushedMetalTexture: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func random() -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double(seed >> 33) / Double(UInt64(1) << 31)
            }
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = -20
                while x < size.width {
                    let length = 80 + random() * 260
                    let isLight = random() > 0.45
                    let alpha = 0.015 + random() * 0.035
                    let color = isLight ? Color.white.opacity(alpha * 2.2) : Color.black.opacity(alpha)
                    context.fill(Path(CGRect(x: x, y: y, width: length, height: 0.5)), with: .color(color))
                    x += length + random() * 40
                }
                y += 0.5 + random() * 0.6
            }
        }
        .allowsHitTesting(false)
    }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
