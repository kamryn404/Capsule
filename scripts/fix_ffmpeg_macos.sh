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
        
        # If bundling failed (file not found), we can't use @rpath.
        if [ ! -f "$LIBS_DIR/$dep_name" ]; then
             # Fallback: Redirect to system path (e.g. /usr/lib/libz.1.dylib)
             SYSTEM_PATH="/usr/lib/$dep_name"
             echo "      ⚠️  Failed to bundle $dep_name. Redirecting to system path: $SYSTEM_PATH"
             install_name_tool -change "$dep" "$SYSTEM_PATH" "$binary"
        else
             # Patch the framework to point to the bundled lib
             echo "      Redirecting $dep -> @rpath/$dep_name"
             install_name_tool -change "$dep" "@rpath/$dep_name" "$binary"
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
cat <<EOF > scripts/update_xcode.rb
require 'xcodeproj'

project_path = 'macos/Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'Runner' }
group = project.main_group['Frameworks'] || project.main_group.new_group('Frameworks')

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

Dir.glob('$PROJECT_FRAMEWORKS_DIR/*.dylib').each do |file|
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
EOF

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
