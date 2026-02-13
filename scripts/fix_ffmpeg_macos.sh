#!/bin/bash
# fix_ffmpeg_macos.sh - Post-build script to fix FFmpeg library paths in the final .app bundle
#
# This script patches the final .app bundle AFTER Flutter builds it.
# It ensures all Homebrew dependencies are bundled and patched to use @rpath.
#
# For fat binaries that can't be patched directly, it extracts each architecture,
# patches them separately, and recombines them.
#
# Usage:
#   ./scripts/fix_ffmpeg_macos.sh [path/to/App.app]
#
# Compatible with bash 3.x (macOS default)

set -e

echo "🔧 FFmpeg macOS Post-Build Fix"
echo "==============================="
echo ""

# Find the .app bundle
APP_PATH="$1"
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find build/macos/Build/Products/Release -name "*.app" -type d 2>/dev/null | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Could not find .app bundle"
    echo "   Usage: $0 [path/to/App.app]"
    exit 1
fi

echo "   App bundle: $APP_PATH"

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
TEMP_DIR=$(mktemp -d)
mkdir -p "$FRAMEWORKS_DIR"

# Temp file for tracking dependencies
HOMEBREW_DEPS_FILE=$(mktemp)
trap "rm -rf $TEMP_DIR $HOMEBREW_DEPS_FILE" EXIT

# ============================================================================
# Helper Functions
# ============================================================================

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

