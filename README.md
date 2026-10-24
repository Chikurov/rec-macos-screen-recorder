<img src="docs/icon.png" width="144" height="144" align="left" alt="Rec icon">

<h1>Rec <a href="https://github.com/Chikurov/rec-macos-screen-recorder/releases/latest"><img align="right" src="https://img.shields.io/badge/Download_for_macOS-EF4560?logo=apple&logoColor=white" alt="Download for macOS"></a></h1>

A private, open-source screen recorder for macOS.<br>
Use it as is, or as a base for your own.

<br clear="left">

<p><img src="docs/bar.png" width="100%" alt="The Rec control bar on the desktop"></p>

- **Record** — a screen, an app, a window or an area, with microphone, system audio and camera. Zoom in while recording.
- **Share** — after each recording, a preview pops up: open it, drag it into a chat, trim it, compress it or save it as a GIF.
- **Make it yours** — four themes, a slim bar, your own buttons and shortcuts.
- **Private** — no accounts, no tracking, no analytics and no internet access. Recordings and settings stay on your Mac.

## Install

Requires macOS 14 or later.

1. Download the `.dmg` from [Releases](https://github.com/Chikurov/rec-macos-screen-recorder/releases/latest) and drag **Rec** to Applications.
2. Open Rec once, then allow it in System Settings → Privacy & Security → **Open Anyway**. Rec is not notarized yet.
3. Allow **Screen & System Audio Recording** and reopen Rec.

## Build on it

18 Swift files, about 4,600 lines, no dependencies. Xcode 15 or later.

```sh
./build.sh          # build and install
./build.sh --dmg    # the same, plus a .dmg
swift test          # 110 tests
```

[`AGENTS.md`](AGENTS.md) maps the code and the 19 problems already solved.

To verify the privacy, run `codesign -d --entitlements :- /Applications/Rec.app`: there is no network entitlement.

---

<p align="center">
  ⭐ <b>Free and open source.</b> If Rec helps you, star the repository.<br>
  <sub>
    <b>Rec 1.1</b> · <a href="CHANGELOG.md">What's new</a> ·
    <a href="https://github.com/Chikurov/rec-macos-screen-recorder/issues">Report a problem</a> ·
    <a href="LICENSE">MIT License</a>
  </sub>
</p>
