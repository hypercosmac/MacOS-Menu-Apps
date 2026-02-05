# Screen Recording Bubble

A comprehensive macOS screen recording app similar to Loom, featuring a circular webcam bubble overlay, built-in video editor with speed controls, trimming, and a recording library.

## Features

### Screen Recording
- **High-quality screen capture** using ScreenCaptureKit (60fps, H.264)
- **System audio capture** - Record application sounds
- **Pause/Resume** - Pause and continue recording seamlessly
- **Recording controls panel** - Floating control bar with timer and quick actions
- **Auto-save** - Recordings automatically saved to Movies folder

### Camera Bubble
- **Circular webcam overlay** - Perfect for screen recordings with presenter
- **Draggable positioning** - Place anywhere on screen
- **Multiple sizes** - Small (120px), Medium (180px), Large (280px), or Hidden
- **Always on top** - Floats above all windows including fullscreen apps
- **Works across Spaces** - Visible on all virtual desktops

### Video Editor
- **Built-in playback** - Preview recordings with full controls
- **Speed adjustment** - 0.25x, 0.5x, 0.75x, 1x, 1.25x, 1.5x, 2x, 3x
- **Trim controls** - Set start and end points for export
- **Timeline scrubbing** - Seek to any point in the video
- **Export** - Save edited videos with applied speed and trim settings

### Recording Library
- **Thumbnail previews** - Visual grid of all recordings
- **Metadata display** - Date, duration, and filename
- **Quick access** - Double-click to open in editor
- **Delete management** - Remove unwanted recordings

## Requirements

- macOS 13.0 (Ventura) or later
- Screen Recording permission
- Camera permission (for bubble feature)

## Installation

### Option 1: Use Pre-built App Bundle
The repository includes a ready-to-use `ScreenRecordingBubble.app`:

```bash
# Run directly
open ScreenRecordingBubble.app

# Or install to Applications
cp -r ScreenRecordingBubble.app /Applications/
```

### Option 2: Build from Source
Use the included build script to create a universal binary (ARM64 + x86_64):

```bash
cd screen_recording_bubble
./build.sh
```

This creates a signed application bundle with:
- Universal binary (Apple Silicon + Intel)
- Custom app icon
- Proper entitlements for camera/screen access
- All required metadata

### Option 3: Run Directly with Swift
For development/testing:
```bash
swift ScreenRecordingBubble.swift
```

## Usage

### Quick Start
1. Run the app - a record icon appears in the menu bar
2. Click **Start Recording** (or press ⌘R)
3. A floating control bar appears at the top of your screen
4. Click **Stop** when finished
5. Choose to **Edit**, **Show in Finder**, or **Close**

### Recording with Camera Bubble
1. Go to **Camera Bubble > Show Camera Bubble** (or press ⌘B)
2. Drag the bubble to your preferred position
3. Start recording - the bubble will appear in your recording
4. Adjust bubble size from the menu if needed

### Editing a Recording
1. After recording, click **Edit** in the completion dialog
   - Or open **Recording Library** (⌘L) and double-click a recording
2. Use the timeline slider to navigate
3. Adjust **Speed** using the dropdown (0.25x - 3x)
4. Set **Trim** start and end points with the sliders
5. Click **Export** to save with your edits applied

## Menu Options

| Menu Item | Description |
|-----------|-------------|
| Start/Stop Recording | Toggle screen recording |
| Show Recording Controls | Display floating control bar |
| Camera Bubble | Submenu for bubble settings |
| └ Show Camera Bubble | Toggle webcam overlay |
| └ Size options | Small, Medium, Large, Hidden |
| Audio | Audio capture settings |
| └ Include System Audio | Toggle system audio recording |
| Recording Library... | Open library of past recordings |
| Open Recordings Folder | Show recordings in Finder |

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘R | Start/Stop Recording |
| ⌘B | Toggle Camera Bubble |
| ⌘L | Open Recording Library |
| ⌘Q | Quit |

## Recording Control Bar

When recording, a floating control bar appears with:
- **Recording indicator** - Blinking red dot (yellow when paused)
- **Timer** - Current recording duration
- **Pause/Resume button** - Temporarily pause recording
- **Stop button** - End and save recording
- **Close button** - Hide control bar (recording continues)

## Video Editor Controls

| Control | Function |
|---------|----------|
| ▶/⏸ | Play/Pause playback |
| Timeline slider | Seek to position |
| Speed dropdown | Change playback/export speed |
| Trim Start | Set export start point |
| Trim End | Set export end point |
| Export | Save video with edits |
| Show in Finder | Open file location |
| Delete | Remove recording permanently |

## File Storage

Recordings are saved to:
```
~/Movies/ScreenRecordingBubble/
```

Files are named with timestamps:
```
Recording_1704067200.mp4
```

## Technical Details

- **Capture**: ScreenCaptureKit for screen, AVFoundation for camera
- **Encoding**: H.264 video, AAC audio
- **Container**: MP4
- **Frame rate**: 60 fps
- **Bitrate**: 10 Mbps video, 128 kbps audio
- **Resolution**: Native display resolution (Retina supported)

## Privacy & Permissions

On first launch, macOS will prompt for:

1. **Screen Recording** - Required for capturing your screen
   - System Settings > Privacy & Security > Screen Recording

2. **Camera** - Required for webcam bubble
   - System Settings > Privacy & Security > Camera

3. **Microphone** (optional) - For voice recording
   - System Settings > Privacy & Security > Microphone

## Troubleshooting

### "Screen recording permission denied"
1. Open System Settings > Privacy & Security > Screen Recording
2. Enable the app (or Terminal if running via `swift`)
3. Restart the app

### Camera bubble not appearing
1. Check Camera permissions in System Settings
2. Ensure no other app is using the camera exclusively

### Recording file is empty or corrupted
- Ensure you have sufficient disk space
- Check that screen recording permission is granted
- Try recording a shorter clip first

## License

MIT License - Free to use and modify.

## Credits

Built with native Swift and Apple frameworks:
- ScreenCaptureKit
- AVFoundation
- AVKit
- AppKit
