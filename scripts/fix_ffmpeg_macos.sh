#!/bin/bash
# fix_ffmpeg_macos.sh - Fix FFmpeg kit libiconv/zlib issues on macOS by bundling dependencies

set -e

echo "🔧 Setting up FFmpeg Kit macOS fix..."

if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ This script is only for macOS."
    exit 1
fi

# Find the package in pub cache
PUB_CACHE_HOME="${PUB_CACHE:-$HOME/.pub-cache}"
PACKAGE_DIR=$(find "$PUB_CACHE_HOME/hosted/pub.dev" -maxdepth 2 -type d -name "ffmpeg_kit_flutter_new_full-*" | head -n 1)

if [ -z "$PACKAGE_DIR" ]; then
    echo "❌ FFmpeg kit package not found in pub cache. Run 'flutter pub get' first."
    exit 1
fi

echo "   Found package at: $PACKAGE_DIR"

# 1. Check for corruption (duplicate links from previous bad fixes)
echo "🔍 Checking for corrupted frameworks..."
NEEDS_RESET=0
if [ -d "$PACKAGE_DIR/macos/Frameworks" ]; then
    for framework in "$PACKAGE_DIR/macos/Frameworks/"*.framework; do
        binary_name=$(basename "$framework" .framework)
        binary="$framework/$binary_name"
        if [ -f "$binary" ]; then
            # Check for duplicate libSystem (from "libSystem" patch)
            if [ "$(otool -L "$binary" | grep -c "/usr/lib/libSystem.B.dylib")" -gt 1 ]; then
                echo "🚨 $binary_name has duplicate libSystem links."
                NEEDS_RESET=1
                break
            fi
            # Check for duplicate FlutterMacOS (from "FlutterMacOS" patch)
            if [ "$(otool -L "$binary" | grep -c "FlutterMacOS")" -gt 1 ]; then
                echo "🚨 $binary_name has duplicate FlutterMacOS links."
                NEEDS_RESET=1
                break
            fi
        fi
    done
fi

if [ "$NEEDS_RESET" -eq 1 ]; then
    echo "🧹 Removing corrupted package..."
    rm -rf "$PACKAGE_DIR"
    echo "⬇️  Running flutter pub get..."
    flutter pub get
    # Re-find package dir
    PACKAGE_DIR=$(find "$PUB_CACHE_HOME/hosted/pub.dev" -maxdepth 2 -type d -name "ffmpeg_kit_flutter_new_full-*" | head -n 1)
    echo "   Package restored at: $PACKAGE_DIR"
fi

# 2. Ensure frameworks exist (download if missing)
if [ ! -d "$PACKAGE_DIR/macos/Frameworks" ]; then
    echo "⬇️  Frameworks not found. Downloading..."
    if [ -f "$PACKAGE_DIR/scripts/setup_macos.sh" ]; then
        pushd "$PACKAGE_DIR/macos" > /dev/null
        chmod +x ../scripts/setup_macos.sh
        ../scripts/setup_macos.sh
        popd > /dev/null
    else
        echo "❌ setup_macos.sh not found in package."
        exit 1
    fi
fi

# 3. Bundle dependencies
LIBS_DIR="$PACKAGE_DIR/macos/libs"
mkdir -p "$LIBS_DIR"

bundle_lib() {
    local lib_path="$1"
    local dest_dir="$2"
    local lib_name=$(basename "$lib_path")
    
    # Skip if already bundled
    if [ -f "$dest_dir/$lib_name" ]; then
        return
    fi
    
    if [ ! -f "$lib_path" ]; then
        echo "⚠️  Warning: Dependency $lib_path not found. Skipping bundle."
        return
    fi

    echo "      Bundling $lib_name..."
    cp "$lib_path" "$dest_dir/"
    chmod +w "$dest_dir/$lib_name"
    
    # Patch the ID of the bundled lib
    install_name_tool -id "@rpath/$lib_name" "$dest_dir/$lib_name"
    
    # Scan for dependencies of this lib
    local deps=$(otool -L "$dest_dir/$lib_name" | grep -E "/opt/homebrew|/usr/local" | awk '{print $1}')
    for dep in $deps; do
        local dep_name=$(basename "$dep")
        # Recursive bundle
        bundle_lib "$dep" "$dest_dir"
        # Patch dependency path in the bundled lib
        install_name_tool -change "$dep" "@rpath/$dep_name" "$dest_dir/$lib_name"
    done
}

echo "📦 Bundling dependencies..."

for framework in "$PACKAGE_DIR/macos/Frameworks/"*.framework; do
    binary_name=$(basename "$framework" .framework)
    binary="$framework/$binary_name"
    
    if [ ! -f "$binary" ]; then
        continue
    fi

    echo "   Processing $binary_name..."
    
    # Find Homebrew/local dependencies
    deps=$(otool -L "$binary" | grep -E "/opt/homebrew|/usr/local" | awk '{print $1}')
    
    for dep in $deps; do
        dep_name=$(basename "$dep")
        bundle_lib "$dep" "$LIBS_DIR"
        
        # Patch the framework to point to the bundled lib
        echo "      Redirecting $dep -> @rpath/$dep_name"
        install_name_tool -change "$dep" "@rpath/$dep_name" "$binary"
    done
done

# 4. Patch Podspec to include bundled libraries
PODSPEC="$PACKAGE_DIR/macos/ffmpeg_kit_flutter_new_full.podspec"
if [ -f "$PODSPEC" ]; then
    if ! grep -q "vendored_libraries" "$PODSPEC"; then
        echo "📝 Patching podspec to include bundled libs..."
        # Insert vendored_libraries after vendored_frameworks line
        # We use a safe sed pattern
        sed -i '' '/vendored_frameworks/a\
    ss.osx.vendored_libraries = "libs/*.dylib"' "$PODSPEC"
    else
        echo "✅ Podspec already patched."
    fi
else
    echo "⚠️  Podspec not found at $PODSPEC"
fi

echo "✅ Fix script completed."
