import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var hotKeyFeedback: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    ForEach(BarSkin.allCases, id: \.self) { skin in
                        SkinTile(
                            skin: skin,
                            previewSkin: skin.resolved(isDarkAppearance: colorScheme == .dark),
                            isSelected: settings.skin == skin
                        ) {
                            settings.skin = skin
                        }
                    }
                }
                .padding(.vertical, 4)
                Toggle("Тонкая панель", isOn: $settings.slimBar)
            } header: {
                Label("Оформление панели", systemImage: "paintpalette")
            }

            Section {
                ForEach(BarButton.allCases, id: \.self) { button in
                    Toggle(isOn: Binding(
                        get: { !settings.hiddenButtons.contains(button) },
                        set: { isShown in
                            if isShown {
                                settings.hiddenButtons.remove(button)
                            } else {
                                settings.hiddenButtons.insert(button)
                            }
                        }
                    )) {
                        Label(button.title, systemImage: button.symbol)
                    }
                }
            } header: {
                Label("Кнопки на панели", systemImage: "slider.horizontal.3")
            }

            Section {
                HStack(spacing: 12) {
                    ForEach(RecordingQuality.allCases, id: \.self) { quality in
                        QualityCard(quality: quality, frameRate: settings.frameRate, isSelected: settings.quality == quality) {
                            settings.quality = quality
                        }
                    }
                }
                .padding(.vertical, 4)
                Picker("Частота кадров", selection: $settings.frameRate) {
                    Text("30 кадров/с").tag(30)
                    Text("60 кадров/с").tag(60)
                }
                .pickerStyle(.segmented)
                Toggle("Показывать курсор в записи", isOn: $settings.showsCursor)
            } header: {
                Label("Видео", systemImage: "film")
            }

            Section {
                LabeledContent("Папка") {
                    HStack {
                        Text(settings.folderPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Выбрать…") { settings.chooseFolder() }
                    }
                }
                HStack {
                    Button("Открыть папку") { NSWorkspace.shared.open(settings.outputFolder()) }
                    Button("Сбросить на «Фильмы/Rec»") { settings.resetFolder() }
                }
            } header: {
                Label("Сохранение", systemImage: "folder")
            }

            Section {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    HotKeyRecorder(action: action, feedback: $hotKeyFeedback)
                }
                Text(hotKeyFeedback ?? "Сочетание должно включать ⌘, ⌥ или ⌃.")
                    .font(.caption)
                    .foregroundStyle(hotKeyFeedback == nil ? Color.secondary : Color.red)
            } header: {
                Label("Горячие клавиши", systemImage: "keyboard")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 700, minHeight: 360)
    }
}

private struct SkinTile: View {
    let skin: BarSkin
    let previewSkin: BarSkin
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 46)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                    )
                Text(skin.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
    }

    private var preview: some View {
        let theme = BarTheme(skin: previewSkin)
        return HStack(spacing: 6) {
            Image(systemName: "mic.fill")
            Image(systemName: "speaker.wave.2.fill")
            Capsule()
                .fill(theme.recordIdleFill)
                .frame(width: 34, height: 18)
                .overlay(Circle().fill(BarStyle.record).frame(width: 7, height: 7))
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.icon)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(BarBackground(skin: previewSkin, cornerRadius: 13))
    }
}

private struct QualityCard: View {
    let quality: RecordingQuality
    let frameRate: Int
    let isSelected: Bool
    let action: () -> Void

    private var estimate: RecorderController.QualityEstimate {
        let screen = NSScreen.main
        let pointSize = screen?.frame.size ?? CGSize(width: 1440, height: 900)
        let scale = RecorderController.captureScale(pointPixelScale: Float(screen?.backingScaleFactor ?? 2), quality: quality)
        return RecorderController.qualityEstimate(pointSize: pointSize, scale: scale, frameRate: frameRate)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(quality.title).font(.headline)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                Text(verbatim: "\(Int(estimate.size.width))×\(Int(estimate.size.height)) · \(estimate.aspect)")
                    .font(.callout.monospacedDigit())
                Text(verbatim: "≈ \(estimate.megabytesPerMinute) МБ/мин")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(quality == .high ? "Максимальная чёткость" : "Меньше места на диске")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
