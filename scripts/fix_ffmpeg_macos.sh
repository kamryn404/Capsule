#!/bin/bash
# fix_ffmpeg_macos.sh - Fix FFmpeg kit libiconv/zlib issues on macOS by bundling dependencies
#
# The pre-built FFmpeg frameworks from ffmpeg_kit_flutter_new_full have:
# 1. Hardcoded Homebrew library paths that don't exist on end-user machines
# 2. Duplicate load commands for libiconv (a bug in the pre-built frameworks)
#
# This script:
# 1. Downloads the FFmpeg frameworks if not present
# 2. Patches Homebrew paths to use @rpath (bundled libraries)
# 3. Bundles required Homebrew libraries into the app
# 4. Updates the Xcode project to embed the bundled libraries
#
# The duplicate load commands issue is handled by the -Wl,-no_warn_duplicate_libraries
# linker flag added to the Podfile.

set -e

echo "🔧 Setting up FFmpeg Kit macOS fix..."

if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ This script is only for macOS."
    exit 1
fi

# Install required Homebrew dependencies for bundling
echo "📦 Installing required Homebrew dependencies..."
# We need to ensure these are installed and linked correctly
brew install libiconv fribidi srt openssl@3 harfbuzz fontconfig freetype glib pcre2 graphite2 gettext libpng zlib expat brotli bzip2 xz 2>/dev/null || true

# Determine Homebrew prefix (different on Intel vs Apple Silicon)
HOMEBREW_PREFIX=$(brew --prefix)
echo "   Using Homebrew prefix: $HOMEBREW_PREFIX"

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

