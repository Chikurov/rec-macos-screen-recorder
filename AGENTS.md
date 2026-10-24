# AGENTS.md — guide for AI coding agents

Rec is a macOS screen recorder (macOS 14+, Swift 5.9, ScreenCaptureKit + AVFoundation). You may reuse it as a base for your own screen recorder (MIT license). This file explains how it is built and which problems were already solved, so you do not have to rediscover them.

## Ground rules of this project

- **No network.** The app is sandboxed without network entitlements and contains no networking code, analytics, update checks or third-party SDKs. Keep it that way unless your user explicitly asks otherwise, and say so in your README if you change it.
- **No third-party dependencies.** Only Apple frameworks.
- UI strings are in Russian. Code comments are kept to the strictly necessary minimum.
- Builds with Xcode 15.2 / Swift 5.9 and the macOS 14 SDK. Do not use APIs newer than macOS 14 without `#available` checks, and remember that the Swift 5.9 compiler does not know macOS 15+ SDK symbols at all.

## Build and check

```sh
./build.sh [--dmg]        # swift build (universal), assemble Rec.app, codesign, install to /Applications
swift test                # XCTest suite, needs no Screen Recording permission
```

There is no `.xcodeproj`: `Package.swift` builds the executable, `build.sh` assembles the bundle from `Support/` (Info.plist, entitlements, icon) and signs it. The signing identity is taken from `REC_SIGNING_IDENTITY`, then a local "Rec Local Signing" certificate (`scripts/create-signing-cert.sh`), then ad-hoc.

## Tests

`Tests/RecTests` covers the audio pipeline (gap filling, mixing, track flags and titles, sync after toggling sources, copying tracks without re-encoding), pause timing, sample buffer retiming, microphone level, compressed copy and GIF export (including the guard against overwriting the original and one export at a time), the post-recording thumbnail, output naming, capture geometry and quality, remembered sources, temporary file cleanup, hot keys and skins. `InterfaceTests` render the control bar offscreen and check that its size does not change between idle, countdown, recording, paused and saving (in every skin, regular and slim), that the settings window fits a 400 pt high window and scrolls, menu anchoring and toggle-close, bar resizing, persisted setting names and record button contrast. `RecorderController.setPhaseForTesting` exists only in debug builds for these tests. The audio tests were checked against deliberately broken code: they fail when gap filling or mixing is removed.

Real capture cannot be tested headlessly: it needs the Screen Recording permission for the built app. Diagnostics go to the unified log: `/usr/bin/log show --last 10m --predicate 'subsystem == "com.chikurov.Rec"'` (in zsh, plain `log` is a shell builtin).

## Code map

| File | Role |
|---|---|
| `main.swift` | AppKit entry point. No SwiftUI `App`/`Settings` scene on purpose (see pitfalls). |
| `AppDelegate.swift` | Main menu, floating control panel, Dock menu, settings window, quit-while-recording. |
| `ControlBar.swift` | SwiftUI control bar, record button / Stop capsule, regular and slim sizes (`BarMetrics`). |
| `BarTheme.swift` | Skins (follow system, dark, light, brushed metal), theme environment, first-click hosting view. |
| `RecorderController.swift` | State machine (idle → countdown → recording ⇄ paused → saving), menus, permissions, builds `SCContentFilter` for each source. |
| `RecordingEngine.swift` | `SCStream` video + system audio, `AVCaptureSession` microphone, `AVAssetWriter`, pause, retiming. |
| `PauseTimeline.swift` | Pause/resume bookkeeping: which buffers to drop and how to shift timestamps. |
| `AudioTrackWriter.swift` | Appends audio and fills gaps with silence. |
| `AudioMixer.swift` | Post-processing: temporary `.mov` → final `.mp4` with Mix + separate tracks. |
| `CaptureSource.swift` | Displays / apps / windows / area, device lists. |
| `CameraBubble.swift` | Round webcam window on the desktop. |
| `OverlayWindows.swift` | Countdown, area selection, area border with move handle, zoom frame, `NSMenu` helpers and `MenuAnchor` (menus open under their button, a second click closes them). |
| `RecordingExports.swift` | Compressed copy (own bitrate, not AVAssetExportSession presets), GIF, file naming. |
| `RecordingActions.swift` | Quick Look preview, open in QuickTime for trimming, Finder, export with save panels and progress. |
| `RecordingThumbnail.swift` | Post-recording thumbnail above the bar with an action strip: click previews, drag exports the file. |
| `SettingsView.swift` | Settings window: skin tiles, slim bar, optional buttons, quality cards with size estimates, folder, hot keys. |
| `HotKeys.swift` | Global shortcuts via Carbon `RegisterEventHotKey` plus a SwiftUI recorder. |
| `AppSettings.swift` | `UserDefaults`-backed settings, security-scoped bookmark for a custom folder. |

## Pitfalls already solved

