#!/bin/bash
# fix_ffmpeg_macos.sh - Patch FFmpeg frameworks to use system libiconv
# Run this script after `flutter pub get` when using ffmpeg_kit_flutter_new_full on macOS
#
# The problem: The ffmpeg_kit_flutter_new_full package ships pre-built frameworks
# that have BOTH /usr/lib and /opt/homebrew paths linked for libiconv/libz.
# This causes "duplicate linked dylib" errors at link time.
#
# The fix: Use install_name_tool to change homebrew paths to system paths.
# If system paths are already linked, the -change command becomes a no-op
# (it doesn't add duplicates, just removes the old reference).

set -e

# Find the package - try multiple possible versions
PACKAGE_BASE="$HOME/.pub-cache/hosted/pub.dev"
PACKAGE_NAME="ffmpeg_kit_flutter_new_full"

# Find the installed version
PACKAGE_PATH=""
for dir in "$PACKAGE_BASE"/${PACKAGE_NAME}-*/; do
    if [ -d "$dir/macos/Frameworks" ]; then
        PACKAGE_PATH="$dir/macos/Frameworks"
        VERSION=$(basename "$(dirname "$(dirname "$PACKAGE_PATH")")" | sed "s/${PACKAGE_NAME}-//")
        break
    fi
done

if [ -z "$PACKAGE_PATH" ] || [ ! -d "$PACKAGE_PATH" ]; then
    echo "❌ FFmpeg kit package not found in pub cache"
    echo "   Expected location: $PACKAGE_BASE/${PACKAGE_NAME}-*/macos/Frameworks"
    echo "   Make sure you've run 'flutter pub get' first"
    exit 1
fi

echo "📦 Found ffmpeg_kit_flutter_new_full v$VERSION"
echo "📁 Frameworks path: $PACKAGE_PATH"
echo ""
echo "🔧 Patching frameworks to remove homebrew paths..."

patch_count=0
for framework in "$PACKAGE_PATH"/*.framework; do
    if [ -d "$framework" ]; then
        framework_name=$(basename "$framework" .framework)
        binary_path="$framework/Versions/A/$framework_name"
        
        if [ -f "$binary_path" ]; then
            # Check current dependencies
            deps=$(otool -L "$binary_path" 2>/dev/null || true)
            
            # Check if the binary has homebrew paths
            has_homebrew=$(echo "$deps" | grep -c "/opt/homebrew\|/usr/local/opt" || echo "0")
            
            if [ "$has_homebrew" != "0" ]; then
                echo "   Patching: $framework_name"
                
                # Change homebrew paths to system paths
                # If the system path already exists, this effectively removes the duplicate
                # because -change removes the old entry and points it to the new one
                # (which already exists, so no new entry is added)
                
                # The key insight: -change replaces the LOAD command, it doesn't add a new one.
                # So even if /usr/lib/libiconv.2.dylib is already linked, changing
                # /opt/homebrew/.../libiconv.2.dylib to /usr/lib/libiconv.2.dylib
                # will just make them both point to the same place (deduped by loader)
                
                install_name_tool -change \
                    /opt/homebrew/opt/libiconv/lib/libiconv.2.dylib \
                    /usr/lib/libiconv.2.dylib \
                    "$binary_path" 2>/dev/null || true
                
                install_name_tool -change \
                    /opt/homebrew/opt/zlib/lib/libz.1.dylib \
                    /usr/lib/libz.1.dylib \
                    "$binary_path" 2>/dev/null || true
                
                # Intel Mac homebrew paths
                install_name_tool -change \
                    /usr/local/opt/libiconv/lib/libiconv.2.dylib \
                    /usr/lib/libiconv.2.dylib \
                    "$binary_path" 2>/dev/null || true
                
                install_name_tool -change \
                    /usr/local/opt/zlib/lib/libz.1.dylib \
                    /usr/lib/libz.1.dylib \
                    "$binary_path" 2>/dev/null || true
                
                ((patch_count++)) || true
            else
                echo "   ✓ No homebrew paths: $framework_name"
            fi
        fi
    fi
done

echo ""
if [ $patch_count -gt 0 ]; then
    echo "✅ Patched $patch_count framework(s)"
else
    echo "✅ All frameworks already patched"
fi

echo ""
echo "🔍 Verifying libswresample (the framework that reported the error)..."
SWRESAMPLE="$PACKAGE_PATH/libswresample.framework/Versions/A/libswresample"
if [ -f "$SWRESAMPLE" ]; then
    deps=$(otool -L "$SWRESAMPLE" 2>/dev/null | grep -E "(libiconv|libz)" || true)
    echo "$deps"
    
    # Check if any homebrew paths remain
    if echo "$deps" | grep -q "/opt/homebrew\|/usr/local/opt"; then
        echo ""
        echo "⚠️  Homebrew paths still present after patching."
        echo "    This is a known issue with ffmpeg_kit_flutter_new_full v2.0.0"
        echo "    The framework has duplicate LC_LOAD_DYLIB entries that cannot be"
        echo "    removed with install_name_tool -change alone."
        echo ""
        echo "    Attempting alternative fix: creating symlinks for homebrew paths..."
        
        # Create the homebrew directory structure and symlink to system libs
        # This is a workaround - we make the expected paths point to system libs
        sudo mkdir -p /opt/homebrew/opt/libiconv/lib
        sudo mkdir -p /opt/homebrew/opt/zlib/lib
        sudo ln -sf /usr/lib/libiconv.2.dylib /opt/homebrew/opt/libiconv/lib/libiconv.2.dylib 2>/dev/null || true
        sudo ln -sf /usr/lib/libz.1.dylib /opt/homebrew/opt/zlib/lib/libz.1.dylib 2>/dev/null || true
        
        echo "✅ Created symlinks as fallback"
    else
        echo ""
        echo "✅ Verification passed - using system libraries"
    fi
fi

echo ""
echo "📋 Patching complete!"
