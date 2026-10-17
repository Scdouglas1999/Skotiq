#!/bin/bash
# Copy Rust library to macOS app bundle
# This should be run after building the Flutter macOS app

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Find the app bundle
APP_BUNDLE="$PROJECT_ROOT/apps/desktop/build/macos/Build/Products/Release/skotiq.app"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "App bundle not found at $APP_BUNDLE"
    echo "Please build the macOS app first with: flutter build macos"
    exit 1
fi

# Find the Rust library
RUST_LIB="$PROJECT_ROOT/native/skotiq_native/target/release/libskotiq_bridge.dylib"

# Try different target directories
if [ -f "$PROJECT_ROOT/native/skotiq_native/target/x86_64-apple-darwin/release/libskotiq_bridge.dylib" ]; then
    RUST_LIB="$PROJECT_ROOT/native/skotiq_native/target/x86_64-apple-darwin/release/libskotiq_bridge.dylib"
elif [ -f "$PROJECT_ROOT/native/skotiq_native/target/aarch64-apple-darwin/release/libskotiq_bridge.dylib" ]; then
    RUST_LIB="$PROJECT_ROOT/native/skotiq_native/target/aarch64-apple-darwin/release/libskotiq_bridge.dylib"
fi

if [ ! -f "$RUST_LIB" ]; then
    echo "Rust library not found. Please build it first with:"
    echo "  cd native/skotiq_native && cargo build --release --target x86_64-apple-darwin"
    echo "  or"
    echo "  cd native/skotiq_native && cargo build --release --target aarch64-apple-darwin"
    exit 1
fi

# Create Frameworks directory in app bundle
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

# Copy the library
cp "$RUST_LIB" "$FRAMEWORKS_DIR/"
echo "Copied Rust library to $FRAMEWORKS_DIR"

# Update library install name to use @rpath
install_name_tool -id "@rpath/libskotiq_bridge.dylib" "$FRAMEWORKS_DIR/libskotiq_bridge.dylib" 2>/dev/null || true

echo "Done!"





