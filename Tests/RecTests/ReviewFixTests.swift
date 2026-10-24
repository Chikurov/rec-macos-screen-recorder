import AppKit
import XCTest
@testable import Rec

final class SameFileTests: XCTestCase {
    func testSamePathInDifferentSpellingIsTheSameFile() throws {
        let url = TestMedia.temporaryURL("mp4")
        try Data([1]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let spelled = url.deletingLastPathComponent().appendingPathComponent(".").appendingPathComponent(url.lastPathComponent)
        XCTAssertTrue(RecordingExports.isSameFile(url, spelled))
    }

    func testSymlinkPointsToTheSameFile() throws {
        let url = TestMedia.temporaryURL("mp4")
        let link = TestMedia.temporaryURL("mp4")
        try Data([1]).write(to: url)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: link)
        }
        XCTAssertTrue(RecordingExports.isSameFile(url, link))
    }

    func testDifferentFilesAreNotTheSame() throws {
        let first = TestMedia.temporaryURL("mp4")
        let second = TestMedia.temporaryURL("mp4")
        try Data([1]).write(to: first)
        addTeardownBlock { try? FileManager.default.removeItem(at: first) }
        XCTAssertFalse(RecordingExports.isSameFile(first, second))
    }
}

@MainActor
final class ExportQueueTests: XCTestCase {
    func testSecondExportDoesNotStartWhileTheFirstRuns() async {
        let actions = RecordingActions()
        var progress: [String?] = []
        actions.onProgress = { _, message in progress.append(message) }
        let url = URL(fileURLWithPath: "/tmp/recording.mp4")

        let first = actions.run(url, message: "Сжатие 720p…") {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertNotNil(first)
        XCTAssertTrue(actions.isBusy)
        let second = actions.run(url, message: "Создание GIF…") {}
        XCTAssertNil(second)

        await first?.value
        XCTAssertFalse(actions.isBusy)
        XCTAssertEqual(progress, ["Сжатие 720p…", nil])
        XCTAssertNotNil(actions.run(url, message: "Создание GIF…") {})
    }
}

@MainActor
final class ThumbnailTests: XCTestCase {
    private var movie: URL!

    override func setUp() async throws {
        movie = TestMedia.temporaryURL("mov")
        try await TestMedia.writeMovie(to: movie, duration: 1)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: movie)
    }

    private func visibleThumbnailPanels() -> Int {
        NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("ThumbnailPanel") }.count
    }

    private func waitUntilShown(_ thumbnail: RecordingThumbnail) async {
        for _ in 0..<50 where !thumbnail.isShowing {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    func testOverlappingShowsLeaveOneThumbnail() async {
        _ = NSApplication.shared
        let thumbnail = RecordingThumbnail(actions: RecordingActions())
        thumbnail.show(url: movie, above: nil)
        thumbnail.show(url: movie, above: nil)
        thumbnail.show(url: movie, above: nil)
        await waitUntilShown(thumbnail)
        XCTAssertEqual(visibleThumbnailPanels(), 1)
        thumbnail.hide(animated: false)
        XCTAssertEqual(visibleThumbnailPanels(), 0)
    }

    func testBusyMessageSentBeforeTheThumbnailAppearsIsShown() async {
        _ = NSApplication.shared
        let thumbnail = RecordingThumbnail(actions: RecordingActions())
        thumbnail.setBusy("Сжатие 720p…", for: movie)
        await waitUntilShown(thumbnail)
        XCTAssertEqual(thumbnail.busyMessage, "Сжатие 720p…")
        thumbnail.hide(animated: false)
    }

    func testExportThatEndsBeforeTheThumbnailAppearsLeavesNoSpinner() async {
        _ = NSApplication.shared
        let thumbnail = RecordingThumbnail(actions: RecordingActions())
        thumbnail.setBusy("Сжатие 720p…", for: movie)
        thumbnail.setBusy(nil, for: movie)
        await waitUntilShown(thumbnail)
        XCTAssertTrue(thumbnail.isShowing)
        XCTAssertNil(thumbnail.busyMessage)
        thumbnail.hide(animated: false)
    }

    func testHiddenThumbnailDoesNotComeBack() async {
        _ = NSApplication.shared
        let thumbnail = RecordingThumbnail(actions: RecordingActions())
        thumbnail.show(url: movie, above: nil)
        thumbnail.hide(animated: false)
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(thumbnail.isShowing)
        XCTAssertEqual(visibleThumbnailPanels(), 0)
    }
}
