#!/bin/bash
# fix_ffmpeg_macos.sh - Post-build script to fix FFmpeg library paths in the final .app bundle
#
# This script patches the final .app bundle AFTER Flutter builds it.
# It ensures all Homebrew dependencies are bundled and patched to use @rpath.
#
# Usage:
#   ./scripts/fix_ffmpeg_macos.sh [path/to/App.app]
#
# If no path is provided, it will look for the app in build/macos/Build/Products/Release/
#
# Compatible with bash 3.x (macOS default)

set -e

echo "🔧 FFmpeg macOS Post-Build Fix"
echo "==============================="

# Find the .app bundle
APP_PATH="$1"
if [ -z "$APP_PATH" ]; then
    # Try to find it in the default Flutter build location
    APP_PATH=$(find build/macos/Build/Products/Release -name "*.app" -type d 2>/dev/null | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Could not find .app bundle"
    echo "   Usage: $0 [path/to/App.app]"
    echo "   Or run 'flutter build macos' first"
    exit 1
fi

echo "   App bundle: $APP_PATH"

# Verify it's a valid .app bundle
if [ ! -d "$APP_PATH/Contents/MacOS" ]; then
    echo "❌ Error: Invalid .app bundle (missing Contents/MacOS)"
    exit 1
fi

# Determine Homebrew prefix
if [ -d "/opt/homebrew" ]; then
    HOMEBREW_PREFIX="/opt/homebrew"
elif [ -d "/usr/local/Homebrew" ]; then
    HOMEBREW_PREFIX="/usr/local"
else
    echo "❌ Error: Homebrew not found"
    exit 1
fi
echo "   Homebrew prefix: $HOMEBREW_PREFIX"

# Setup
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

# Temp file to track processed libraries (bash 3.x compatible)
PROCESSED_FILE=$(mktemp)
HOMEBREW_DEPS_FILE=$(mktemp)
trap "rm -f $PROCESSED_FILE $HOMEBREW_DEPS_FILE" EXIT

# ============================================================================
# Helper Functions
# ============================================================================

# Check if a path is a system library we should NOT bundle
is_system_path() {
    local path="$1"
    case "$path" in
        /System/Library/*) return 0 ;;
        /usr/lib/libSystem*) return 0 ;;
        /usr/lib/libc++*) return 0 ;;
        /usr/lib/libobjc*) return 0 ;;
        /usr/lib/libz.*) return 0 ;;
        /usr/lib/libbz2.*) return 0 ;;
        /usr/lib/liblzma.*) return 0 ;;
        /usr/lib/libresolv.*) return 0 ;;
        /usr/lib/libcharset.*) return 0 ;;
        /usr/lib/libiconv.*) return 0 ;;
        /usr/lib/libexpat.*) return 0 ;;
        /usr/lib/libsqlite3.*) return 0 ;;
        /usr/lib/libxml2.*) return 0 ;;
        /usr/lib/libcurl.*) return 0 ;;
        @rpath/*) return 0 ;;
        @executable_path/*) return 0 ;;
        @loader_path/*) return 0 ;;
    esac
    return 1
}

# Check if a library name has been processed
is_processed() {
    local name="$1"
    grep -q "^$name$" "$PROCESSED_FILE" 2>/dev/null
}

# Mark a library as processed
mark_processed() {
    local name="$1"
    echo "$name" >> "$PROCESSED_FILE"
}

# Find a library in Homebrew
find_in_homebrew() {
    local lib_name="$1"

    # Common Homebrew package locations
    local search_dirs="
        $HOMEBREW_PREFIX/opt/libpng/lib
        $HOMEBREW_PREFIX/opt/fontconfig/lib
        $HOMEBREW_PREFIX/opt/freetype/lib
        $HOMEBREW_PREFIX/opt/fribidi/lib
        $HOMEBREW_PREFIX/opt/harfbuzz/lib
        $HOMEBREW_PREFIX/opt/glib/lib
        $HOMEBREW_PREFIX/opt/graphite2/lib
        $HOMEBREW_PREFIX/opt/libiconv/lib
        $HOMEBREW_PREFIX/opt/openssl@3/lib
        $HOMEBREW_PREFIX/opt/pcre2/lib
        $HOMEBREW_PREFIX/opt/srt/lib
        $HOMEBREW_PREFIX/opt/gettext/lib
        $HOMEBREW_PREFIX/opt/zlib/lib
        $HOMEBREW_PREFIX/opt/expat/lib
        $HOMEBREW_PREFIX/opt/brotli/lib
        $HOMEBREW_PREFIX/opt/bzip2/lib
        $HOMEBREW_PREFIX/opt/xz/lib
        $HOMEBREW_PREFIX/opt/intltool/lib
        $HOMEBREW_PREFIX/lib
    "

    for dir in $search_dirs; do
        if [ -f "$dir/$lib_name" ]; then
            echo "$dir/$lib_name"
            return 0
        fi
    done

    # Broader search
    local found=$(find "$HOMEBREW_PREFIX/opt" -name "$lib_name" -type f 2>/dev/null | head -n 1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

# Get all dependencies of a binary
get_deps() {
    local binary="$1"
    otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}'
}

# ============================================================================
# PASS 1: Collect ALL Homebrew dependencies recursively
# ============================================================================
echo ""
echo "📦 Pass 1: Scanning for Homebrew dependencies..."

# Recursively collect dependencies
collect_deps() {
    local binary="$1"
    local deps=$(get_deps "$binary")

    for dep in $deps; do
        # Skip system paths
        if is_system_path "$dep"; then
            continue
        fi

        # Only process Homebrew paths
        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/"* ]]; then
            local lib_name=$(basename "$dep")

            # Skip if already collected
            if grep -q "^$lib_name:" "$HOMEBREW_DEPS_FILE" 2>/dev/null; then
                continue
            fi

            # Record the dependency
            echo "$lib_name:$dep" >> "$HOMEBREW_DEPS_FILE"
            echo "   Found: $lib_name"

            # Find and recursively scan this library
            local lib_path=$(find_in_homebrew "$lib_name")
            if [ -n "$lib_path" ] && [ -f "$lib_path" ]; then
                collect_deps "$lib_path"
            fi
        fi
    done
}

# Scan all binaries in the app
echo "   Scanning main executable..."
for exe in "$APP_PATH/Contents/MacOS"/*; do
    [ -f "$exe" ] && collect_deps "$exe"
done

echo "   Scanning frameworks..."
for framework in "$FRAMEWORKS_DIR"/*.framework; do
    [ -d "$framework" ] || continue
    framework_name=$(basename "$framework" .framework)

    # Try different framework binary locations
    for binary in "$framework/Versions/A/$framework_name" "$framework/$framework_name"; do
        if [ -f "$binary" ]; then
            echo "      Scanning $framework_name..."
            collect_deps "$binary"
            break
        fi
    done
done

echo "   Scanning existing dylibs..."
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    dylib_name=$(basename "$dylib")
    echo "      Scanning $dylib_name..."
    collect_deps "$dylib"
done

# Count dependencies
DEP_COUNT=$(wc -l < "$HOMEBREW_DEPS_FILE" | tr -d ' ')
echo ""
echo "   Found $DEP_COUNT Homebrew dependencies to bundle"

# ============================================================================
# PASS 2: Bundle all collected dependencies
# ============================================================================
echo ""
echo "📦 Pass 2: Bundling dependencies..."

while IFS=: read -r lib_name original_path; do
    [ -z "$lib_name" ] && continue

    dest_path="$FRAMEWORKS_DIR/$lib_name"

    # Skip if already exists
    if [ -f "$dest_path" ]; then
        echo "   $lib_name (already bundled)"
        continue
    fi

    # Find the library
    source_path=$(find_in_homebrew "$lib_name")
    if [ -z "$source_path" ]; then
        echo "   ⚠️  $lib_name not found in Homebrew, skipping..."
        continue
    fi

    echo "   Bundling: $lib_name"
    cp "$source_path" "$dest_path"
    chmod +w "$dest_path"

    # Remove code signature (we'll re-sign during packaging)
    codesign --remove-signature "$dest_path" 2>/dev/null || true
done < "$HOMEBREW_DEPS_FILE"

# ============================================================================
# PASS 3: Patch ALL binaries to use @rpath
# ============================================================================
echo ""
echo "🔧 Pass 3: Patching binaries to use @rpath..."

patch_binary() {
    local binary="$1"
    local binary_name=$(basename "$binary")

    # Make writable
    chmod +w "$binary" 2>/dev/null || true

    # Remove existing signature
    codesign --remove-signature "$binary" 2>/dev/null || true

    # Get all dependencies
    local deps=$(get_deps "$binary")

    for dep in $deps; do
        local dep_name=$(basename "$dep")

        # Skip system paths
        if is_system_path "$dep"; then
            continue
        fi

        # Patch Homebrew paths to @rpath
        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/"* ]]; then
            if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                install_name_tool -change "$dep" "@rpath/$dep_name" "$binary" 2>/dev/null || true
            fi
        fi
    done
}

# Patch main executable
echo "   Patching main executable..."
for exe in "$APP_PATH/Contents/MacOS"/*; do
    [ -f "$exe" ] || continue
    echo "      $(basename "$exe")"
    patch_binary "$exe"
done

# Patch frameworks
echo "   Patching frameworks..."
for framework in "$FRAMEWORKS_DIR"/*.framework; do
    [ -d "$framework" ] || continue
    framework_name=$(basename "$framework" .framework)

    for binary in "$framework/Versions/A/$framework_name" "$framework/$framework_name"; do
        if [ -f "$binary" ]; then
            echo "      $framework_name"
            patch_binary "$binary"
            break
        fi
    done
done

# Patch bundled dylibs
echo "   Patching bundled dylibs..."
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    dylib_name=$(basename "$dylib")
    echo "      $dylib_name"
    patch_binary "$dylib"

    # Also update the dylib's own ID
    install_name_tool -id "@rpath/$dylib_name" "$dylib" 2>/dev/null || true
done

# ============================================================================
# PASS 4: Verification
# ============================================================================
echo ""
echo "🔍 Pass 4: Verifying all binaries..."

FAILED=0
CHECKED=0

verify_binary() {
    local binary="$1"
    local name="$2"

    CHECKED=$((CHECKED + 1))

    local bad_deps=$(otool -L "$binary" 2>/dev/null | grep -E "/opt/homebrew|/usr/local" | awk '{print $1}')

    if [ -n "$bad_deps" ]; then
        echo "   ❌ $name has unresolved Homebrew dependencies:"
        for dep in $bad_deps; do
            echo "      - $dep"
        done
        FAILED=$((FAILED + 1))
        return 1
    fi

    return 0
}

# Check main executable
for exe in "$APP_PATH/Contents/MacOS"/*; do
    [ -f "$exe" ] && verify_binary "$exe" "$(basename "$exe")"
done

# Check frameworks
for framework in "$FRAMEWORKS_DIR"/*.framework; do
    [ -d "$framework" ] || continue
    framework_name=$(basename "$framework" .framework)

    for binary in "$framework/Versions/A/$framework_name" "$framework/$framework_name"; do
        if [ -f "$binary" ]; then
            verify_binary "$binary" "$framework_name.framework"
            break
        fi
    done
done

# Check dylibs
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    verify_binary "$dylib" "$(basename "$dylib")"
done

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "❌ FAILED: $FAILED of $CHECKED binaries have unresolved dependencies!"
    echo ""
    echo "   This app will NOT work on machines without Homebrew."
    echo "   Please check the errors above and ensure all dependencies are bundled."
    exit 1
fi

echo "✅ SUCCESS: All $CHECKED binaries verified!"
echo ""
echo "   The app bundle at $APP_PATH is ready for distribution."
echo "   All Homebrew dependencies have been bundled and patched."
