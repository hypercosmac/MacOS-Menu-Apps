#!/bin/bash

# Build script for Screen Recording Bubble
# Creates a universal macOS application bundle

set -e

APP_NAME="ScreenRecordingBubble"
BUNDLE_NAME="$APP_NAME.app"
BUNDLE_ID="com.screenrecordingbubble.app"
VERSION="1.0.0"
MIN_MACOS="13.0"

echo "========================================="
echo "Building $APP_NAME v$VERSION"
echo "========================================="

# Clean previous build
echo "Cleaning previous build..."
rm -rf "$BUNDLE_NAME"
rm -f "${APP_NAME}_arm64" "${APP_NAME}_x86_64"

# Create bundle structure
echo "Creating bundle structure..."
mkdir -p "$BUNDLE_NAME/Contents/MacOS"
mkdir -p "$BUNDLE_NAME/Contents/Resources"

# Copy Info.plist (create if it doesn't exist)
if [ -f "Info.plist" ]; then
    cp Info.plist "$BUNDLE_NAME/Contents/"
else
    cat > "$BUNDLE_NAME/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Screen Recording Bubble</string>
    <key>CFBundleDisplayName</key>
    <string>Screen Recording Bubble</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>Screen Recording Bubble needs camera access to show your webcam in the bubble overlay during screen recordings.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Screen Recording Bubble needs microphone access to record audio narration with your screen recordings.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Screen Recording Bubble needs screen recording permission to capture your screen.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF
fi

# Generate app icon if script exists
if [ -f "generate_icon.swift" ]; then
    echo "Generating app icons..."
    mkdir -p "$BUNDLE_NAME/Contents/Resources/AppIcon.iconset"
    swift generate_icon.swift 2>/dev/null || true

    if [ -d "$BUNDLE_NAME/Contents/Resources/AppIcon.iconset" ] && [ "$(ls -A $BUNDLE_NAME/Contents/Resources/AppIcon.iconset)" ]; then
        iconutil -c icns "$BUNDLE_NAME/Contents/Resources/AppIcon.iconset" -o "$BUNDLE_NAME/Contents/Resources/AppIcon.icns" 2>/dev/null || true
        rm -rf "$BUNDLE_NAME/Contents/Resources/AppIcon.iconset"
    fi
fi

# Compile for ARM64
echo "Compiling for ARM64 (Apple Silicon)..."
swiftc -O -whole-module-optimization \
    -target arm64-apple-macos$MIN_MACOS \
    -o "${APP_NAME}_arm64" \
    "$APP_NAME.swift" 2>&1 | grep -v "warning:" || true

# Compile for x86_64
echo "Compiling for x86_64 (Intel)..."
swiftc -O -whole-module-optimization \
    -target x86_64-apple-macos$MIN_MACOS \
    -o "${APP_NAME}_x86_64" \
    "$APP_NAME.swift" 2>&1 | grep -v "warning:" || true

# Create universal binary
echo "Creating universal binary..."
lipo -create "${APP_NAME}_arm64" "${APP_NAME}_x86_64" \
    -output "$BUNDLE_NAME/Contents/MacOS/$APP_NAME"

# Clean up intermediate files
rm -f "${APP_NAME}_arm64" "${APP_NAME}_x86_64"

# Create entitlements if not exists
if [ ! -f "$APP_NAME.entitlements" ]; then
    cat > "$APP_NAME.entitlements" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.camera</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.files.downloads.read-write</key>
    <true/>
</dict>
</plist>
EOF
fi

# Code sign the application
echo "Code signing application..."
codesign --force --deep --sign - \
    --entitlements "$APP_NAME.entitlements" \
    "$BUNDLE_NAME"

# Verify the build
echo ""
echo "========================================="
echo "Build complete!"
echo "========================================="
echo ""

# Show app info
echo "Application: $BUNDLE_NAME"
echo "Location: $(pwd)/$BUNDLE_NAME"
echo ""

# Verify architecture
echo "Architecture support:"
lipo -info "$BUNDLE_NAME/Contents/MacOS/$APP_NAME"
echo ""

# Verify code signature
echo "Code signature:"
codesign -dv "$BUNDLE_NAME" 2>&1 | head -5
echo ""

# Show file size
echo "Bundle size: $(du -sh "$BUNDLE_NAME" | cut -f1)"
echo ""

echo "To run the app:"
echo "  open $BUNDLE_NAME"
echo ""
echo "To install to Applications:"
echo "  cp -r $BUNDLE_NAME /Applications/"
echo ""