1. **Microphone on macOS 14.** `SCStream` can capture the microphone only from macOS 15. Here the microphone uses `AVCaptureSession` + `AVCaptureAudioDataOutput`. Its timestamps are on the session's `synchronizationClock`; convert them to the host clock with `CMSyncConvertTime` so they line up with `SCStream` buffers.
2. **AAC tracks collapse gaps.** If you stop appending audio (mic turned off, system audio muted) and resume later, `AVAssetWriter` packs the samples back to back, and everything after the gap plays early. `AudioTrackWriter` inserts silence for every gap. `AudioPipelineTests` verifies this.
3. **Players play only the first audio track.** With mic + system audio, the final file has an enabled "Mix" track (made with `AVAssetReaderAudioMixOutput`) and two disabled per-source tracks for editors. Only the mix is re-encoded; per-source tracks are copied as is, which is safe because gaps are already filled. Titles are written as track metadata.
4. **Static screens shorten the video.** `SCStream` delivers only `.idle` frames when nothing changes, so the last appended frame may be far before the stop time. On stop, the last frame is appended again at the stop time before `endSession`.
5. **`CMTime.invalid` compares greater than every valid time.** Use `.negativeInfinity` as the initial "last time", or the first frame is never written.
6. **Pause** drops buffers and shifts later timestamps by the total paused duration. Buffers that arrive late from before the resume are dropped too, so timestamps stay monotonic.
7. **Encoder limits and load.** Output size is capped at 3840 px on the long side and rounded to even numbers. Frames are captured as 420v YUV with the BT.709 matrix, the format the H.264 encoder consumes, to avoid a per-frame conversion. "Compact" quality records at point size instead of Retina pixels.
8. **Webcam in the recording.** The bubble is an app window; the display filter excludes the app but adds the bubble via `exceptingWindows`. Reuse the same window when the camera is toggled so its `CGWindowID` stays in the filter. A `desktopIndependentWindow` (single window) capture cannot include it.
9. **Floating panel clicks.** The control panel is a non-activating `NSPanel` that never becomes key, and its hosting view accepts the first mouse. Otherwise the first click only activates the panel, and macOS may show the input-source (keyboard layout) indicator over it.
10. **SwiftUI `Settings` scene.** In an app whose only SwiftUI scene is `Settings`, macOS can open that window by itself on launch or Dock click, and it may come back through window restoration. This project uses a plain AppKit lifecycle and disables window restoration.
11. **Swift 5.9 top-level code is not `@MainActor`.** `main.swift` wraps startup in `MainActor.assumeIsolated`.
12. **Permissions.** Screen Recording takes effect only after the app restarts. macOS ties permissions to the code signature, so use a stable (self-signed) identity during development.
13. **Sandbox file access.** `assets.movies.read-write` for `~/Movies`, a security-scoped bookmark for a user-chosen folder, save panels for exports.
    Third-party apps cannot get the Quick Look "Trim" button (QuickLookUI has no editing API on macOS), so trimming is delegated to QuickTime Player.
14. **Live source changes.** Zoom and moving the area use `SCStream.updateConfiguration` with a new `sourceRect`; updates are coalesced so at most one is in flight. Zoom targets are expanded to the output aspect ratio, otherwise ScreenCaptureKit letterboxes.
15. **Export presets are not small.** `AVAssetExportPreset1280x720` targets roughly 8 Mbit/s, which can exceed a compact recording. Compressed copies use `AVAssetWriter` with an explicit bitrate instead.
16. **Temporary recordings.** The raw `.mov` lives in the sandbox temp folder with the `Rec-recording-` prefix; it is removed after saving, on failure, and on the next launch after a crash. If the final MP4 cannot be built, the raw recording is kept next to it as `.mov` instead of being lost.
17. **Exports never touch the original.** A save panel lets the user pick the recording itself and confirm "Replace"; deleting the target first would destroy the source. `RecordingExports.isSameFile` (path, symlinks and file identity) guards this, and only one export runs at a time.
18. **The bar must not change size.** Anything that appears or disappears when recording starts moves the bar under the cursor. Keep controls in place and disable them instead; `InterfaceTests` render the bar in every phase and compare sizes.
19. **Scripts.** The `swift` interpreter may fail to link AppKit; compile helper scripts with `swiftc` (see `scripts/make-icon.sh`).

## Contributing

You are welcome to review this code, find bugs and propose improvements. Open an issue or a pull request and describe:

- the problem (what happens, on which macOS version, how to reproduce);
- the change and why it fixes the problem;
- how you verified it: `./build.sh` succeeds and `swift test` passes.

Keep pull requests focused, follow the ground rules above, and do not add network access, analytics or third-party dependencies. Every pull request will be read and discussed. Thank you for helping to improve the project.

## If you fork this

- Change `CFBundleIdentifier` in `Support/Info.plist`, the `Logger` subsystem strings, and the hot key signature in `HotKeys.swift`.
- Keep `swift test` passing. Pure logic lives in small types or `nonisolated static` helpers (`PauseTimeline`, `RecorderController.encodableSize`, `captureArea`, `RecordingExports.uniqueURL`, `AppDelegate.barFrame`) so it can be tested without screen access.
