import AppKit
import SwiftUI
import XCTest
@testable import Rec

@MainActor
final class ControlBarLayoutTests: XCTestCase {
    private var savedSkin = BarSkin.system
    private var savedSlim = false
    private var savedHidden = Set<BarButton>()

    private let phases: [RecorderController.Phase] = [.idle, .countdown(3), .recording, .paused, .saving]

    override func setUp() async throws {
        let settings = AppSettings.shared
        savedSkin = settings.skin
        savedSlim = settings.slimBar
        savedHidden = settings.hiddenButtons
    }

    override func tearDown() async throws {
        let settings = AppSettings.shared
        settings.skin = savedSkin
        settings.slimBar = savedSlim
        settings.hiddenButtons = savedHidden
    }

    private func barSize(_ controller: RecorderController) -> NSSize {
        let host = NSHostingView(rootView: ControlBarView(controller: controller, onOpenSettings: {}, onHide: {}))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func sizes(slim: Bool, skin: BarSkin, hidden: Set<BarButton> = []) -> [NSSize] {
        let settings = AppSettings.shared
        settings.skin = skin
        settings.slimBar = slim
        settings.hiddenButtons = hidden
        let controller = RecorderController()
        return phases.map { phase in
            controller.setPhaseForTesting(phase)
            return barSize(controller)
        }
    }

    func testBarKeepsItsSizeWhenRecordingStarts() {
        for slim in [false, true] {
            for skin in BarSkin.allCases {
                let sizes = sizes(slim: slim, skin: skin)
                for (phase, size) in zip(phases, sizes) {
                    XCTAssertEqual(size.width, sizes[0].width, accuracy: 0.5, "\(skin) slim=\(slim) \(phase)")
                    XCTAssertEqual(size.height, sizes[0].height, accuracy: 0.5, "\(skin) slim=\(slim) \(phase)")
                }
            }
        }
    }

    func testBarKeepsItsSizeWithHiddenButtons() {
        for hidden in [Set([BarButton.microphone]), [.camera, .systemAudio], [.microphone, .camera, .systemAudio, .zoom, .folder]] {
            for slim in [false, true] {
                let sizes = sizes(slim: slim, skin: .dark, hidden: hidden)
                for (phase, size) in zip(phases, sizes) {
                    XCTAssertEqual(size.width, sizes[0].width, accuracy: 0.5, "\(hidden) slim=\(slim) \(phase)")
                }
            }
        }
    }

    func testSlimBarIsLowAndNarrow() {
        let regular = sizes(slim: false, skin: .dark)[0]
        let slim = sizes(slim: true, skin: .dark)[0]
        XCTAssertLessThanOrEqual(slim.height, 34.5)
        XCTAssertLessThan(slim.width, regular.width * 0.6)
    }

    func testHiddenButtonsMakeTheBarNarrower() {
        let all = sizes(slim: false, skin: .dark)[0]
        let fewer = sizes(slim: false, skin: .dark, hidden: [.zoom, .folder])[0]
        XCTAssertLessThan(fewer.width, all.width)
    }

    func testSlimTargetsStayClickable() {
        let slim = BarMetrics(isSlim: true)
        let regular = BarMetrics(isSlim: false)
        XCTAssertGreaterThanOrEqual(slim.button, 24)
        XCTAssertGreaterThanOrEqual(slim.chip, 24)
        XCTAssertLessThan(slim.button, regular.button)
        XCTAssertLessThan(slim.icon, regular.icon)
        XCTAssertLessThan(slim.separator, regular.separator)
    }
}

final class BarFrameTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 25, width: 1440, height: 850)

    func testResizeKeepsLeftAndBottomEdges() {
        let current = NSRect(x: 200, y: 60, width: 860, height: 56)
        let frame = AppDelegate.barFrame(current: current, fitting: NSSize(width: 400, height: 34), visible: screen)
        XCTAssertEqual(frame, NSRect(x: 200, y: 60, width: 400, height: 34))
    }

    func testGrowingBarStaysOnScreen() {
        let current = NSRect(x: 1000, y: 60, width: 400, height: 34)
        let frame = AppDelegate.barFrame(current: current, fitting: NSSize(width: 860, height: 56), visible: screen)
        XCTAssertEqual(frame.maxX, screen.maxX)
        XCTAssertEqual(frame.minY, 60)
    }

    func testBarWiderThanScreenStartsAtLeftEdge() {
        let current = NSRect(x: 300, y: 60, width: 400, height: 34)
        let frame = AppDelegate.barFrame(current: current, fitting: NSSize(width: 1600, height: 56), visible: screen)
        XCTAssertEqual(frame.minX, screen.minX)
    }

    func testWithoutScreenOnlySizeChanges() {
        let current = NSRect(x: 5000, y: 60, width: 400, height: 34)
        let frame = AppDelegate.barFrame(current: current, fitting: NSSize(width: 860, height: 56), visible: nil)
        XCTAssertEqual(frame.origin, current.origin)
    }
}

