import AppKit
import SwiftUI

struct BarMetrics {
    let isSlim: Bool
    var button: CGFloat { isSlim ? 26 : 36 }
    var chip: CGFloat { isSlim ? 26 : 38 }
    var icon: CGFloat { isSlim ? 13 : 17 }
    var chevronWidth: CGFloat { isSlim ? 15 : 22 }
    var chevron: CGFloat { isSlim ? 8 : 11 }
    var separator: CGFloat { isSlim ? 16 : 26 }
    var corner: CGFloat { isSlim ? 8 : 11 }
    var groupSpacing: CGFloat { isSlim ? 2 : 4 }
}

private struct BarMetricsKey: EnvironmentKey {
    static let defaultValue = BarMetrics(isSlim: false)
}

extension EnvironmentValues {
    var barMetrics: BarMetrics {
        get { self[BarMetricsKey.self] }
        set { self[BarMetricsKey.self] = newValue }
    }
}

enum BarStyle {
    static let record = Color(red: 0.94, green: 0.27, blue: 0.37)
}

final class ControlPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct ControlBarView: View {
    @ObservedObject var controller: RecorderController
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject private var hotKeys = HotKeyManager.shared
    @Environment(\.colorScheme) private var colorScheme
    let onOpenSettings: @MainActor () -> Void
    let onHide: @MainActor () -> Void

    private var isBusy: Bool { controller.phase != .idle }
    private var skin: BarSkin { settings.skin.resolved(isDarkAppearance: colorScheme == .dark) }
    private var theme: BarTheme { BarTheme(skin: skin) }
    private var metrics: BarMetrics { BarMetrics(isSlim: settings.slimBar) }

    private func shows(_ button: BarButton) -> Bool {
        !settings.hiddenButtons.contains(button)
    }

    private func shortcut(_ action: HotKeyAction) -> String {
        hotKeys.hotKey(for: action).map { " (\($0.displayString))" } ?? ""
    }

    private var showsAudioGroup: Bool {
        shows(.microphone) || shows(.camera) || shows(.systemAudio)
    }

    private var showsTimerSlot: Bool {
        shows(.countdown) || controller.isRecording
    }

