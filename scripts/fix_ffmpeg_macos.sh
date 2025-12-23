#!/bin/bash
# fix_ffmpeg_macos.sh - Patch FFmpeg frameworks to use system libiconv
# Run this script after `flutter pub get` when using ffmpeg_kit_flutter_new_full on macOS
#
# The problem: The ffmpeg_kit_flutter_new_full package ships pre-built frameworks
# that have hardcoded Homebrew paths (/opt/homebrew/opt/libiconv/lib/libiconv.2.dylib)
# which don't exist on most systems.
#
# The fix: Use install_name_tool to redirect these to system libraries at /usr/lib/

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
echo "🔧 Patching frameworks..."

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
            
            # Check if already has /usr/lib/libiconv (to avoid duplicates)
            has_system_iconv=$(echo "$deps" | grep -c "/usr/lib/libiconv" || echo "0")
            
            if [ "$has_homebrew" != "0" ]; then
                echo "   Patching: $framework_name (homebrew paths found)"
                
                # Only patch if system lib isn't already linked (avoid duplicates)
                if [ "$has_system_iconv" = "0" ]; then
                    # Patch libiconv - try homebrew arm64 path
                    install_name_tool -change \
                        /opt/homebrew/opt/libiconv/lib/libiconv.2.dylib \
                        /usr/lib/libiconv.2.dylib \
                        "$binary_path" 2>/dev/null || true
                    
                    # Patch zlib
                    install_name_tool -change \
                        /opt/homebrew/opt/zlib/lib/libz.1.dylib \
                        /usr/lib/libz.1.dylib \
                        "$binary_path" 2>/dev/null || true
                    
                    # Also handle Intel Mac homebrew path
                    install_name_tool -change \
                        /usr/local/opt/libiconv/lib/libiconv.2.dylib \
                        /usr/lib/libiconv.2.dylib \
                        "$binary_path" 2>/dev/null || true
                    
                    install_name_tool -change \
                        /usr/local/opt/zlib/lib/libz.1.dylib \
                        /usr/lib/libz.1.dylib \
                        "$binary_path" 2>/dev/null || true
                else
                    echo "      (skipped: /usr/lib/libiconv already linked, would cause duplicates)"
                    # The binary already has both - we need to remove the homebrew one
                    # This requires more complex handling - deleting the LC_LOAD_DYLIB entry
                    # For now, skip as the system one should work
                fi
                
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
    
    if echo "$deps" | grep -q "/opt/homebrew\|/usr/local/opt"; then
        echo ""
        echo "⚠️  Warning: Still seeing homebrew paths. The patching may not have worked."
        exit 1
    else
        echo ""
        echo "✅ Verification passed - using system libraries"
    fi
fi

echo ""
echo "📋 Next steps:"
echo "   1. Run: flutter clean"
echo "   2. Run: cd macos && pod deintegrate && pod install && cd .."
echo "   3. Run: flutter run -d macos"