@MainActor
final class MenuAnchorTests: XCTestCase {
    private let source = NSRect(x: 100, y: 40, width: 220, height: 40)
    private let microphone = NSRect(x: 400, y: 40, width: 22, height: 38)
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func testSecondClickOnTheSameButtonClosesTheMenu() {
        MenuAnchor.didClose(anchor: source, now: start)
        XCTAssertTrue(MenuAnchor.justClosed(by: source, now: start.addingTimeInterval(0.1)))
    }

    func testClickOnAnotherButtonOpensItsMenu() {
        MenuAnchor.didClose(anchor: source, now: start)
        XCTAssertFalse(MenuAnchor.justClosed(by: microphone, now: start.addingTimeInterval(0.1)))
    }

    func testLaterClickOpensTheMenuAgain() {
        MenuAnchor.didClose(anchor: source, now: start)
        XCTAssertFalse(MenuAnchor.justClosed(by: source, now: start.addingTimeInterval(1)))
    }

    func testMenuWithoutAnchorNeverBlocksClicks() {
        MenuAnchor.didClose(anchor: nil, now: start)
        XCTAssertFalse(MenuAnchor.justClosed(by: source, now: start))
        XCTAssertFalse(MenuAnchor.justClosed(by: nil, now: start))
    }

    func testPendingAnchorIsUsedOnce() {
        MenuAnchor.prepare(source, now: start)
        XCTAssertEqual(MenuAnchor.take(now: start.addingTimeInterval(0.5)), source)
        XCTAssertNil(MenuAnchor.take(now: start.addingTimeInterval(0.6)))
    }

    func testStaleAnchorIsIgnored() {
        MenuAnchor.prepare(source, now: start)
        XCTAssertNil(MenuAnchor.take(now: start.addingTimeInterval(3)))
    }

    func testMenuOpensBelowWhenThereIsRoom() {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 850)
        let anchor = NSRect(x: 100, y: 500, width: 200, height: 40)
        XCTAssertEqual(MenuAnchor.menuOrigin(below: anchor, menuHeight: 200, visibleFrame: screen), NSPoint(x: 100, y: 496))
    }

    func testMenuOpensAboveAndClearsTheButton() {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 850)
        let anchor = NSRect(x: 100, y: 40, width: 200, height: 40)
        let origin = MenuAnchor.menuOrigin(below: anchor, menuHeight: 260, visibleFrame: screen)
        XCTAssertGreaterThan(origin.y - 260, anchor.maxY)
    }
}

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testSettingsFitASmallWindowAndScroll() {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SettingsView())
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.layoutIfNeeded()
        XCTAssertEqual(window.contentLayoutRect.height, 400, accuracy: 1)
        XCTAssertLessThanOrEqual(window.contentMinSize.height, 400)
        window.setContentSize(NSSize(width: 900, height: 700))
        window.layoutIfNeeded()
        XCTAssertEqual(window.contentLayoutRect.width, 900, accuracy: 1)
        XCTAssertEqual(window.contentLayoutRect.height, 700, accuracy: 1)
    }
}

final class PersistedNamesTests: XCTestCase {
    func testSkinNamesStayStable() {
        XCTAssertEqual(BarSkin.allCases.map(\.rawValue), ["system", "dark", "light", "metal"])
    }

    func testBarButtonNamesStayStable() {
        XCTAssertEqual(BarButton.allCases.map(\.rawValue), ["microphone", "camera", "systemAudio", "countdown", "zoom", "folder"])
    }

    func testQualityNamesStayStable() {
        XCTAssertEqual(RecordingQuality.allCases.map(\.rawValue), ["high", "compact"])
    }
}

final class RecordButtonStyleTests: XCTestCase {
    func testLightRecordButtonMatchesMetal() {
        XCTAssertEqual(BarTheme(skin: .light).recordIdleFill, BarTheme(skin: .metal).recordIdleFill)
        XCTAssertEqual(BarTheme(skin: .light).recordIdleText, BarTheme(skin: .metal).recordIdleText)
    }

    func testDarkRecordButtonIsRaisedWithABorder() {
        let dark = BarTheme(skin: .dark)
        XCTAssertNotEqual(dark.recordIdleBorder, .clear)
        XCTAssertEqual(dark.recordIdleText, .white)
        XCTAssertEqual(BarTheme(skin: .system).recordIdleFill, dark.recordIdleFill)
    }

    func testRecordTextContrastsWithItsButton() {
        for skin in BarSkin.allCases {
            let theme = BarTheme(skin: skin)
            XCTAssertGreaterThan(Self.contrast(theme.recordIdleFill, theme.recordIdleText), 4.5, "\(skin)")
        }
    }

    private static func contrast(_ first: Color, _ second: Color) -> Double {
        func luminance(_ color: Color) -> Double {
            let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722 * channel(rgb.blueComponent)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
