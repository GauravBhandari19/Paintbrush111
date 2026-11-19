# MiniPaint

A simple, Paintbrush-style bitmap painting app for macOS, built with SwiftUI and AppKit.

## Features

- **Tools:** pencil, brush, spray can, eraser, line, rectangle, oval, paint bucket, eyedropper, text
- **Shapes:** hold ⇧ for straight 45° lines, squares and circles; optional fill color
- **Colors:** stroke/fill pickers, swap button, swatch palette
- **Paste:** paste screenshots or images from the clipboard (⌘V), drag them into place, press Return to place
- **Undo/redo:** 30 levels
- **Files:** New (custom size), Open image, Save as PNG/JPEG, copy canvas to clipboard

## Requirements

- macOS 13 or later
- Xcode 15 or later

## Build

1. Open `MiniPaint.xcodeproj` in Xcode.
2. In **Signing & Capabilities**, choose your own Team.
3. Under **App Sandbox → File Access**, set **User Selected File** to **Read/Write**.
4. Press **⌘R**.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| New / Open / Save | ⌘N / ⌘O / ⌘S |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Paste image | ⌘V |
| Copy canvas | ⇧⌘C |

## License

