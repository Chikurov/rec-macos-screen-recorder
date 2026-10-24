import AppKit
import SwiftUI

enum BarSkin: String, CaseIterable {
    case system
    case dark
    case light
    case metal

    var title: String {
        switch self {
        case .system: return "Как в системе"
        case .dark: return "Тёмная"
        case .light: return "Светлая"
        case .metal: return "Белый металл"
        }
    }

    func resolved(isDarkAppearance: Bool) -> BarSkin {
        guard self == .system else { return self }
        return isDarkAppearance ? .dark : .light
    }
}

struct BarTheme {
    let icon: Color
    let iconMuted: Color
    let accent: Color
    let hover: Color
    let border: Color
    let badgeText: Color
    let recordIdleFill: Color
    let recordIdleText: Color
    let recordIdleBorder: Color
    let activeFill: Color

    init(skin: BarSkin) {
        switch skin {
        case .dark, .system:
            icon = .white
            iconMuted = Color.white.opacity(0.55)
            accent = .white
            hover = Color.white.opacity(0.13)
            border = Color.white.opacity(0.24)
            badgeText = .black
            recordIdleFill = Color(white: 0.2)
            recordIdleText = .white
            recordIdleBorder = Color.white.opacity(0.2)
            activeFill = Color.white.opacity(0.16)
        case .light:
            icon = Color.black.opacity(0.92)
            iconMuted = Color.black.opacity(0.5)
            accent = .black
            hover = Color.black.opacity(0.08)
            border = Color.black.opacity(0.22)
            badgeText = .white
            recordIdleFill = Color(red: 0.16, green: 0.18, blue: 0.21)
            recordIdleText = .white
            recordIdleBorder = .clear
            activeFill = Color.black.opacity(0.09)
        case .metal:
            icon = Color(red: 0.10, green: 0.12, blue: 0.15)
            iconMuted = Color(red: 0.10, green: 0.12, blue: 0.15).opacity(0.55)
            accent = Color(red: 0.12, green: 0.45, blue: 0.95)
            hover = Color.black.opacity(0.08)
            border = Color.black.opacity(0.2)
            badgeText = .white
            recordIdleFill = Color(red: 0.16, green: 0.18, blue: 0.21)
            recordIdleText = .white
            recordIdleBorder = .clear
            activeFill = Color.black.opacity(0.10)
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
    var cornerRadius: CGFloat = 20
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        switch skin {
        case .dark, .system:
            shape
                .fill(Color(white: 0.03))
                .overlay(shape.strokeBorder(Color.white.opacity(0.32), lineWidth: 1))
                .overlay(
                    RoundedRectangle(cornerRadius: max(0, cornerRadius - 1), style: .continuous)
                        .inset(by: 1)
                        .strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center),
                            lineWidth: 1
                        )
                )
        case .light:
            shape
                .fill(Color.white)
                .overlay(shape.strokeBorder(Color.black.opacity(0.26), lineWidth: 1))
                .overlay(
                    RoundedRectangle(cornerRadius: max(0, cornerRadius - 1), style: .continuous)
                        .inset(by: 1)
                        .strokeBorder(
                            LinearGradient(colors: [Color.white, .clear], startPoint: .top, endPoint: .center),
                            lineWidth: 1
                        )
                )
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
