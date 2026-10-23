import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Rec

final class FormattingTests: XCTestCase {
    func testElapsedTimeFormat() {
        XCTAssertEqual(ControlBarView.format(0), "00:00")
        XCTAssertEqual(ControlBarView.format(5.9), "00:05")
        XCTAssertEqual(ControlBarView.format(65), "01:05")
        XCTAssertEqual(ControlBarView.format(3599), "59:59")
        XCTAssertEqual(ControlBarView.format(3600), "1:00:00")
        XCTAssertEqual(ControlBarView.format(-3), "00:00")
    }

    func testOutputFileName() {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 23
        components.hour = 9
        components.minute = 5
        components.second = 7
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(RecorderController.outputFileName(for: date), "Запись 2026-10-23 в 09.05.07.mp4")
    }

    func testCaptureSourceTitlesAndSymbols() {
        XCTAssertEqual(CaptureSource.display(1, name: "Студия").title, "Студия")
        XCTAssertEqual(CaptureSource.application(bundleID: "com.google.Chrome", name: "Chrome").title, "Chrome")
        XCTAssertEqual(CaptureSource.area(NSRect(x: 10, y: 20, width: 800.4, height: 600.6)).title, "Область 800×600")
        XCTAssertEqual(CaptureSource.display(1, name: "").symbol, "display")
        XCTAssertEqual(CaptureSource.window(5, name: "").symbol, "macwindow")
        XCTAssertEqual(CaptureSource.area(.zero).symbol, "rectangle.dashed")
        XCTAssertNotNil(NSImage(systemSymbolName: CaptureSource.application(bundleID: "", name: "").symbol, accessibilityDescription: nil))
    }
}

final class CaptureGeometryTests: XCTestCase {
    func testEncodableSizeKeepsSmallSizesAndMakesThemEven() {
        XCTAssertEqual(RecorderController.encodableSize(CGSize(width: 2880, height: 1800)), CGSize(width: 2880, height: 1800))
        XCTAssertEqual(RecorderController.encodableSize(CGSize(width: 1001, height: 601)), CGSize(width: 1000, height: 600))
    }

    func testEncodableSizeLimitsTheLongSide() {
        let size = RecorderController.encodableSize(CGSize(width: 5120, height: 2880))
        XCTAssertEqual(size.width, 3840)
        XCTAssertEqual(size.height, 2160)
        let portrait = RecorderController.encodableSize(CGSize(width: 2160, height: 7680))
        XCTAssertEqual(portrait.height, 3840)
        XCTAssertEqual(portrait.width, 1080)
    }

    func testEncodableSizeNeverCollapsesToZero() {
        let size = RecorderController.encodableSize(CGSize(width: 1, height: 1))
        XCTAssertGreaterThanOrEqual(size.width, 2)
        XCTAssertGreaterThanOrEqual(size.height, 2)
    }

    func testCaptureAreaFlipsToTopLeftOrigin() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let area = RecorderController.captureArea(for: NSRect(x: 100, y: 200, width: 400, height: 300), in: screen)
        XCTAssertEqual(area, CGRect(x: 100, y: 400, width: 400, height: 300))
    }

    func testCaptureAreaOnSecondaryScreen() {
        let screen = NSRect(x: 1440, y: -200, width: 1920, height: 1080)
        let area = RecorderController.captureArea(for: NSRect(x: 1540, y: 0, width: 500, height: 400), in: screen)
        XCTAssertEqual(area, CGRect(x: 100, y: 480, width: 500, height: 400))
    }

    func testCaptureAreaIsClippedToTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let area = RecorderController.captureArea(for: NSRect(x: 1300, y: 800, width: 400, height: 300), in: screen)
        XCTAssertEqual(area, CGRect(x: 1300, y: 0, width: 140, height: 100))
    }
}

final class HotKeyTests: XCTestCase {
    func testDisplayString() {
        let hotKey = HotKey(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey))
        XCTAssertEqual(hotKey.displayString, "⌃⌥R")
        let withAll = HotKey(keyCode: UInt32(kVK_F5), carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(withAll.displayString, "⌃⌥⇧⌘F5")
    }

    func testRequiredModifier() {
        XCTAssertFalse(HotKey(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: 0).hasRequiredModifier)
        XCTAssertFalse(HotKey(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(shiftKey)).hasRequiredModifier)
        XCTAssertTrue(HotKey(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(cmdKey)).hasRequiredModifier)
    }

    func testCodableRoundTrip() throws {
        let hotKey = HotKey(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey | optionKey))
        let decoded = try JSONDecoder().decode(HotKey.self, from: JSONEncoder().encode(hotKey))
        XCTAssertEqual(decoded, hotKey)
    }

    func testDefaultShortcutsAreValidAndDistinct() {
        let defaults = HotKeyAction.allCases.map(\.defaultHotKey)
        XCTAssertEqual(Set(defaults.map(\.displayString)).count, defaults.count)
        XCTAssertTrue(defaults.allSatisfy(\.hasRequiredModifier))
        XCTAssertEqual(HotKeyAction.toggleRecording.defaultHotKey.displayString, "⌃⌥R")
        XCTAssertEqual(HotKeyAction.togglePause.defaultHotKey.displayString, "⌃⌥P")
    }
}

final class ThemeTests: XCTestCase {
    func testSkins() {
        XCTAssertEqual(BarSkin.allCases, [.dark, .metal])
        XCTAssertEqual(BarSkin.allCases.map(\.title), ["Тёмный", "Белый металл"])
        XCTAssertNil(BarSkin(rawValue: "glass"))
    }

    func testThemesDifferBySkin() {
        XCTAssertNotEqual(BarTheme(skin: .dark).icon, BarTheme(skin: .metal).icon)
    }

    func testCameraBubbleSizesAreOrdered() {
        let values = CameraBubble.sizes.map(\.value)
        XCTAssertEqual(values, values.sorted())
        XCTAssertTrue(values.contains(200))
    }
}

final class QualityTests: XCTestCase {
    func testHighQualityUsesRetinaScale() {
        XCTAssertEqual(RecorderController.captureScale(pointPixelScale: 2, quality: .high), 2)
        XCTAssertEqual(RecorderController.captureScale(pointPixelScale: 1, quality: .high), 1)
    }

    func testCompactQualityUsesPointSize() {
        XCTAssertEqual(RecorderController.captureScale(pointPixelScale: 2, quality: .compact), 1)
        let compact = RecorderController.encodableSize(CGSize(width: 1440, height: 900))
        let high = RecorderController.encodableSize(CGSize(width: 1440 * 2, height: 900 * 2))
        XCTAssertEqual(high.width * high.height / (compact.width * compact.height), 4)
    }

    func testBrokenScaleFallsBackToOne() {
        XCTAssertEqual(RecorderController.captureScale(pointPixelScale: 0, quality: .high), 1)
    }

    func testQualityTitles() {
        XCTAssertEqual(RecordingQuality.allCases.map(\.title), ["Высокое", "Компактное"])
    }
}
