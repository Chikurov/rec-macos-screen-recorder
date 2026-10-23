import AppKit
import SwiftUI

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
    let onMinimize: @MainActor () -> Void

    private var isBusy: Bool { controller.phase != .idle }
    private var theme: BarTheme { BarTheme(skin: settings.skin) }

    var body: some View {
        HStack(spacing: 4) {
            GripDots()
                .frame(width: 16, height: 36)
                .background(WindowDragArea())
                .help("Перетащить")

            sourceButton
                .disabled(controller.isRecording)
                .opacity(controller.isRecording ? 0.5 : 1)

            Spacer().frame(width: 6)

            ToggleWithMenu(
                symbol: settings.microphoneEnabled ? "mic.fill" : "mic.slash",
                isOn: settings.microphoneEnabled,
                help: "Микрофон",
                action: controller.toggleMicrophone,
                menu: controller.showMicrophoneMenu
            )

            BarIconButton(
                symbol: settings.systemAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash",
                tint: settings.systemAudioEnabled ? theme.icon : theme.iconMuted,
                help: "Системный звук",
                action: controller.toggleSystemAudio
            )

            ToggleWithMenu(
                symbol: controller.cameraEnabled ? "video.fill" : "video.slash",
                isOn: controller.cameraEnabled,
                help: "Камера",
                action: controller.toggleCamera,
                menu: controller.showCameraMenu
            )

            if controller.isRecording {
                BarIconButton(
                    symbol: controller.phase == .paused ? "play.fill" : "pause.fill",
                    tint: theme.icon,
                    help: controller.phase == .paused ? "Продолжить" : "Пауза",
                    action: controller.togglePause
                )
            } else {
                BarIconButton(
                    symbol: "timer",
                    tint: settings.countdown > 0 ? theme.accent : theme.iconMuted,
                    badge: settings.countdown > 0 ? "\(settings.countdown)" : nil,
                    help: "Отсчёт перед записью",
                    action: controller.showCountdownMenu
                )
                .disabled(isBusy)
            }

            RecordButton(phase: controller.phase, elapsed: controller.elapsed, action: controller.toggleRecording)
                .padding(.horizontal, 6)

            BarIconButton(symbol: "ellipsis", tint: theme.icon, help: "Ещё", rotation: 90, action: controller.showMoreMenu)
            BarIconButton(symbol: "minus", tint: theme.icon, help: "Свернуть", action: onMinimize)
            BarIconButton(symbol: "xmark", tint: theme.icon, help: "Закрыть Rec") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(WindowDragArea())
        .background(BarBackground(skin: settings.skin))
        .environment(\.barTheme, theme)
        .fixedSize()
    }

    private var sourceButton: some View {
        HoverButton(action: controller.showSourceMenu) {
            HStack(spacing: 8) {
                Image(systemName: controller.source.symbol)
                    .font(.system(size: 15))
                Text(controller.source.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.iconMuted)
            }
            .foregroundStyle(theme.icon)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.border)
            )
        }
        .help("Что записывать")
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
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    Circle().frame(width: 3, height: 3)
                    Circle().frame(width: 3, height: 3)
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
    let action: @MainActor () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            switch phase {
            case .idle, .countdown:
                circle
            case .recording, .paused, .saving:
                capsule
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(phase == .saving)
        .help(help)
    }

    private var fill: Color {
        BarStyle.record.opacity(isHovering ? 0.85 : 1)
    }

    private var circle: some View {
        ZStack {
            Circle().fill(fill).frame(width: 48, height: 48)
            if case .countdown(let value) = phase {
                Text("\(value)")
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            } else {
                Circle().fill(.white).frame(width: 16, height: 16)
            }
        }
    }

    private var capsule: some View {
        HStack(spacing: 8) {
            if phase == .saving {
                ProgressView().controlSize(.small).tint(.white)
                Text("Сохранение…")
                    .font(.system(size: 14, weight: .semibold))
            } else {
                RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 12, height: 12)
                Text("Стоп")
                    .font(.system(size: 14, weight: .semibold))
                Text("·").opacity(0.6)
                RecordingDot(isActive: phase == .recording)
                Text(ControlBarView.format(elapsed))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .opacity(phase == .paused ? 0.6 : 1)
                    .frame(minWidth: 60, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Capsule().fill(fill))
        .contentShape(Capsule())
    }

    private var help: String {
        switch phase {
        case .idle: return "Начать запись"
        case .countdown: return "Отменить"
        case .recording, .paused: return "Остановить и сохранить"
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

private struct ToggleWithMenu: View {
    @Environment(\.barTheme) private var theme
    let symbol: String
    let isOn: Bool
    let help: String
    let action: @MainActor () -> Void
    let menu: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 0) {
            BarIconButton(symbol: symbol, tint: isOn ? theme.icon : theme.iconMuted, help: help, action: action)
            HoverButton(action: menu) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.iconMuted)
                    .frame(width: 16, height: 36)
            }
            .help("\(help): выбрать устройство")
        }
    }
}

private struct BarIconButton: View {
    @Environment(\.barTheme) private var theme
    let symbol: String
    let tint: Color
    var badge: String?
    let help: String
    var rotation: Double = 0
    let action: @MainActor () -> Void

    var body: some View {
        HoverButton(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .rotationEffect(.degrees(rotation))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.badgeText)
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(theme.accent))
                        .offset(x: -2, y: 4)
                }
            }
        }
        .help(help)
    }
}

private struct HoverButton<Label: View>: View {
    @Environment(\.barTheme) private var theme
    let action: @MainActor () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            label()
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isHovering && isEnabled ? theme.hover : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var hotKeyFeedback: String?

    var body: some View {
        Form {
            Section("Оформление") {
                Picker("Скин панели", selection: $settings.skin) {
                    ForEach(BarSkin.allCases, id: \.self) { skin in
                        Text(skin.title).tag(skin)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Сохранение") {
                LabeledContent("Папка") {
                    HStack {
                        Text(settings.folderPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Выбрать…") { settings.chooseFolder() }
                    }
                }
                Button("Сбросить на «Фильмы/Rec»") { settings.resetFolder() }
                Toggle("Открывать окно с записью после остановки", isOn: $settings.revealAfterRecording)
            }

            Section("Видео") {
                Picker("Частота кадров", selection: $settings.frameRate) {
                    Text("30 кадров/с").tag(30)
                    Text("60 кадров/с").tag(60)
                }
                Toggle("Показывать курсор", isOn: $settings.showsCursor)
            }

            Section("Горячие клавиши") {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    HotKeyRecorder(action: action, feedback: $hotKeyFeedback)
                }
                Text(hotKeyFeedback ?? "Сочетание должно включать ⌘, ⌥ или ⌃.")
                    .font(.caption)
                    .foregroundStyle(hotKeyFeedback == nil ? Color.secondary : Color.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
