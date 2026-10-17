#!/bin/bash
# Build script for Skotiq native Rust library
# Builds for Windows, Linux, and macOS (when run on respective platforms)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NATIVE_DIR="$PROJECT_ROOT/native/skotiq_native"

cd "$NATIVE_DIR"

echo "Building Skotiq native library..."
echo "Project root: $PROJECT_ROOT"
echo "Native dir: $NATIVE_DIR"

# Detect platform
PLATFORM="$(uname -s)"
ARCH="$(uname -m)"

echo "Platform: $PLATFORM"
echo "Architecture: $ARCH"

# Build for current platform
if [[ "$PLATFORM" == "Linux" ]]; then
    echo "Building for Linux..."
    
    # Detect ARM architecture for Raspberry Pi
    if [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
        echo "Detected ARM64 architecture (Raspberry Pi)"
        # Install cross-compilation target if needed
        rustup target add aarch64-unknown-linux-gnu 2>/dev/null || true
        cargo build --release --target aarch64-unknown-linux-gnu --manifest-path bridge/Cargo.toml
        LIB_NAME="libskotiq_bridge.so"
        TARGET_DIR="$PROJECT_ROOT/apps/desktop/build/linux/arm64/release/bundle/lib"
        mkdir -p "$TARGET_DIR"
        cp "target/aarch64-unknown-linux-gnu/release/$LIB_NAME" "$TARGET_DIR/"
        echo "Copied $LIB_NAME to $TARGET_DIR"
    elif [[ "$ARCH" == "armv7l" ]] || [[ "$ARCH" == "arm" ]]; then
        echo "Detected ARMv7 architecture (Raspberry Pi)"
        # Install cross-compilation target if needed
        rustup target add armv7-unknown-linux-gnueabihf 2>/dev/null || true
        cargo build --release --target armv7-unknown-linux-gnueabihf --manifest-path bridge/Cargo.toml
        LIB_NAME="libskotiq_bridge.so"
        TARGET_DIR="$PROJECT_ROOT/apps/desktop/build/linux/arm64/release/bundle/lib"
        mkdir -p "$TARGET_DIR"
        cp "target/armv7-unknown-linux-gnueabihf/release/$LIB_NAME" "$TARGET_DIR/"
        echo "Copied $LIB_NAME to $TARGET_DIR"
    else
        # x86_64 or other
        cargo build --release --manifest-path bridge/Cargo.toml
        LIB_NAME="libskotiq_bridge.so"
        TARGET_DIR="$PROJECT_ROOT/apps/desktop/build/linux/x64/release/bundle/lib"
        mkdir -p "$TARGET_DIR"
        cp "target/release/$LIB_NAME" "$TARGET_DIR/"
        echo "Copied $LIB_NAME to $TARGET_DIR"
    fi
    
elif [[ "$PLATFORM" == "Darwin" ]]; then
    echo "Building for macOS..."
    
    # Build for Intel Mac
    if [[ "$ARCH" == "x86_64" ]]; then
        cargo build --release --target x86_64-apple-darwin --manifest-path bridge/Cargo.toml
        LIB_NAME="libskotiq_bridge.dylib"
        TARGET_DIR="$PROJECT_ROOT/apps/desktop/build/macos/Build/Products/Release/skotiq.app/Contents/Frameworks"
        mkdir -p "$TARGET_DIR"
        cp "target/x86_64-apple-darwin/release/$LIB_NAME" "$TARGET_DIR/"
        echo "Copied $LIB_NAME to $TARGET_DIR"
    fi
    
    # Build for Apple Silicon
    if [[ "$ARCH" == "arm64" ]] || [[ "$ARCH" == "aarch64" ]]; then
        cargo build --release --target aarch64-apple-darwin --manifest-path bridge/Cargo.toml
        LIB_NAME="libskotiq_bridge.dylib"
        TARGET_DIR="$PROJECT_ROOT/apps/desktop/build/macos/Build/Products/Release/skotiq.app/Contents/Frameworks"
        mkdir -p "$TARGET_DIR"
        cp "target/aarch64-apple-darwin/release/$LIB_NAME" "$TARGET_DIR/"
        echo "Copied $LIB_NAME to $TARGET_DIR"
    fi
    
elif [[ "$PLATFORM" == MINGW* ]] || [[ "$PLATFORM" == MSYS* ]] || [[ "$PLATFORM" == CYGWIN* ]]; then
    echo "Building for Windows..."
    cargo build --release --manifest-path bridge/Cargo.toml
    
    # Copy to Flutter app directory
    LIB_NAME="skotiq_bridge.dll"
    TARGET_DIR="$PROJECT_ROOT/apps/desktop/build/windows/x64/runner/Release"
    mkdir -p "$TARGET_DIR"
    cp "target/release/$LIB_NAME" "$TARGET_DIR/"
    echo "Copied $LIB_NAME to $TARGET_DIR"
else
    echo "Unknown platform: $PLATFORM"
    exit 1
fi

echo "Build complete!"