# Function to find a library by name in Homebrew
find_brew_lib() {
    local lib_name="$1"

    # Try to find the library in common Homebrew locations
    # We check specific opt paths first for reliability
    local candidates=(
        "$HOMEBREW_PREFIX/opt/fontconfig/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/freetype/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/fribidi/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/harfbuzz/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/glib/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/graphite2/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/libiconv/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/libpng/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/openssl@3/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/pcre2/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/srt/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/gettext/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/zlib/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/expat/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/brotli/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/bzip2/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/xz/lib/$lib_name"
        "$HOMEBREW_PREFIX/lib/$lib_name"
    )

    for candidate in "${candidates[@]}"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    # Try a broader search as a fallback
    local found=$(find "$HOMEBREW_PREFIX/opt" -name "$lib_name" -type f 2>/dev/null | head -n 1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

# List of libraries that are safe to use from /usr/lib (system libraries)
# Note: libiconv is often in /usr/lib but FFmpeg links the Homebrew one for features.
# We will bundle libiconv to be safe, as the system one might be older.
# libexpat.1.dylib is NOT a system library on all macOS versions (it's often Homebrew),
# so we remove it from here to ensure it gets bundled.
SYSTEM_LIBS="libz.1.dylib libbz2.1.0.dylib liblzma.5.dylib libSystem.B.dylib libc++.1.dylib libobjc.A.dylib libcharset.1.dylib libresolv.9.dylib Foundation CoreGraphics CoreFoundation CoreVideo CoreMedia AppKit AudioToolbox VideoToolbox Security OpenGL Metal QuartzCore"

is_system_lib() {
    local lib_name=$(basename "$1")
    for sys_lib in $SYSTEM_LIBS; do
        if [ "$lib_name" = "$sys_lib" ]; then
            return 0
        fi
    done
    # Also check if it's a system framework path
    if [[ "$1" == "/System/Library/Frameworks/"* ]]; then
        return 0
    fi
    return 1
}

bundle_lib() {
    local lib_path="$1"
    local dest_dir="$2"
    local lib_name=$(basename "$lib_path")

    # Skip if already bundled
    if [ -f "$dest_dir/$lib_name" ]; then
        return 0
    fi

    # If the path doesn't exist, try to find it in Homebrew
    if [ ! -f "$lib_path" ]; then
        local found_path=$(find_brew_lib "$lib_name")
        if [ -n "$found_path" ]; then
            lib_path="$found_path"
        else
            echo "❌ Error: Dependency $lib_name not found in Homebrew. Cannot bundle."
            return 1
        fi
    fi

    echo "      Bundling $lib_name from $lib_path..."
    cp "$lib_path" "$dest_dir/"
    chmod +w "$dest_dir/$lib_name"

    # Patch the ID of the bundled lib
    install_name_tool -id "@rpath/$lib_name" "$dest_dir/$lib_name"

    # Scan for dependencies of this lib (recursive)
    # We look for any path that isn't already @rpath or system
    local deps=$(otool -L "$dest_dir/$lib_name" | grep -E "^[[:space:]]/" | awk '{print $1}')
    for dep in $deps; do
        local dep_name=$(basename "$dep")

        # Skip system libraries and frameworks
        if is_system_lib "$dep"; then
            # If it's a dylib in /usr/lib, ensure it points there
            if [[ "$dep" == *".dylib" && "$dep" != "/usr/lib/"* && "$dep" != "/System/"* ]]; then
                install_name_tool -change "$dep" "/usr/lib/$dep_name" "$dest_dir/$lib_name" 2>/dev/null || true
            fi
            continue
        fi

        # Recursive bundle
        if ! bundle_lib "$dep" "$dest_dir"; then
            echo "❌ Failed to bundle dependency $dep_name for $lib_name"
            return 1
        fi
        # Patch dependency path in the bundled lib
        install_name_tool -change "$dep" "@rpath/$dep_name" "$dest_dir/$lib_name"
    done

    return 0
}

echo "📦 Bundling dependencies..."

for framework in "$PACKAGE_DIR/macos/Frameworks/"*.framework; do
    binary_name=$(basename "$framework" .framework)
    # Handle framework structure: Foo.framework/Versions/A/Foo or Foo.framework/Foo
    binary="$framework/$binary_name"
    if [ ! -f "$binary" ]; then
        # Try Versions/A/ structure
        binary="$framework/Versions/A/$binary_name"
    fi

    if [ ! -f "$binary" ]; then
        echo "⚠️  Binary not found in $framework, skipping..."
        continue
    fi

    echo "   Processing $binary_name..."

    # Make sure we can write to the binary
    chmod +w "$binary"

    # FIRST: Redirect @rpath system libraries to /usr/lib
    for sys_lib in $SYSTEM_LIBS; do
        install_name_tool -change "@rpath/$sys_lib" "/usr/lib/$sys_lib" "$binary" 2>/dev/null || true
    done

    # Find all dependencies that look like absolute paths (Homebrew or local)
    # We do NOT grep for just /opt/homebrew because paths can vary
    deps=$(otool -L "$binary" | grep -E "^\t/" | awk '{print $1}')

    for dep in $deps; do
        dep_name=$(basename "$dep")

        # Skip system libraries and frameworks
        if is_system_lib "$dep"; then
            # Ensure it points to /usr/lib for system dylibs
            if [[ "$dep" == *".dylib" && "$dep" != "/usr/lib/"* && "$dep" != "/System/"* ]]; then
                 install_name_tool -change "$dep" "/usr/lib/$dep_name" "$binary" 2>/dev/null || true
            fi
            continue
        fi

        # Skip if it's already pointing to @rpath
        if [[ "$dep" == "@rpath/"* ]]; then
            continue
        fi

        # Try to bundle the library
        echo "      Found dependency: $dep"
        if bundle_lib "$dep" "$LIBS_DIR"; then
            # Patch the framework to point to the bundled lib
            echo "      Patching $dep_name in $binary_name -> @rpath/$dep_name"
            install_name_tool -change "$dep" "@rpath/$dep_name" "$binary"
        else
            echo "❌ ERROR: Failed to bundle required dependency: $dep_name"
            echo "   Please ensure the library is available in Homebrew."
            exit 1
        fi
    done

    # Verify patching
    if otool -L "$binary" | grep -q "/opt/homebrew"; then
        echo "❌ ERROR: Binary $binary_name still contains hardcoded Homebrew paths!"
        otool -L "$binary" | grep "/opt/homebrew"
        exit 1
    fi
done

# 4. Copy bundled libs to project and update Xcode project
echo "📂 Copying bundled libs to macos/Runner/Frameworks..."
PROJECT_FRAMEWORKS_DIR="macos/Runner/Frameworks"
mkdir -p "$PROJECT_FRAMEWORKS_DIR"

# Check if there are any dylibs to copy
if ls "$LIBS_DIR/"*.dylib 1> /dev/null 2>&1; then
    cp "$LIBS_DIR/"*.dylib "$PROJECT_FRAMEWORKS_DIR/"
else
    echo "⚠️  No bundled libraries found in $LIBS_DIR. Skipping copy."
fi

echo "📝 Updating Xcode project to embed libraries..."

# Create Ruby script to update Xcode project
cat <<'RUBY_EOF' > scripts/update_xcode.rb
require 'xcodeproj'

project_path = 'macos/Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'Runner' }
group = project.main_group['Frameworks'] || project.main_group.new_group('Frameworks')

# Add linker flag to suppress duplicate dylib errors from FFmpeg frameworks
# The pre-built FFmpeg frameworks have duplicate LC_LOAD_DYLIB entries for libiconv
# that cannot be removed with install_name_tool. This flag tells the linker to
# treat duplicate dylibs as warnings instead of errors.
# We also use -Wl,-ld_classic to use the older linker which is more lenient with duplicates.
puts "Adding linker flags to Runner target..."
target.build_configurations.each do |config|
  config.build_settings['OTHER_LDFLAGS'] ||= '$(inherited)'
  flags = config.build_settings['OTHER_LDFLAGS']
  ['-Wl,-no_warn_duplicate_libraries', '-Wl,-ld_classic'].each do |flag|
    if flags.is_a?(String)
      unless flags.include?(flag)
        flags = "#{flags} #{flag}"
        puts "   Added #{flag} to #{config.name} configuration"
      end
    elsif flags.is_a?(Array)
      unless flags.include?(flag)
        flags << flag
        puts "   Added #{flag} to #{config.name} configuration"
      end
    end
  end
  config.build_settings['OTHER_LDFLAGS'] = flags
end

# Ensure "Embed Frameworks" phase exists
embed_phase = target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' || p.dst_subfolder_spec == 10 }
if embed_phase.nil?
  embed_phase = target.new_copy_files_build_phase('Embed Frameworks')
  embed_phase.dst_subfolder_spec = "10" # Frameworks
end

# Clean up existing file references from the Frameworks group
# This removes them from the project and ALL build phases, ensuring a clean slate.
puts "Cleaning existing file references from Frameworks group..."
group.files.to_a.each do |file_ref|
  if file_ref.path && file_ref.path.end_with?('.dylib')
    puts "   Removing reference #{file_ref.path}"
    file_ref.remove_from_project
  end
end

frameworks_dir = 'macos/Runner/Frameworks'
Dir.glob("#{frameworks_dir}/*.dylib").each do |file|
  filename = File.basename(file)
  puts "Processing #{filename}..."

  # Calculate path relative to the Xcode project (which is in macos/)
  relative_path = file.sub(/^macos\//, '')

  # Add file to project (new reference)
  file_ref = group.new_reference(relative_path)

  # Add to Embed phase
  build_file = embed_phase.add_file_reference(file_ref)
  build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
  puts "   Added to Embed Frameworks"
end

project.save
puts "Xcode project updated."
RUBY_EOF

# Run Ruby script
ruby scripts/update_xcode.rb
rm scripts/update_xcode.rb

# 5. Force Pod Install
# We delete Podfile.lock to ensure pod install runs and picks up the new frameworks/headers
echo "🔄 Forcing pod install update..."
rm -f macos/Podfile.lock
# We don't run pod install here because flutter build macos will do it.
# But deleting the lockfile ensures it runs.

echo "✅ Fix script completed."
