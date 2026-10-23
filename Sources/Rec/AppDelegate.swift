import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = RecorderController()
    private var barPanel: ControlPanel?
    private var settingsWindow: NSWindow?
    private let resultWindow = RecordingResultWindow()
    private var statusItem: NSStatusItem?
    private var statusSecond = -1
    private var cancellables = Set<AnyCancellable>()

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RecordingEngine.removeTemporaryFiles()
        buildMainMenu()
        createBar()

        controller.openSettings = { [weak self] in self?.showSettings() }
        controller.onRecordingSaved = { [weak self] url in self?.resultWindow.show(url: url) }
        controller.$phase
            .combineLatest(controller.$source, controller.$cameraEnabled, AppSettings.shared.$skin)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.fitBar() }
            }
            .store(in: &cancellables)
        controller.$phase
            .combineLatest(controller.$elapsed)
            .sink { [weak self] phase, elapsed in
                self?.updateStatusItem(phase: phase, elapsed: elapsed)
            }
            .store(in: &cancellables)

        HotKeyManager.shared.onHotKey = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleRecording:
                controller.toggleRecording()
            case .togglePause:
                controller.togglePause()
            }
        }
        HotKeyManager.shared.start()

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showBar()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.isRecording else { return .terminateNow }
        Task {
            await controller.stopRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let title = controller.isRecording ? "Остановить запись" : "Начать запись"
        menu.addItem(ActionMenuItem(title: title) { [weak self] in
            self?.controller.toggleRecording()
        })
        menu.addItem(ActionMenuItem(title: "Показать панель") { [weak self] in
            self?.showBar()
        })
        return menu
    }

    // MARK: - Bar

    private func createBar() {
        let hostingView = FirstClickHostingView(rootView: ControlBarView(controller: controller, onMinimize: { [weak self] in
            self?.barPanel?.orderOut(nil)
        }))
        let size = hostingView.fittingSize

        let panel = ControlPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 60))
        }
        barPanel = panel
        showBar()
    }

    private func showBar() {
        barPanel?.orderFrontRegardless()
    }

    private func fitBar() {
        guard let panel = barPanel, let content = panel.contentView else { return }
        let size = content.fittingSize
        let frame = panel.frame
        guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else { return }
        let newFrame = NSRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height)
        panel.setFrame(newFrame, display: true)
    }

    // MARK: - Status Item

    private func updateStatusItem(phase: RecorderController.Phase, elapsed: TimeInterval) {
        guard phase == .recording || phase == .paused else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            statusSecond = -1
            return
        }

        let isNew = statusItem == nil
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let second = Int(elapsed)
        if isNew || second != statusSecond || item.menu?.items.first?.title != pauseTitle(for: phase) {
            statusSecond = second
            let title = NSMutableAttributedString(
                string: phase == .paused ? "❚❚ " : "● ",
                attributes: [.foregroundColor: phase == .paused ? NSColor.secondaryLabelColor : NSColor.systemRed]
            )
            title.append(NSAttributedString(
                string: ControlBarView.format(elapsed),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
            ))
            item.button?.attributedTitle = title
            item.menu = makeStatusMenu(phase: phase)
        }
    }

    private func pauseTitle(for phase: RecorderController.Phase) -> String {
        phase == .paused ? "Продолжить" : "Пауза"
    }

    private func makeStatusMenu(phase: RecorderController.Phase) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(title: pauseTitle(for: phase)) { [weak self] in
            self?.controller.togglePause()
        })
        menu.addItem(ActionMenuItem(title: "Остановить и сохранить") { [weak self] in
            self?.controller.toggleRecording()
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Показать панель") { [weak self] in
            self?.showBar()
        })
        return menu
    }

    // MARK: - Settings

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Настройки Rec"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: 500, height: 420))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "О программе Rec", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = ActionMenuItem(title: "Настройки…") { [weak self] in self?.showSettings() }
        settingsItem.keyEquivalent = ","
        appMenu.addItem(settingsItem)
        let barItem = ActionMenuItem(title: "Показать панель") { [weak self] in self?.showBar() }
        barItem.keyEquivalent = "0"
        appMenu.addItem(barItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть Rec", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Выйти из Rec", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Окно")
        windowMenu.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }
}
