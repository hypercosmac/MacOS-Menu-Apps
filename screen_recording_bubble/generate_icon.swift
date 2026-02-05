#!/usr/bin/env swift

import Cocoa

// Generate app icon for Screen Recording Bubble
// Creates a modern, professional icon with a camera bubble and record indicator

func createIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))

    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let scale = CGFloat(size) / 1024.0

    // Background gradient (dark blue to purple)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1.0),
        NSColor(red: 0.2, green: 0.1, blue: 0.3, alpha: 1.0)
    ])!

    // Rounded rect background
    let cornerRadius = CGFloat(size) * 0.22
    let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: 2 * scale, dy: 2 * scale), xRadius: cornerRadius, yRadius: cornerRadius)
    gradient.draw(in: bgPath, angle: -45)

    // Main bubble circle (camera preview representation)
    let bubbleSize = CGFloat(size) * 0.55
    let bubbleX = (CGFloat(size) - bubbleSize) / 2
    let bubbleY = (CGFloat(size) - bubbleSize) / 2 + CGFloat(size) * 0.05
    let bubbleRect = NSRect(x: bubbleX, y: bubbleY, width: bubbleSize, height: bubbleSize)

    // Bubble gradient (light gray to white - represents camera feed)
    let bubbleGradient = NSGradient(colors: [
        NSColor(white: 0.85, alpha: 1.0),
        NSColor(white: 0.95, alpha: 1.0)
    ])!

    let bubblePath = NSBezierPath(ovalIn: bubbleRect)
    bubbleGradient.draw(in: bubblePath, angle: -45)

    // Bubble border (white glow effect)
    NSColor.white.withAlphaComponent(0.9).setStroke()
    bubblePath.lineWidth = 4 * scale
    bubblePath.stroke()

    // Camera lens icon inside bubble
    let lensSize = bubbleSize * 0.35
    let lensX = bubbleX + (bubbleSize - lensSize) / 2
    let lensY = bubbleY + (bubbleSize - lensSize) / 2
    let lensRect = NSRect(x: lensX, y: lensY, width: lensSize, height: lensSize)

    // Outer lens ring
    NSColor(white: 0.3, alpha: 0.8).setStroke()
    let lensPath = NSBezierPath(ovalIn: lensRect)
    lensPath.lineWidth = 3 * scale
    lensPath.stroke()

    // Inner lens
    let innerLensSize = lensSize * 0.6
    let innerLensX = lensX + (lensSize - innerLensSize) / 2
    let innerLensY = lensY + (lensSize - innerLensSize) / 2
    let innerLensRect = NSRect(x: innerLensX, y: innerLensY, width: innerLensSize, height: innerLensSize)

    NSColor(white: 0.2, alpha: 0.9).setFill()
    NSBezierPath(ovalIn: innerLensRect).fill()

    // Lens highlight
    let highlightSize = innerLensSize * 0.3
    let highlightX = innerLensX + innerLensSize * 0.2
    let highlightY = innerLensY + innerLensSize * 0.5
    let highlightRect = NSRect(x: highlightX, y: highlightY, width: highlightSize, height: highlightSize)

    NSColor.white.withAlphaComponent(0.6).setFill()
    NSBezierPath(ovalIn: highlightRect).fill()

    // Record indicator (red dot in top right)
    let recordSize = CGFloat(size) * 0.18
    let recordX = CGFloat(size) * 0.72
    let recordY = CGFloat(size) * 0.72
    let recordRect = NSRect(x: recordX, y: recordY, width: recordSize, height: recordSize)

    // Red glow behind record button
    let glowRect = recordRect.insetBy(dx: -4 * scale, dy: -4 * scale)
    NSColor.red.withAlphaComponent(0.4).setFill()
    NSBezierPath(ovalIn: glowRect).fill()

    // Record button gradient
    let recordGradient = NSGradient(colors: [
        NSColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1.0),
        NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0)
    ])!

    let recordPath = NSBezierPath(ovalIn: recordRect)
    recordGradient.draw(in: recordPath, angle: -45)

    // Record button highlight
    let recordHighlightSize = recordSize * 0.3
    let recordHighlightX = recordX + recordSize * 0.2
    let recordHighlightY = recordY + recordSize * 0.5
    let recordHighlightRect = NSRect(x: recordHighlightX, y: recordHighlightY, width: recordHighlightSize, height: recordHighlightSize)

    NSColor.white.withAlphaComponent(0.5).setFill()
    NSBezierPath(ovalIn: recordHighlightRect).fill()

    image.unlockFocus()

    return image
}

func saveIcon(image: NSImage, filename: String, size: Int) {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG for \(filename)")
        return
    }

    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("ScreenRecordingBubble.app/Contents/Resources/AppIcon.iconset")
        .appendingPathComponent(filename)

    do {
        try pngData.write(to: url)
        print("Created \(filename)")
    } catch {
        print("Failed to write \(filename): \(error)")
    }
}

// Generate all required icon sizes
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

print("Generating app icons...")

for (filename, size) in sizes {
    let icon = createIcon(size: size)
    saveIcon(image: icon, filename: filename, size: size)
}

print("Done! Now run: iconutil -c icns ScreenRecordingBubble.app/Contents/Resources/AppIcon.iconset")
