# Fix Plan: FFmpeg Kit macOS libiconv Error

## Problem Summary

The `ffmpeg_kit_flutter_new_full` package (v2.0.0) has pre-built macOS frameworks with hardcoded Homebrew library paths:
- `/opt/homebrew/opt/libiconv/lib/libiconv.2.dylib`
- `/opt/homebrew/opt/zlib/lib/libz.1.dylib`

When the app launches, macOS attempts to load `libswresample.framework` which references these non-existent paths, causing immediate crash.

**Root Cause**: The package maintainer compiled FFmpeg on a system with Homebrew and didn't properly relink the libraries to use system paths (`/usr/lib/libiconv.2.dylib` and `/usr/lib/libz.1.dylib`).

## Solution Options

### Option 1: Patch Frameworks in the Pub Cache (Recommended)

Patch the frameworks **at the source** in `~/.pub-cache` so all subsequent builds use the fixed binaries. This is a one-time fix that persists until you `flutter pub upgrade`.

**Steps:**
1. Create a shell script that patches all FFmpeg frameworks in the pub cache
2. Run the script once after `flutter pub get`
3. The patching persists across builds

**Script:**
```bash
#!/bin/bash
# fix_ffmpeg_macos.sh - Run once after flutter pub get

PACKAGE_PATH="$HOME/.pub-cache/hosted/pub.dev/ffmpeg_kit_flutter_new_full-2.0.0/macos/Frameworks"

if [ ! -d "$PACKAGE_PATH" ]; then
    echo "FFmpeg kit package not found at $PACKAGE_PATH"
    exit 1
fi

echo "Patching FFmpeg frameworks..."

for framework in "$PACKAGE_PATH"/*.framework; do
    if [ -d "$framework" ]; then
        binary_name=$(basename "$framework" .framework)
        binary_path="$framework/Versions/A/$binary_name"
        
        if [ -f "$binary_path" ]; then
            echo "Patching $binary_name..."
            install_name_tool -change /opt/homebrew/opt/libiconv/lib/libiconv.2.dylib /usr/lib/libiconv.2.dylib "$binary_path" 2>/dev/null
            install_name_tool -change /opt/homebrew/opt/zlib/lib/libz.1.dylib /usr/lib/libz.1.dylib "$binary_path" 2>/dev/null
        fi
    fi
done

echo "Patching complete!"
```

**Pros:**
- Simple one-time fix
- Works with standard Flutter build process
- No need to modify Podfile

**Cons:**
- Must re-run after `flutter pub upgrade` if package updates
- Modifies files outside project directory

---

### Option 2: Add Xcode Build Phase Script (More Robust)

Add a "Run Script" build phase in Xcode that patches the frameworks **after they're copied to the app bundle**.

**Implementation:**
1. Open `macos/Runner.xcworkspace` in Xcode
2. Select the Runner target → Build Phases
3. Add a new "Run Script" phase AFTER "Embed Pods Frameworks"
4. Add the patching script

**Script content:**
```bash
# Patch FFmpeg frameworks for libiconv
APP_FRAMEWORKS="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"

if [ -d "$APP_FRAMEWORKS" ]; then
    for framework in "$APP_FRAMEWORKS"/lib*.framework "$APP_FRAMEWORKS"/ffmpegkit.framework; do
        if [ -d "$framework" ]; then
            binary_name=$(basename "$framework" .framework)
            binary_path="$framework/Versions/A/$binary_name"
            
            if [ -f "$binary_path" ]; then
                install_name_tool -change /opt/homebrew/opt/libiconv/lib/libiconv.2.dylib /usr/lib/libiconv.2.dylib "$binary_path" 2>/dev/null || true
                install_name_tool -change /opt/homebrew/opt/zlib/lib/libz.1.dylib /usr/lib/libz.1.dylib "$binary_path" 2>/dev/null || true
            fi
        fi
    done
fi
```

**Pros:**
- Automatically runs on every build
- Doesn't modify package source
- Project-specific

**Cons:**
- Requires manual Xcode configuration
- Build phase may not survive Flutter clean/recreate

---

### Option 3: Modify Podfile Post-Install (Your Current Approach - Fixed)

Your current approach patches the wrong location. The correct approach is to patch the **source frameworks in the package** during `post_install`, not the Pods directory.

**Updated Podfile post_install:**
```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_macos_build_settings(target)
  end

  # Patch FFmpeg frameworks at the source
  ffmpeg_frameworks_path = File.expand_path('~/.pub-cache/hosted/pub.dev/ffmpeg_kit_flutter_new_full-2.0.0/macos/Frameworks')
  
  if Dir.exist?(ffmpeg_frameworks_path)
    puts "Patching FFmpeg frameworks at #{ffmpeg_frameworks_path}..."
    Dir.glob("#{ffmpeg_frameworks_path}/*.framework/Versions/A/*").each do |binary|
      next if binary.end_with?(".plist", ".h", ".modulemap") || binary.include?("_CodeSignature") || binary.include?("Headers") || binary.include?("Modules") || binary.include?("Resources")
      next unless File.file?(binary)
      
      puts "  Patching: #{File.basename(binary)}"
      system("install_name_tool -change /opt/homebrew/opt/libiconv/lib/libiconv.2.dylib /usr/lib/libiconv.2.dylib \"#{binary}\" 2>/dev/null")
      system("install_name_tool -change /opt/homebrew/opt/zlib/lib/libz.1.dylib /usr/lib/libz.1.dylib \"#{binary}\" 2>/dev/null")
    end
    puts "FFmpeg patching complete!"
  else
    puts "Warning: FFmpeg frameworks not found at #{ffmpeg_frameworks_path}"
  end
end
```

**Pros:**
- Integrated into standard Flutter workflow
- Automatic on `pod install`

**Cons:**
- Hardcoded version number in path
- Must update path when package version changes

---

### Option 4: Use a Different FFmpeg Package

Consider alternative packages that may not have this issue:

1. **ffmpeg_kit_flutter** (Original) - Version 6.0.3
2. **ffmpeg_kit_flutter_full** - Different maintainer
3. **media_kit** - You already have this, and it has its own FFmpeg libs

Check if `media_kit` can handle your FFmpeg needs without the problematic package.

---

### Option 5: Report Issue to Package Maintainer

This is a bug in the package build process. The maintainer should:
1. Build FFmpeg binaries that use `@rpath` or system library paths
2. Not hardcode Homebrew paths in distributed binaries

Report at: https://github.com/sk3llo/ffmpeg_kit_flutter/issues

---

## Recommended Approach

**For immediate fix**: Use **Option 1** (patch pub cache) - it's the simplest and most reliable.

**For long-term**: Combine with **Option 5** (report the bug) so future versions are fixed.

## Implementation Plan

1. [ ] Create the patching script (`scripts/fix_ffmpeg_macos.sh`)
2. [ ] Run the script once: `bash scripts/fix_ffmpeg_macos.sh`
3. [ ] Clean and rebuild: `flutter clean && flutter build macos`
4. [ ] Test the app launches successfully
5. [ ] (Optional) Report issue to package maintainer
6. [ ] (Optional) Add build phase in Xcode for automated future builds

## Verification

After patching, verify with:
```bash
otool -L ~/.pub-cache/hosted/pub.dev/ffmpeg_kit_flutter_new_full-2.0.0/macos/Frameworks/libswresample.framework/Versions/A/libswresample
```

Should show `/usr/lib/libiconv.2.dylib` instead of `/opt/homebrew/opt/libiconv/lib/libiconv.2.dylib`