find_in_homebrew() {
    local lib_name="$1"
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
        $HOMEBREW_PREFIX/lib
    "

    for dir in $search_dirs; do
        if [ -f "$dir/$lib_name" ]; then
            echo "$dir/$lib_name"
            return 0
        fi
    done

    local found=$(find "$HOMEBREW_PREFIX/opt" -name "$lib_name" -type f 2>/dev/null | head -n 1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

get_deps() {
    local binary="$1"
    otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}'
}

get_architectures() {
    local binary="$1"
    lipo -info "$binary" 2>/dev/null | sed 's/.*: //' | tr ' ' '\n' | grep -v "^$"
}

is_fat_binary() {
    local binary="$1"
    local arch_count=$(lipo -info "$binary" 2>/dev/null | grep -c "are:" || echo "0")
    [ "$arch_count" -gt 0 ]
}

# Patch a thin (single-architecture) binary
patch_thin_binary() {
    local binary="$1"
    local binary_name=$(basename "$binary")

    chmod 755 "$binary" 2>/dev/null || true
    codesign --remove-signature "$binary" 2>/dev/null || true

    local deps=$(get_deps "$binary")
    for dep in $deps; do
        if is_system_path "$dep"; then
            continue
        fi

        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/"* ]]; then
            local dep_name=$(basename "$dep")
            if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                install_name_tool -change "$dep" "@rpath/$dep_name" "$binary" 2>/dev/null || true
            fi
        fi
    done
}

# Patch a binary, handling fat binaries by extracting/recombining
patch_binary() {
    local binary="$1"
    local binary_name=$(basename "$binary")

    echo "   Patching: $binary_name"

    if [ ! -f "$binary" ]; then
        echo "      ❌ File does not exist!"
        return 1
    fi

    chmod 755 "$binary" 2>/dev/null || true
    codesign --remove-signature "$binary" 2>/dev/null || true

    # Check if it has Homebrew dependencies
    local has_homebrew_deps=0
    local deps=$(get_deps "$binary")
    for dep in $deps; do
        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/"* ]]; then
            has_homebrew_deps=1
            break
        fi
    done

    if [ "$has_homebrew_deps" -eq 0 ]; then
        echo "      No Homebrew dependencies"
        return 0
    fi

    # Try direct patching first
    local direct_patch_failed=0
    for dep in $deps; do
        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/"* ]]; then
            local dep_name=$(basename "$dep")
            if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                if ! install_name_tool -change "$dep" "@rpath/$dep_name" "$binary" 2>/dev/null; then
                    direct_patch_failed=1
                    break
                fi
            fi
        fi
    done

    # If direct patching failed, try the extract/patch/recombine approach
    if [ "$direct_patch_failed" -eq 1 ]; then
        echo "      Direct patching failed, trying extract/patch/recombine..."

        if ! is_fat_binary "$binary"; then
            echo "      ❌ Not a fat binary, cannot use alternative approach"
            return 1
        fi

        local archs=$(get_architectures "$binary")
        local thin_binaries=""
        local work_dir="$TEMP_DIR/$(basename "$binary")_$$"
        mkdir -p "$work_dir"

        # Extract each architecture
        for arch in $archs; do
            echo "      Extracting $arch..."
            local thin_path="$work_dir/$arch"
            if ! lipo -thin "$arch" -output "$thin_path" "$binary" 2>/dev/null; then
                echo "      ❌ Failed to extract $arch"
                return 1
            fi
            thin_binaries="$thin_binaries $thin_path"
        done

        # Patch each thin binary
        for thin in $thin_binaries; do
            echo "      Patching $(basename "$thin")..."
            patch_thin_binary "$thin"
        done

        # Recombine into fat binary
        echo "      Recombining architectures..."
        local new_binary="$work_dir/combined"
        if ! lipo -create $thin_binaries -output "$new_binary" 2>/dev/null; then
            echo "      ❌ Failed to recombine architectures"
            return 1
        fi

        # Replace original with patched version
        cp "$new_binary" "$binary"
        chmod 755 "$binary"

        echo "      ✓ Successfully patched via extract/recombine"
    else
        echo "      ✓ Direct patching succeeded"
    fi

    return 0
}

# ============================================================================
# PASS 1: Collect ALL Homebrew dependencies recursively
# ============================================================================
echo "📦 Pass 1: Scanning for Homebrew dependencies..."

collect_deps() {
    local binary="$1"
    local deps=$(get_deps "$binary")

    for dep in $deps; do
        if is_system_path "$dep"; then
            continue
        fi

        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/"* ]]; then
            local lib_name=$(basename "$dep")

            if grep -q "^$lib_name:" "$HOMEBREW_DEPS_FILE" 2>/dev/null; then
                continue
            fi

            echo "$lib_name:$dep" >> "$HOMEBREW_DEPS_FILE"
            echo "   Found: $lib_name"

            local lib_path=$(find_in_homebrew "$lib_name")
            if [ -n "$lib_path" ] && [ -f "$lib_path" ]; then
                collect_deps "$lib_path"
            fi
        fi
    done
}

# Scan main executable
for exe in "$APP_PATH/Contents/MacOS"/*; do
    [ -f "$exe" ] && collect_deps "$exe"
done

# Scan frameworks
for framework in "$FRAMEWORKS_DIR"/*.framework; do
    [ -d "$framework" ] || continue
    framework_name=$(basename "$framework" .framework)
    for binary in "$framework/Versions/A/$framework_name" "$framework/$framework_name"; do
        if [ -f "$binary" ]; then
            collect_deps "$binary"
            break
        fi
    done
done

# Scan existing dylibs
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] && collect_deps "$dylib"
done

DEP_COUNT=$(wc -l < "$HOMEBREW_DEPS_FILE" 2>/dev/null | tr -d ' ')
echo ""
echo "   Found $DEP_COUNT Homebrew dependencies"

# ============================================================================
# PASS 2: Bundle all collected dependencies
# ============================================================================
if [ "$DEP_COUNT" -gt 0 ]; then
    echo ""
    echo "📦 Pass 2: Bundling dependencies..."

    while IFS=: read -r lib_name original_path; do
        [ -z "$lib_name" ] && continue

        dest_path="$FRAMEWORKS_DIR/$lib_name"

        if [ -f "$dest_path" ]; then
            echo "   $lib_name (already exists)"
            continue
        fi

        source_path=$(find_in_homebrew "$lib_name")
        if [ -z "$source_path" ]; then
            echo "   ⚠️  $lib_name not found"
            continue
        fi

        echo "   Bundling: $lib_name"
        cp "$source_path" "$dest_path"
        chmod 755 "$dest_path"
        codesign --remove-signature "$dest_path" 2>/dev/null || true
    done < "$HOMEBREW_DEPS_FILE"
fi

# ============================================================================
# PASS 3: Patch ALL binaries to use @rpath
# ============================================================================
echo ""
echo "🔧 Pass 3: Patching binaries..."

# Patch main executable
echo ""
echo "   === Main Executable ==="
for exe in "$APP_PATH/Contents/MacOS"/*; do
    [ -f "$exe" ] && patch_binary "$exe"
done

# Patch frameworks
echo ""
echo "   === Frameworks ==="
for framework in "$FRAMEWORKS_DIR"/*.framework; do
    [ -d "$framework" ] || continue
    framework_name=$(basename "$framework" .framework)

    for binary in "$framework/Versions/A/$framework_name" "$framework/$framework_name"; do
        if [ -f "$binary" ]; then
            patch_binary "$binary"
            break
        fi
    done
done

# Patch bundled dylibs
echo ""
echo "   === Bundled Dylibs ==="
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    patch_binary "$dylib"

    # Update the dylib's ID
    dylib_name=$(basename "$dylib")
    install_name_tool -id "@rpath/$dylib_name" "$dylib" 2>/dev/null || true
done

# ============================================================================
# PASS 4: Verification
# ============================================================================
echo ""
echo "🔍 Pass 4: Verifying..."

FAILED=0
CHECKED=0

verify_binary() {
    local binary="$1"
    local name="$2"

    CHECKED=$((CHECKED + 1))

    local bad_deps=$(get_deps "$binary" | grep -E "/opt/homebrew|/usr/local" || true)

    if [ -n "$bad_deps" ]; then
        echo "   ❌ $name has unresolved dependencies:"
        for dep in $bad_deps; do
            echo "      - $dep"
        done
        FAILED=$((FAILED + 1))
        return 1
    fi

    echo "   ✅ $name"
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
    [ -f "$dylib" ] && verify_binary "$dylib" "$(basename "$dylib")"
done

echo ""
echo "==============================="
if [ "$FAILED" -gt 0 ]; then
    echo "❌ FAILED: $FAILED of $CHECKED binaries have unresolved dependencies!"
    exit 1
fi

echo "✅ SUCCESS: All $CHECKED binaries verified!"
echo "   App bundle is ready for distribution."
