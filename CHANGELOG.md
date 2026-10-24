<img src="docs/icon.png" width="112" height="112" align="left" alt="Rec icon">

<h1>Rec changelog</h1>

What changed in every release, and how it was done.<br>
<a href="README.md">← Back to README</a>

<br clear="left">

---

## 🏷️ 1.1 · 24 October 2026

<a href="https://github.com/Chikurov/rec-macos-screen-recorder/releases/tag/v1.1"><img src="https://img.shields.io/badge/Download-1.1-EF4560?logo=apple&logoColor=white" alt="Download Rec 1.1" align="top"></a> Build 19 · macOS 14+, Apple Silicon and Intel · [Pull request #1](https://github.com/Chikurov/rec-macos-screen-recorder/pull/1)

### ✨ What changed

**After recording**
- A thumbnail appears above the bar, like a screenshot in macOS. It replaces the separate result window from 1.0.
- Click the thumbnail to watch the recording in Quick Look, or drag it into Telegram, Mail or Finder.
- Its action strip trims the recording in QuickTime, saves a compressed copy (1080p or 720p, with the size shown before saving), makes a GIF or shows the file in Finder.
- The Dock menu has **Last recording** and **Open recordings folder**.

**While recording**
- **Zoom:** press 🔍 or <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>Z</kbd>, select a fragment, and the video zooms in up to 4×. A light dashed frame on the screen shows what is being recorded.
- In area mode, move the recorded area by its red handle.
- The menu bar shows a red dot and the elapsed time; its menu can pause or stop the recording.
- A level meter under the microphone shows that it hears you.

**The bar**
- Four themes: follow the system, dark, light and brushed metal.
- **Slim bar:** about half the size of the regular one.
- Buttons you do not use can be hidden in Settings. A new 📁 button opens the recordings folder.
- The record button is neutral before recording, so it no longer looks like a recording is already running.
- Menus open under their button and close when you click the button again.
- System audio has a clearer icon: a screen with a sound wave.

**Settings**
- **Quality:** High (full Retina resolution) or Compact (3–4 times smaller files), with the estimated size per minute for your screen.
- The settings window can be resized and scrolls.
- Rec remembers the last display, app or area you recorded.

### 🛠️ How it works

- **Trimming in QuickTime.** macOS does not give third-party apps the Trim button in Quick Look, so Rec does not build its own editor. It opens the recording in QuickTime Player, where trimming is <kbd>⌘</kbd> <kbd>T</kbd>.
- **Compressed copy.** Apple's ready-made export presets target about 8 Mbit/s even for 720p, so a "compressed" copy could be larger than a Compact recording. Rec encodes the copy itself at a fixed bitrate: 5 Mbit/s for 1080p and 2.5 Mbit/s for 720p. A test checks that the file is never larger than the size shown in the menu.
- **Zoom.** ScreenCaptureKit can change the captured rectangle while recording. Rec moves it about 60 times per second with an easing curve: fast start, soft stop. The zoomed area is widened to the video's aspect ratio, otherwise macOS adds black bars. The dashed frame is a Rec window, and Rec's own windows are excluded from the capture, so the frame never appears in the video.
- **Faster saving.** The separate System audio and Microphone tracks are now copied into the MP4 without re-encoding; only the Mix track is encoded. Screen frames are captured in the format the H.264 encoder uses directly (YUV, BT.709), which saves a conversion for every frame.
- **The bar does not jump.** When recording started, the microphone's arrow used to disappear, the bar got narrower and moved under the cursor. Now the arrow stays in place and is only dimmed. Automated tests draw the bar off-screen in every state (before recording, countdown, recording, paused, saving), in every theme, regular and slim, and check that its size never changes.
- **Temporary files.** The raw recording is kept in a temporary folder and removed after saving, after an error and on the next launch after a crash. If the final MP4 cannot be built, the raw recording is kept next to it instead of being lost.

### 🐛 Fixed

- Saving a compressed copy over the recording itself deleted the original. Rec now refuses and asks for another name.
- The thumbnail could stay on screen forever, and the export progress could disappear or spin endlessly.
- Two exports could run at once and confuse the progress indicator. Exports now run one at a time.
- The source menu covered its own button when the bar was near the bottom of the screen. The menu now opens above the bar when there is no room below.
- The settings window was taller than the screen and could not be scrolled.
- The grab cursor on the bar's handle was replaced by the arrow.

All of these have automated tests; the new tests were checked against the old code and fail there. **110 tests** in total.

### ⚠️ Known limitations

> [!WARNING]
> - Rec is not notarized: allow the first launch in System Settings → Privacy & Security → **Open Anyway**.
> - The microphone can be switched on and off during recording, but a different microphone can be chosen only before recording.
> - In single-window mode the webcam bubble is not recorded; macOS captures only that window.
> - If the timer button is hidden, the pause button appears when recording starts and the bar becomes wider.
> - This version has not yet been tried on macOS 26 Tahoe.

---

## 🏷️ 1.0 · 23 October 2026

<a href="https://github.com/Chikurov/rec-macos-screen-recorder/releases/tag/v1.0"><img src="https://img.shields.io/badge/Download-1.0-6E7781?logo=apple&logoColor=white" alt="Download Rec 1.0" align="top"></a> Build 8 · macOS 14+, Apple Silicon and Intel · The first public version.

### ✨ What it could do

- Record a whole display, one app, one window or a selected area.
- Record the microphone and system audio, and switch each on and off during recording.
- A round webcam bubble on the desktop, recorded together with the screen.
- Countdown, pause and shortcuts <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>R</kbd> (record) and <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>P</kbd> (pause).
- An MP4 with a Mix track for players plus separate System audio and Microphone tracks for editing.
- A result window with trimming and Telegram (1080p / 720p) and GIF export.
- No network access and no analytics.

### 🛠️ How it works

- **Microphone on macOS 14.** ScreenCaptureKit can record the microphone only from macOS 15, so Rec records it separately through AVFoundation and lines up its timestamps with the screen.
- **Sound stays in sync.** When a source is switched off and on, the audio encoder packs the remaining sound together and everything after the gap plays early. Rec fills every gap with silence. Tests check the sync after switching sources.
- **Privacy.** The app runs in the App Sandbox without network entitlements, has no third-party libraries and stores recordings in `~/Movies/Rec` or a folder you choose.
- **43 automated tests** cover the audio pipeline, pause timing, exports and helpers.

---

<p align="center">
  ⭐ <b>Free and open source.</b> If Rec helps you, star the repository.<br>
  <sub>
    <a href="README.md">README</a> ·
    <a href="https://github.com/Chikurov/rec-macos-screen-recorder/releases">All releases</a> ·
    <a href="https://github.com/Chikurov/rec-macos-screen-recorder/issues">Report a problem</a> ·
    <a href="LICENSE">MIT License</a>
  </sub>
</p>
