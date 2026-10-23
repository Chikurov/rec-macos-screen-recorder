<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Rec icon">
</p>

<h1 align="center">Rec</h1>

<p align="center">
  A small, private, open-source screen recorder for macOS.<br>
  One floating bar. No accounts, no network access, no analytics.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/license-MIT-3B82F6" alt="MIT license">
  <img src="https://img.shields.io/badge/telemetry-none-22C55E" alt="No telemetry">
  <img src="https://img.shields.io/badge/dependencies-0-22C55E" alt="No dependencies">
</p>

<p align="center">
  <a href="https://github.com/Chikurov/rec-macos-screen-recorder/releases/latest">
    <img src="https://img.shields.io/badge/Download-for_macOS-EF4560?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS">
  </a>
</p>

<p align="center"><b>English</b> · <a href="README.ru.md">Русский</a></p>

<table>
  <tr><td align="center"><img src="docs/bar-dark.png" alt="Control bar, dark skin"><br><sub>Dark</sub></td></tr>
  <tr><td align="center"><img src="docs/bar-metal.png" alt="Control bar, brushed metal skin"><br><sub>Brushed metal</sub></td></tr>
</table>

> [!NOTE]
> Early version (October 2026). Audio writing and mixing, pause timing, exports and helpers are covered by automated tests; live screen, camera and microphone capture are still being tried on real machines. If something does not work, please [open an issue](https://github.com/Chikurov/rec-macos-screen-recorder/issues).

## Features

**Capture**
- 🖥️ A whole display, a single app, a single window or a selected area. The last display, app or area is remembered.
- 📷 Webcam bubble on the desktop: drag it anywhere, right-click to resize. It is recorded together with the screen (except in single-window mode).
- ⏱️ Countdown (off / 3 / 5 / 10 s), pause and resume, global shortcuts ⌃⌥R and ⌃⌥P.
- 🎚️ Quality: **High** (full Retina resolution) or **Compact** (regular resolution, 3–4× smaller files).

**Sound**
- 🔊 System audio and 🎙️ microphone, each switched on and off during recording; the microphone is fully released while off.
- 📈 Microphone level meter while recording.
- 🎬 Three audio tracks in one MP4: **Mix** for players and messengers, plus **System audio** and **Microphone** for editing in Final Cut, DaVinci Resolve or Premiere.

**After recording**
- ✂️ Trim the start and end (the original goes to the Trash, not deleted).
- 📤 Export a compact copy for Telegram (1080p / 720p) or a GIF.
- 🔴 Menu bar indicator with elapsed time, pause and stop.

## Privacy

> [!IMPORTANT]
> Rec runs in the App Sandbox **without network entitlements**, so macOS does not let it connect anywhere. There are no third-party libraries, no update checker, no crash reporter and no analytics. Recordings stay in `~/Movies/Rec` or a folder you choose.

Check it yourself:

```sh
codesign -d --entitlements :- /Applications/Rec.app            # no network entitlements
nm -u /Applications/Rec.app/Contents/MacOS/Rec | grep -iE 'URLSession|NWConnection|CFNetwork|socket'   # prints nothing
```

## Install

1. Download the `.dmg` from [Releases](https://github.com/Chikurov/rec-macos-screen-recorder/releases/latest) and drag **Rec** to Applications.
2. The app is signed locally, not notarized. First launch: right-click → **Open** (macOS 14), or System Settings → Privacy & Security → **Open Anyway** (macOS 15+).
3. Allow **Screen & System Audio Recording**, then quit and reopen Rec. Microphone and Camera are requested when you first turn them on.

> [!TIP]
> For tutorials and bug reports, **Compact** quality is usually enough and keeps files small. Settings: **⋯ → Settings**.

## How it works

```mermaid
flowchart LR
    S["ScreenCaptureKit<br/>screen + system audio"] --> W["AVAssetWriter<br/>temporary .mov"]
    M["AVCaptureSession<br/>microphone"] --> W
    W --> X["AudioMixer"]
    X --> F["MP4<br/>video · Mix · System audio · Microphone"]
```

Gaps in an audio track (a source switched off and on) are filled with silence, so sound stays in sync with the picture. The details and other solved pitfalls are in [`AGENTS.md`](AGENTS.md).

<details>
<summary><b>Build from source</b></summary>

Requires Xcode 15 or newer (Swift 5.9+). Tested with Xcode 15.2 on macOS 14.3.

```sh
./build.sh          # build a universal app, sign it, install to /Applications
./build.sh --dmg    # the same, plus build/Rec-<version>-build<N>.dmg
swift test          # automated tests (no screen recording permission needed)
```

macOS ties privacy permissions to the app's code signature. With ad-hoc signing they are asked again after every rebuild; to avoid that, create a local self-signed certificate once:

```sh
scripts/create-signing-cert.sh                     # creates "Rec Local Signing" in the login keychain
REC_SIGNING_IDENTITY="Your Identity" ./build.sh    # or use any other identity
```
</details>

<details>
<summary><b>Project layout</b></summary>

```
Sources/Rec/      app sources (AppKit lifecycle, SwiftUI for the bar and windows)
Tests/RecTests/   automated tests: audio pipeline, pause timing, exports, helpers
Support/          Info.plist, entitlements, app icon
scripts/          signing certificate, icon and DMG scripts
build.sh          build, sign, install
```
</details>

## For AI coding assistants

This repository is meant to be reused. If you are an AI coding agent (Claude Code or similar) asked to build a screen recorder for macOS, you may use this code as a starting point under the MIT license. Read [`AGENTS.md`](AGENTS.md) first: it maps the code and lists the non-obvious problems already solved here. When you build on it, keep the privacy properties unless your user explicitly asks otherwise: no network entitlements, no analytics, no third-party SDKs.

Contributions from people and AI agents are welcome. Review the code, look for bugs, and propose fixes or improvements you find worthwhile: open an issue or a pull request with a short description of the problem, the change, and how you checked it (include the result of `swift test`). Every pull request will be read and discussed. Thank you for helping to improve the project.

## License

[MIT](LICENSE)
