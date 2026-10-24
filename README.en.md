<div align="center">

[简体中文](README.md) · **English**

# SnapLex

### Capture, annotate, pin, and translate — in one native macOS app

A native macOS productivity app that turns on-screen content into information you can edit, revisit, and use.

[Features](#features) · [Install and run](#install-and-run) · [Permissions](#permissions) · [Privacy](#privacy) · [Contributing](#contributing)

[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-111111?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&logoColor=white)](https://swift.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

SnapLex brings screen capture and language tools together in a native macOS app. Capture and annotate your screen, keep a reference pinned on the desktop, record a walkthrough, or select unfamiliar text to translate it. Translation history, word frequency, and saved screenshots are managed from the app’s home page.

## Features

### Capture and annotate

- Capture a region with window detection, selection adjustment, a color picker, magnifier, and annotation tools.
- Draw shapes, arrows, and freehand marks; add mosaics, blur, numbered markers, and text. Annotations can be moved, resized, and rotated after placement.
- Use Apple Vision to remove a background or blur it, recognize text, and scan QR codes and barcodes.
- Stitch scrolling screenshots as you scroll, then edit, copy, or pin the result.

### Desktop pins and screen recording

- Pin screenshots, clipboard images, or text on the desktop for reference. Adjust scale and opacity or enable click-through.
- Record a region, window, or full display with ScreenCaptureKit; export MP4 or GIF.
- Browse recent screenshots in history and configure how many are kept.

### Selection translation and study history

- Select text in another app to show the translation bar, or trigger translation with a shortcut.
- Choose Google Translate or Apple Translation provided by macOS.
- Look up definitions with the macOS system dictionary and speak the original English word aloud.
- Collect selection and screenshot translations, review trends and word frequency by date, revisit context, and exclude words from frequency counts.

### Preferences

- The interface supports Simplified Chinese, Traditional Chinese, English, Japanese, Korean, French, and German.
- Customize global shortcuts, launch at login, and choose separately which translation types are saved.
- Check GitHub Releases for the latest stable version and read its release notes in the app.

## Install and run

### Download

When a stable version is available, download the macOS package from [GitHub Releases](https://github.com/BothSavage/SnapLex/releases/latest).

### Build from source

Requires macOS 15 or later and Swift 5.10+. Install Xcode Command Line Tools, then run:

```bash
git clone https://github.com/BothSavage/SnapLex.git
cd SnapLex
./scripts/build_app.sh
open ./dist/SnapLex.app
```

## Permissions

SnapLex requests macOS permissions when you first use the related feature:

- **Screen Recording** for screenshots, scrolling capture, and screen recording.
- **Accessibility** for cross-app text selection and some global shortcuts.
- **Microphone** only when microphone audio is enabled for a recording.

## Privacy

Screenshots, screenshot history, and translation history are stored locally. If Google Translate is selected, text to be translated is sent to Google. If Apple Translation is selected, macOS handles it with its Translation framework. SnapLex does not upload this content to its own servers. You can turn off automatic selection-translation and screenshot-translation history separately in Preferences.

## Contributing

Bug reports and improvement suggestions are welcome. See [RELEASING.md](RELEASING.md) for the release workflow and the GitHub Actions configuration required for signing and notarization.

## License

SnapLex is available under the [MIT License](LICENSE).