    var body: some View {
        HStack(spacing: metrics.isSlim ? 3 : 6) {
            GripDots()
                .frame(width: metrics.isSlim ? 12 : 16, height: metrics.button)
                .background(WindowDragArea(showsHandCursor: true))
                .help("Перетащить панель")

            sourceButton
                .disabled(controller.isRecording)
                .opacity(controller.isRecording ? 0.5 : 1)

            if showsAudioGroup {
                GroupSeparator()
                HStack(spacing: metrics.groupSpacing) {
                    if shows(.microphone) {
                        DeviceChip(
                            symbol: settings.microphoneEnabled ? "mic.fill" : "mic.slash",
                            isOn: settings.microphoneEnabled,
                            help: settings.microphoneEnabled ? "Микрофон включён — нажмите, чтобы выключить" : "Микрофон выключен — нажмите, чтобы включить",
                            menuHelp: "Выбрать микрофон",
                            level: controller.isRecording && settings.microphoneEnabled ? controller.microphoneLevel : nil,
                            action: controller.toggleMicrophone,
                            menu: controller.showMicrophoneMenu,
                            isMenuDisabled: controller.isRecording,
                            disabledMenuHelp: "Микрофон меняется до начала записи"
                        )
                    }
                    if shows(.camera) {
                        DeviceChip(
                            symbol: controller.cameraEnabled ? "video.fill" : "video.slash",
                            isOn: controller.cameraEnabled,
                            help: controller.cameraEnabled ? "Камера включена — нажмите, чтобы выключить" : "Камера выключена — нажмите, чтобы включить",
                            menuHelp: "Выбрать камеру и размер",
                            level: nil,
                            action: controller.toggleCamera,
                            menu: controller.showCameraMenu
                        )
                    }
                    if shows(.systemAudio) {
                        DeviceChip(
                            symbol: "display",
                            badgeSymbol: settings.systemAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            isOn: settings.systemAudioEnabled,
                            help: settings.systemAudioEnabled ? "Звук компьютера записывается — нажмите, чтобы выключить" : "Звук компьютера не записывается — нажмите, чтобы включить",
                            menuHelp: "",
                            level: nil,
                            action: controller.toggleSystemAudio,
                            menu: nil
                        )
                    }
                }
            }

            if showsTimerSlot || shows(.zoom) {
                GroupSeparator()
                HStack(spacing: metrics.groupSpacing) {
                    if showsTimerSlot {
                        ZStack {
                            if controller.isRecording {
                                BarIconButton(
                                    symbol: controller.phase == .paused ? "play.fill" : "pause.fill",
                                    tint: theme.icon,
                                    help: (controller.phase == .paused ? "Продолжить запись" : "Пауза") + shortcut(.togglePause),
                                    action: controller.togglePause
                                )
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                            } else {
                                BarIconButton(
                                    symbol: "timer",
                                    tint: theme.icon,
                                    badge: settings.countdown > 0 ? "\(settings.countdown)" : nil,
                                    help: settings.countdown > 0 ? "Отсчёт перед записью: \(settings.countdown) с" : "Отсчёт перед записью выключен",
                                    opensMenu: true,
                                    action: controller.showCountdownMenu
                                )
                                .disabled(isBusy)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        }
                        .frame(width: metrics.button, height: metrics.button)
                    }
                    if shows(.zoom) {
                        BarIconButton(
                            symbol: controller.isZoomed ? "minus.magnifyingglass" : "plus.magnifyingglass",
                            tint: controller.isZoomed ? theme.accent : theme.icon,
                            isActive: controller.isZoomed,
                            help: controller.isZoomed
                                ? "Отдалить" + shortcut(.toggleZoom)
                                : "Приблизить фрагмент во время записи" + shortcut(.toggleZoom),
                            action: controller.toggleZoom
                        )
                    }
                }
            }

            GroupSeparator()
            RecordButton(
                phase: controller.phase,
                elapsed: controller.elapsed,
                shortcut: shortcut(.toggleRecording),
                action: controller.toggleRecording
            )

            GroupSeparator()
            HStack(spacing: 2) {
                if shows(.folder) {
                    BarIconButton(symbol: "folder", tint: theme.icon, help: "Открыть папку с записями в Finder", action: controller.openRecordingsFolder)
                }
                BarIconButton(symbol: "gearshape", tint: theme.icon, help: "Настройки (⌘,)", action: onOpenSettings)
                BarIconButton(symbol: "xmark", tint: theme.icon, help: "Скрыть панель — вернуть: клик по значку Rec в Dock", action: onHide)
            }
        }
        .padding(.horizontal, metrics.isSlim ? 6 : 12)
        .padding(.vertical, metrics.isSlim ? 4 : 10)
        .background(WindowDragArea())
        .background(BarBackground(skin: skin, cornerRadius: metrics.isSlim ? 12 : 20))
        .environment(\.barTheme, theme)
        .environment(\.barMetrics, metrics)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: controller.phase)
        .fixedSize()
    }

    private var sourceButton: some View {
        HoverButton(opensMenu: true, action: controller.showSourceMenu) {
            HStack(spacing: metrics.isSlim ? 4 : 8) {
                Image(systemName: controller.source.symbol)
                    .font(.system(size: metrics.isSlim ? 12 : 15))
                if !metrics.isSlim {
                    Text(controller.source.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: 170, alignment: .leading)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: metrics.isSlim ? 8 : 10, weight: .semibold))
                    .foregroundStyle(theme.iconMuted)
            }
            .foregroundStyle(theme.icon)
            .padding(.horizontal, metrics.isSlim ? 7 : 12)
            .frame(height: metrics.isSlim ? 26 : 40)
            .overlay(
                RoundedRectangle(cornerRadius: metrics.isSlim ? 8 : 12, style: .continuous)
                    .strokeBorder(theme.border)
            )
        }
        .help("Что записывать: " + controller.source.title)
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        let rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%02d:%02d", minutes, rest)
    }
}

private struct GripDots: View {
    @Environment(\.barTheme) private var theme
    @Environment(\.barMetrics) private var metrics
    var body: some View {
        let dot: CGFloat = metrics.isSlim ? 2.5 : 3
        VStack(spacing: metrics.isSlim ? 2.5 : 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: metrics.isSlim ? 2.5 : 3) {
                    Circle().frame(width: dot, height: dot)
                    Circle().frame(width: dot, height: dot)
                }
            }
        }
        .foregroundStyle(theme.iconMuted)
        .allowsHitTesting(false)
    }
}

