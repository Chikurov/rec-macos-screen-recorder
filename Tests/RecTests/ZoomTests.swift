import AppKit
import XCTest
@testable import Rec

final class ZoomGeometryTests: XCTestCase {
    private let base = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func assertAspect(_ rect: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.width / rect.height, base.width / base.height, accuracy: 0.001, file: file, line: line)
    }

    func testWideSelectionGrowsInHeight() {
        let rect = RecorderController.zoomRect(for: CGRect(x: 400, y: 400, width: 600, height: 100), matching: base)
        assertAspect(rect)
        XCTAssertEqual(rect.width, 600, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 700, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 450, accuracy: 0.001)
    }

    func testTallSelectionGrowsInWidth() {
        let rect = RecorderController.zoomRect(for: CGRect(x: 600, y: 200, width: 100, height: 400), matching: base)
        assertAspect(rect)
        XCTAssertEqual(rect.height, 400, accuracy: 0.001)
    }

    func testZoomNeverExceedsFourTimes() {
        let rect = RecorderController.zoomRect(for: CGRect(x: 700, y: 440, width: 20, height: 20), matching: base)
        XCTAssertEqual(rect.width, base.width / 4, accuracy: 0.001)
        assertAspect(rect)
    }

    func testZoomStaysInsideTheCaptureArea() {
        let rect = RecorderController.zoomRect(for: CGRect(x: 1300, y: 820, width: 200, height: 100), matching: base)
        XCTAssertTrue(base.contains(rect))
        XCTAssertEqual(rect.maxX, base.maxX, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, base.maxY, accuracy: 0.001)
    }

    func testHugeSelectionFallsBackToFullArea() {
        XCTAssertEqual(RecorderController.zoomRect(for: CGRect(x: -100, y: -100, width: 3000, height: 2000), matching: base), base)
    }

    func testZoomInsideAnArea() {
        let area = CGRect(x: 200, y: 100, width: 800, height: 450)
        let rect = RecorderController.zoomRect(for: CGRect(x: 900, y: 500, width: 100, height: 100), matching: area)
        XCTAssertTrue(area.contains(rect))
        XCTAssertEqual(rect.width / rect.height, area.width / area.height, accuracy: 0.001)
    }

    func testEaseOutStartsFastAndSettlesSmoothly() {
        XCTAssertEqual(RecorderController.easeOut(0), 0)
        XCTAssertEqual(RecorderController.easeOut(1), 1)
        XCTAssertGreaterThan(RecorderController.easeOut(0.25), 0.6)
        XCTAssertLessThan(RecorderController.easeOut(1) - RecorderController.easeOut(0.9), 0.001)
        XCTAssertEqual(RecorderController.easeOut(1.5), 1)
    }

    func testInterpolate() {
        let start = CGRect(x: 0, y: 0, width: 100, height: 50)
        let end = CGRect(x: 100, y: 50, width: 300, height: 150)
        XCTAssertEqual(RecorderController.interpolate(from: start, to: end, progress: 0), start)
        XCTAssertEqual(RecorderController.interpolate(from: start, to: end, progress: 1), end)
        XCTAssertEqual(RecorderController.interpolate(from: start, to: end, progress: 0.5), CGRect(x: 50, y: 25, width: 200, height: 100))
    }
}

final class AreaMoveTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    func testMoveInsideScreenIsKept() {
        let rect = NSRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(RecorderController.clampedArea(rect.offsetBy(dx: 50, dy: -20), in: screen), NSRect(x: 150, y: 80, width: 400, height: 300))
    }

    func testMoveStopsAtScreenEdges() {
        let rect = NSRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(RecorderController.clampedArea(rect.offsetBy(dx: 5000, dy: 5000), in: screen), NSRect(x: 1040, y: 600, width: 400, height: 300))
        XCTAssertEqual(RecorderController.clampedArea(rect.offsetBy(dx: -5000, dy: -5000), in: screen), NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testMoveOnSecondaryScreen() {
        let second = NSRect(x: 1440, y: -200, width: 1920, height: 1080)
        let rect = NSRect(x: 1500, y: 0, width: 400, height: 300)
        XCTAssertEqual(RecorderController.clampedArea(rect.offsetBy(dx: -500, dy: 0), in: second).minX, 1440)
    }
}

final class QualityEstimateTests: XCTestCase {
    func testAspectRatios() {
        XCTAssertEqual(RecorderController.aspectRatio(CGSize(width: 1440, height: 900)), "16:10")
        XCTAssertEqual(RecorderController.aspectRatio(CGSize(width: 1920, height: 1080)), "16:9")
        XCTAssertEqual(RecorderController.aspectRatio(CGSize(width: 1024, height: 768)), "4:3")
        XCTAssertEqual(RecorderController.aspectRatio(CGSize(width: 1000, height: 300)), "10:3")
        XCTAssertEqual(RecorderController.aspectRatio(.zero), "—")
    }

    func testRetinaEstimateUsesFullResolution() {
        let high = RecorderController.qualityEstimate(pointSize: CGSize(width: 1440, height: 900), scale: 2, frameRate: 30)
        XCTAssertEqual(high.size, CGSize(width: 2880, height: 1800))
        XCTAssertEqual(high.aspect, "16:10")
        let compact = RecorderController.qualityEstimate(pointSize: CGSize(width: 1440, height: 900), scale: 1, frameRate: 30)
        XCTAssertEqual(compact.size, CGSize(width: 1440, height: 900))
        XCTAssertGreaterThan(high.megabytesPerMinute, compact.megabytesPerMinute * 3)
    }

    func testEstimateMatchesTheEncoderBitRate() {
        let estimate = RecorderController.qualityEstimate(pointSize: CGSize(width: 1440, height: 900), scale: 2, frameRate: 30)
        let videoBits = Double(RecordingEngine.videoBitRate(width: 2880, height: 1800, frameRate: 30))
        let expected = (videoBits + 416_000) * 60 / 8 / 1_000_000
        XCTAssertEqual(Double(estimate.megabytesPerMinute), expected, accuracy: 5)
    }

    func testSixtyFramesDoublesTheEstimate() {
        let thirty = RecorderController.qualityEstimate(pointSize: CGSize(width: 1440, height: 900), scale: 2, frameRate: 30)
        let sixty = RecorderController.qualityEstimate(pointSize: CGSize(width: 1440, height: 900), scale: 2, frameRate: 60)
        XCTAssertEqual(Double(sixty.megabytesPerMinute) / Double(thirty.megabytesPerMinute), 2, accuracy: 0.1)
    }
}
