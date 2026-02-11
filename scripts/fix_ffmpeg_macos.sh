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
brew install libiconv fribidi srt openssl@3 harfbuzz fontconfig freetype glib pcre2 graphite2 gettext libpng || true

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
    local search_name="${lib_name%.dylib}"
    search_name="${search_name%.*}"  # Remove version suffix like .2
    
    # Try to find the library in common Homebrew locations
    local candidates=(
        "$HOMEBREW_PREFIX/opt/libiconv/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/fribidi/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/srt/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/openssl@3/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/harfbuzz/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/fontconfig/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/freetype/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/glib/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/pcre2/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/graphite2/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/gettext/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/libpng/lib/$lib_name"
        "$HOMEBREW_PREFIX/opt/zlib/lib/$lib_name"
        "$HOMEBREW_PREFIX/lib/$lib_name"
    )
    
    for candidate in "${candidates[@]}"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    
    # Try a broader search
    local found=$(find "$HOMEBREW_PREFIX" -name "$lib_name" -type f 2>/dev/null | head -n 1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi
    
    return 1
}

# List of libraries that are safe to use from /usr/lib (system libraries)
SYSTEM_LIBS="libz.1.dylib libbz2.1.0.dylib liblzma.5.dylib libSystem.B.dylib libc++.1.dylib libobjc.A.dylib libiconv.2.dylib libcharset.1.dylib"

is_system_lib() {
    local lib_name="$1"
    for sys_lib in $SYSTEM_LIBS; do
        if [ "$lib_name" = "$sys_lib" ]; then
            return 0
        fi
    done
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
            echo "⚠️  Warning: Dependency $lib_name not found. Skipping bundle."
            return 1
        fi
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
    
    return 0
}

echo "📦 Bundling dependencies..."

# Libraries that we bundle - we need to redirect ALL possible paths to @rpath
# This includes /usr/lib, /opt/homebrew, /usr/local, and any existing @rpath references
BUNDLED_LIBS=""

for framework in "$PACKAGE_DIR/macos/Frameworks/"*.framework; do
    binary_name=$(basename "$framework" .framework)
    binary="$framework/$binary_name"
    
    if [ ! -f "$binary" ]; then
        continue
    fi

    echo "   Processing $binary_name..."
    
    # FIRST: Redirect @rpath system libraries to /usr/lib
    # The arm64 slice uses @rpath/libz.1.dylib but we want to use the system library
    # Note: On modern macOS, these libraries are in the dyld cache, not as files in /usr/lib
    # But the linker still resolves /usr/lib paths correctly
    for sys_lib in $SYSTEM_LIBS; do
        install_name_tool -change "@rpath/$sys_lib" "/usr/lib/$sys_lib" "$binary" 2>/dev/null || true
    done
    
    # Find Homebrew/local dependencies (both /opt/homebrew and /usr/local paths)
    deps=$(otool -L "$binary" | grep -E "/opt/homebrew|/usr/local" | awk '{print $1}')
    
    for dep in $deps; do
        dep_name=$(basename "$dep")
        
        # Check if this is a known system library first
        # On modern macOS, system libraries are in the dyld cache, not as files in /usr/lib
        # But the dynamic linker still resolves /usr/lib paths correctly
        if is_system_lib "$dep_name"; then
            echo "      Using system library: /usr/lib/$dep_name"
            install_name_tool -change "$dep" "/usr/lib/$dep_name" "$binary"
            continue
        fi
        
        # Try to bundle the library
        if bundle_lib "$dep" "$LIBS_DIR"; then
            # Patch the framework to point to the bundled lib
            echo "      Redirecting $dep -> @rpath/$dep_name"
            install_name_tool -change "$dep" "@rpath/$dep_name" "$binary"
        else
            # Fallback: Check if it's a system library we might have missed
            # Try to use /usr/lib anyway - the dyld cache might have it
            echo "      ⚠️  Trying system library: /usr/lib/$dep_name"
            install_name_tool -change "$dep" "/usr/lib/$dep_name" "$binary"
        fi
    done
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
  ldflags = config.build_settings['OTHER_LDFLAGS'] || '$(inherited)'
  %w[-Wl,-no_warn_duplicate_libraries -Wl,-ld_classic].each do |flag|
    unless ldflags.include?(flag)
      ldflags = "#{ldflags} #{flag}"
      puts "   Added #{flag} to #{config.name} configuration"
    end
  end
  config.build_settings['OTHER_LDFLAGS'] = ldflags
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