private struct RecordButton: View {
    let phase: RecorderController.Phase
    let elapsed: TimeInterval
    let shortcut: String
    let action: @MainActor () -> Void
    @Environment(\.barTheme) private var theme
    @Environment(\.barMetrics) private var metrics
    @State private var isHovering = false

    static let width: CGFloat = 178

    private var width: CGFloat {
        metrics.isSlim ? 84 : Self.width
    }

    private var isRecording: Bool {
        phase == .recording || phase == .paused
    }

    private var isIdleLike: Bool {
        switch phase {
        case .idle, .countdown: return true
        default: return false
        }
    }

    private var fill: Color {
        switch phase {
        case .idle, .countdown: return theme.recordIdleFill
        case .recording: return BarStyle.record
        case .paused: return BarStyle.record.opacity(0.55)
        case .saving: return Color.gray.opacity(0.6)
        }
    }

    private var foreground: Color {
        switch phase {
        case .idle, .countdown: return theme.recordIdleText
        default: return .white
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: metrics.isSlim ? 6 : 9) {
                if !isRecording || metrics.isSlim {
                    Spacer(minLength: 0)
                }
                symbol
                if !metrics.isSlim {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .contentTransition(.opacity)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isRecording && metrics.isSlim {
                    Text(ControlBarView.format(elapsed))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(phase == .paused ? 0.7 : 1)
                    Spacer(minLength: 0)
                } else if isRecording {
                    HStack(spacing: 6) {
                        RecordingDot(isActive: phase == .recording)
                        Text(ControlBarView.format(elapsed))
                            .font(.system(size: 14, weight: .medium).monospacedDigit())
                            .contentTransition(.numericText())
                            .opacity(phase == .paused ? 0.7 : 1)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, metrics.isSlim ? 8 : 16)
            .frame(width: width, height: metrics.isSlim ? 26 : 44)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(isIdleLike ? theme.recordIdleBorder : .clear))
            .overlay(Capsule().fill(Color.white.opacity(isHovering && phase != .saving ? 0.1 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(phase == .saving)
        .help(help)
    }

    @ViewBuilder
    private var symbol: some View {
        switch phase {
        case .saving:
            ProgressView().controlSize(.small).tint(.white).frame(width: 14, height: 14)
        case .countdown(let value):
            Text("\(value)")
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(BarStyle.record)
                .contentTransition(.numericText(countsDown: true))
                .frame(width: 14, height: 14)
        case .idle:
            Circle().fill(BarStyle.record).frame(width: metrics.isSlim ? 10 : 12, height: metrics.isSlim ? 10 : 12)
        case .recording, .paused:
            RoundedRectangle(cornerRadius: metrics.isSlim ? 2 : 3, style: .continuous)
                .fill(.white)
                .frame(width: metrics.isSlim ? 9 : 13, height: metrics.isSlim ? 9 : 13)
        }
    }

    private var title: String {
        switch phase {
        case .idle: return "Запись"
        case .countdown: return "Отмена"
        case .recording, .paused: return "Стоп"
        case .saving: return "Сохранение…"
        }
    }

    private var help: String {
        switch phase {
        case .idle: return "Начать запись" + shortcut
        case .countdown: return "Отменить запись" + shortcut
        case .recording, .paused: return "Остановить и сохранить" + shortcut
        case .saving: return "Сохранение…"
        }
    }
}

private struct RecordingDot: View {
    let isActive: Bool
    @State private var isBright = true

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 7, height: 7)
            .opacity(isActive ? (isBright ? 1 : 0.2) : 0.5)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    isBright = false
                }
            }
    }
}

private struct GroupSeparator: View {
    @Environment(\.barTheme) private var theme
    @Environment(\.barMetrics) private var metrics

    var body: some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: 1, height: metrics.separator)
            .padding(.horizontal, metrics.isSlim ? 1 : 2)
    }
}

private struct DeviceChip: View {
    @Environment(\.barTheme) private var theme
    @Environment(\.barMetrics) private var metrics
    let symbol: String
    var badgeSymbol: String?
    let isOn: Bool
    let help: String
    let menuHelp: String
    let level: Double?
    let action: @MainActor () -> Void
    let menu: (@MainActor () -> Void)?
    var isMenuDisabled = false
    var disabledMenuHelp = ""

