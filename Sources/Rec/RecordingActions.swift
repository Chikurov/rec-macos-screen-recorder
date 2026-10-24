import AVFoundation
import AppKit
import Quartz
import UniformTypeIdentifiers

@MainActor
final class RecordingActions: NSObject, QLPreviewPanelDataSource {
    var onProgress: (URL, String?) -> Void = { _, _ in }
    private(set) var previewURL: URL?
    private(set) var isBusy = false

    func preview(_ url: URL) {
        previewURL = url
        NSApp.activate(ignoringOtherApps: true)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func openInQuickTime(_ url: URL) {
        guard let quickTime = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: quickTime, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func compressedTitle(for preset: RecordingExports.CompressedPreset, duration: Double) -> String {
        let bytes = RecordingExports.estimatedCompressedSize(duration: duration, preset: preset)
        return "Сжатая копия \(preset.label) — до ~\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    func exportCompressed(_ url: URL, preset: RecordingExports.CompressedPreset) {
        guard ensureIdle() else { return }
        let name = url.deletingPathExtension().lastPathComponent + " — сжато \(preset.label)"
        guard let output = askWhereToSave(near: url, name: name, extension: "mp4", type: .mpeg4Movie) else { return }
        guard !RecordingExports.isSameFile(output, url) else {
            showMessage("Нельзя сохранить копию поверх самой записи", detail: "Выберите другое имя или папку.")
            return
        }
        run(url, message: "Сжатие \(preset.label)…") {
            try? FileManager.default.removeItem(at: output)
            try await RecordingExports.exportCompressedCopy(of: url, to: output, preset: preset)
            NSWorkspace.shared.activateFileViewerSelecting([output])
        }
    }

    func exportGIF(_ url: URL) {
        guard ensureIdle() else { return }
        Task {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration).seconds else { return }
            if duration > 60 {
                let alert = NSAlert()
                alert.messageText = "Длинный GIF"
                alert.informativeText = "Запись длится \(Int(duration)) с. GIF такой длины получится очень большим. Продолжить?"
                alert.addButton(withTitle: "Продолжить")
                alert.addButton(withTitle: "Отмена")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            let name = url.deletingPathExtension().lastPathComponent
            guard let output = askWhereToSave(near: url, name: name, extension: "gif", type: .gif),
                  !RecordingExports.isSameFile(output, url) else { return }
            run(url, message: "Создание GIF…") {
                try? FileManager.default.removeItem(at: output)
                try await RecordingExports.makeGIF(from: asset, duration: duration, to: output)
                NSWorkspace.shared.activateFileViewerSelecting([output])
            }
        }
    }

    func menu(for url: URL, duration: Double) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(title: "Просмотр", image: NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil)) { [weak self] in
            self?.preview(url)
        })
        menu.addItem(ActionMenuItem(title: "Обрезать в QuickTime (⌘T)", image: NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)) { [weak self] in
            self?.openInQuickTime(url)
        })
        menu.addItem(ActionMenuItem(title: "Показать в Finder", image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)) { [weak self] in
            self?.revealInFinder(url)
        })
        menu.addItem(.separator())
        for preset in RecordingExports.compressedPresets {
            menu.addItem(ActionMenuItem(title: compressedTitle(for: preset, duration: duration) + "…") { [weak self] in
                self?.exportCompressed(url, preset: preset)
            })
        }
        menu.addItem(ActionMenuItem(title: "GIF-анимация…") { [weak self] in
            self?.exportGIF(url)
        })
        return menu
    }

    @discardableResult
    func run(_ url: URL, message: String, _ work: @escaping () async throws -> Void) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        isBusy = true
        onProgress(url, message)
        return Task {
            do {
                try await work()
            } catch {
                showMessage("Rec", detail: error.localizedDescription)
            }
            isBusy = false
            onProgress(url, nil)
        }
    }

    private func ensureIdle() -> Bool {
        guard isBusy else { return true }
        showMessage("Rec ещё сохраняет предыдущий файл", detail: "Дождитесь, пока он сохранится, и попробуйте снова.")
        return false
    }

    private func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func askWhereToSave(near url: URL, name: String, extension pathExtension: String, type: UTType) -> URL? {
        let suggested = RecordingExports.uniqueURL(in: url.deletingLastPathComponent(), base: name, extension: pathExtension)
        let panel = NSSavePanel()
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { previewURL as NSURL? }
    }
}