    var body: some View {
        HStack(spacing: 0) {
            HoverButton(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: metrics.icon, weight: .regular))
                    .foregroundStyle(theme.icon)
                    .overlay(alignment: .bottomTrailing) {
                        if let badgeSymbol {
                            Image(systemName: badgeSymbol)
                                .font(.system(size: metrics.isSlim ? 5.5 : 7, weight: .bold))
                                .foregroundStyle(theme.badgeText)
                                .frame(width: metrics.isSlim ? 11 : 14, height: metrics.isSlim ? 11 : 14)
                                .background(Circle().fill(theme.icon))
                                .offset(x: metrics.isSlim ? 5 : 6, y: metrics.isSlim ? 4 : 5)
                        }
                    }
                    .frame(width: metrics.chip, height: metrics.chip)
            }
            .help(help)
            .overlay(alignment: .bottom) {
                if let level {
                    LevelMeter(level: level)
                        .padding(.bottom, metrics.isSlim ? 2 : 4)
                }
            }
            if let menu {
                HoverButton(opensMenu: true, action: menu) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: metrics.chevron, weight: .bold))
                        .foregroundStyle(theme.icon.opacity(0.8))
                        .frame(width: metrics.chevronWidth, height: metrics.chip)
                }
                .disabled(isMenuDisabled)
                .opacity(isMenuDisabled ? 0.35 : 1)
                .help(isMenuDisabled ? disabledMenuHelp : menuHelp)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: metrics.corner, style: .continuous)
                .fill(isOn ? theme.activeFill : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.corner, style: .continuous)
                .strokeBorder(isOn ? theme.border : .clear)
        )
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

private struct LevelMeter: View {
    let level: Double
    @Environment(\.barTheme) private var theme

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(theme.iconMuted.opacity(0.35))
            Capsule()
                .fill(level > 0.9 ? Color.orange : Color.green)
                .frame(width: max(2, 20 * level))
        }
        .frame(width: 20, height: 3)
        .animation(.linear(duration: 0.07), value: level)
        .allowsHitTesting(false)
    }
}

private struct BarIconButton: View {
    @Environment(\.barTheme) private var theme
    @Environment(\.barMetrics) private var metrics
    let symbol: String
    let tint: Color
    var badge: String?
    var isActive = false
    let help: String
    var rotation: Double = 0
    var opensMenu = false
    let action: @MainActor () -> Void

    var body: some View {
        HoverButton(opensMenu: opensMenu, action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: metrics.icon, weight: .regular))
                    .rotationEffect(.degrees(rotation))
                    .foregroundStyle(tint)
                    .frame(width: metrics.button, height: metrics.button)
                    .background(
                        RoundedRectangle(cornerRadius: metrics.isSlim ? 7 : 10, style: .continuous)
                            .fill(isActive ? theme.activeFill : .clear)
                    )
                if let badge {
                    Text(badge)
                        .font(.system(size: metrics.isSlim ? 7 : 9, weight: .bold))
                        .foregroundStyle(theme.badgeText)
                        .padding(.horizontal, metrics.isSlim ? 2 : 3)
                        .background(Capsule().fill(theme.accent))
                        .offset(x: metrics.isSlim ? 0 : -2, y: metrics.isSlim ? 1 : 4)
                }
            }
        }
        .help(help)
    }
}

private struct HoverButton<Label: View>: View {
    @Environment(\.barTheme) private var theme
    var opensMenu = false
    let action: @MainActor () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false
    @State private var frame: CGRect = .zero
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            if opensMenu {
                let anchor = MenuAnchor.screenRect(forBarFrame: frame)
                guard !MenuAnchor.justClosed(by: anchor) else { return }
                MenuAnchor.prepare(anchor)
            }
            action()
        } label: {
            label()
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isHovering && isEnabled ? theme.hover : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { frame = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, new in frame = new }
        })
    }
}

struct WindowDragArea: NSViewRepresentable {
    var showsHandCursor = false

    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.showsHandCursor = showsHandCursor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        var showsHandCursor = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            guard showsHandCursor else { return }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func cursorUpdate(with event: NSEvent) {
            showHand()
        }

        override func mouseEntered(with event: NSEvent) {
            showHand()
        }

        override func mouseMoved(with event: NSEvent) {
            showHand()
        }

        private func showHand() {
            NSCursor.openHand.set()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if self.bounds.contains(point) {
                    NSCursor.openHand.set()
                }
            }
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        override func mouseDown(with event: NSEvent) {
            if showsHandCursor {
                NSCursor.closedHand.set()
            }
            window?.performDrag(with: event)
            if showsHandCursor {
                NSCursor.openHand.set()
            }
        }
    }
}
