#!/bin/bash
# fix_ffmpeg_macos.sh - Fix FFmpeg kit library paths on macOS by bundling dependencies
#
# The pre-built FFmpeg frameworks from ffmpeg_kit_flutter_new_full have hardcoded
# Homebrew library paths that don't exist on end-user machines.
#
# This script uses a two-pass approach:
# Pass 1: Scan all frameworks, collect all Homebrew dependencies, bundle them
# Pass 2: Patch all frameworks and bundled libs to use @rpath instead of absolute paths

set -e

echo "🔧 Setting up FFmpeg Kit macOS fix..."

if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ This script is only for macOS."
    exit 1
fi

# Install required Homebrew dependencies for bundling
echo "📦 Installing required Homebrew dependencies..."
brew install libiconv fribidi srt openssl@3 harfbuzz fontconfig freetype glib pcre2 graphite2 gettext libpng zlib expat brotli 2>/dev/null || true

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

# Ensure frameworks exist (download if missing)
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

# Setup directories
LIBS_DIR="$PACKAGE_DIR/macos/libs"
rm -rf "$LIBS_DIR"
mkdir -p "$LIBS_DIR"

# Collect all framework binaries
declare -a FRAMEWORK_BINARIES
for framework in "$PACKAGE_DIR/macos/Frameworks/"*.framework; do
    binary_name=$(basename "$framework" .framework)
    binary="$framework/Versions/A/$binary_name"
    if [ ! -f "$binary" ]; then
        binary="$framework/$binary_name"
    fi
    if [ -f "$binary" ]; then
        FRAMEWORK_BINARIES+=("$binary")
    fi
done

echo "   Found ${#FRAMEWORK_BINARIES[@]} framework binaries"

# Function to check if a path is a system library we should NOT bundle
is_system_path() {
    local path="$1"
    # System frameworks
    [[ "$path" == "/System/Library/"* ]] && return 0
    # System libraries
    [[ "$path" == "/usr/lib/libSystem"* ]] && return 0
    [[ "$path" == "/usr/lib/libc++"* ]] && return 0
    [[ "$path" == "/usr/lib/libobjc"* ]] && return 0
    [[ "$path" == "/usr/lib/libz."* ]] && return 0
    [[ "$path" == "/usr/lib/libbz2."* ]] && return 0
    [[ "$path" == "/usr/lib/liblzma."* ]] && return 0
    [[ "$path" == "/usr/lib/libresolv."* ]] && return 0
    [[ "$path" == "/usr/lib/libcharset."* ]] && return 0
    [[ "$path" == "/usr/lib/libiconv."* ]] && return 0
    [[ "$path" == "/usr/lib/libexpat."* ]] && return 0
    # @rpath and @executable_path are already relative
    [[ "$path" == "@rpath/"* ]] && return 0
    [[ "$path" == "@executable_path/"* ]] && return 0
    [[ "$path" == "@loader_path/"* ]] && return 0
    return 1
}

# Function to find a library in Homebrew
find_brew_lib() {
    local lib_name="$1"

    # Common Homebrew opt paths
    local search_paths=(
        "$HOMEBREW_PREFIX/opt/fontconfig/lib"
        "$HOMEBREW_PREFIX/opt/freetype/lib"
        "$HOMEBREW_PREFIX/opt/fribidi/lib"
        "$HOMEBREW_PREFIX/opt/harfbuzz/lib"
        "$HOMEBREW_PREFIX/opt/glib/lib"
        "$HOMEBREW_PREFIX/opt/graphite2/lib"
        "$HOMEBREW_PREFIX/opt/libiconv/lib"
        "$HOMEBREW_PREFIX/opt/libpng/lib"
        "$HOMEBREW_PREFIX/opt/openssl@3/lib"
        "$HOMEBREW_PREFIX/opt/pcre2/lib"
        "$HOMEBREW_PREFIX/opt/srt/lib"
        "$HOMEBREW_PREFIX/opt/gettext/lib"
        "$HOMEBREW_PREFIX/opt/zlib/lib"
        "$HOMEBREW_PREFIX/opt/expat/lib"
        "$HOMEBREW_PREFIX/opt/brotli/lib"
        "$HOMEBREW_PREFIX/opt/bzip2/lib"
        "$HOMEBREW_PREFIX/opt/xz/lib"
        "$HOMEBREW_PREFIX/lib"
    )

    for search_path in "${search_paths[@]}"; do
        if [ -f "$search_path/$lib_name" ]; then
            echo "$search_path/$lib_name"
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

# ============================================================================
# PASS 1: Collect and bundle all Homebrew dependencies
# ============================================================================
echo ""
echo "📦 Pass 1: Collecting and bundling Homebrew dependencies..."

declare -A HOMEBREW_DEPS  # Associative array to track unique deps

# Function to recursively collect deps from a binary
collect_deps() {
    local binary="$1"
    local deps=$(otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}')

    for dep in $deps; do
        # Skip system paths and already processed
        is_system_path "$dep" && continue

        # Only process Homebrew paths
        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/"* ]]; then
            local lib_name=$(basename "$dep")
            if [ -z "${HOMEBREW_DEPS[$lib_name]}" ]; then
                HOMEBREW_DEPS[$lib_name]="$dep"
                echo "   Found: $lib_name"
            fi
        fi
    done
}

# Collect from all framework binaries
for binary in "${FRAMEWORK_BINARIES[@]}"; do
    echo "   Scanning $(basename "$binary")..."
    collect_deps "$binary"
done

echo ""
echo "   Total unique Homebrew dependencies: ${#HOMEBREW_DEPS[@]}"

# Bundle all collected dependencies and their transitive deps
bundle_with_deps() {
    local original_path="$1"
    local lib_name=$(basename "$original_path")
    local dest_path="$LIBS_DIR/$lib_name"

    # Skip if already bundled
    [ -f "$dest_path" ] && return 0

    # Find the actual file
    local source_path="$original_path"
    if [ ! -f "$source_path" ]; then
        source_path=$(find_brew_lib "$lib_name")
        if [ -z "$source_path" ]; then
            echo "   ⚠️  Warning: Could not find $lib_name, skipping..."
            return 1
        fi
    fi

    echo "   Bundling: $lib_name"
    cp "$source_path" "$dest_path"
    chmod +w "$dest_path"

    # Strip code signature (we'll re-sign later during build)
    codesign --remove-signature "$dest_path" 2>/dev/null || true

    # Recursively bundle its dependencies
    local sub_deps=$(otool -L "$dest_path" 2>/dev/null | tail -n +2 | awk '{print $1}')
    for sub_dep in $sub_deps; do
        is_system_path "$sub_dep" && continue
        if [[ "$sub_dep" == "/opt/homebrew/"* ]] || [[ "$sub_dep" == "/usr/local/"* ]]; then
            bundle_with_deps "$sub_dep"
        fi
    done
}

echo ""
echo "   Bundling libraries..."
for lib_name in "${!HOMEBREW_DEPS[@]}"; do
    bundle_with_deps "${HOMEBREW_DEPS[$lib_name]}"
done

# ============================================================================
# PASS 2: Patch all binaries to use @rpath
# ============================================================================
echo ""
echo "🔧 Pass 2: Patching all binaries to use @rpath..."

patch_binary() {
    local binary="$1"
    local binary_name=$(basename "$binary")

    echo "   Patching: $binary_name"

    # Make writable and strip signature
    chmod +w "$binary"
    codesign --remove-signature "$binary" 2>/dev/null || true

    # Get all current dependencies
    local deps=$(otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}')

    for dep in $deps; do
        local dep_name=$(basename "$dep")

        # Skip system paths
        is_system_path "$dep" && continue

        # Check if this is a Homebrew path we need to patch
        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/"* ]]; then
            # Check if we have this lib bundled
            if [ -f "$LIBS_DIR/$dep_name" ]; then
                echo "      $dep_name: $dep -> @rpath/$dep_name"
                install_name_tool -change "$dep" "@rpath/$dep_name" "$binary" 2>/dev/null || {
                    echo "      ⚠️  Failed to patch $dep_name in $binary_name"
                }
            else
                echo "      ⚠️  $dep_name not bundled, cannot patch"
            fi
        fi
    done
}

# Patch framework binaries
echo ""
echo "   Patching framework binaries..."
for binary in "${FRAMEWORK_BINARIES[@]}"; do
    patch_binary "$binary"
done

# Patch bundled libraries
echo ""
echo "   Patching bundled libraries..."
for lib in "$LIBS_DIR"/*.dylib; do
    [ -f "$lib" ] || continue
    patch_binary "$lib"

    # Also update the library's own ID
    local lib_name=$(basename "$lib")
    install_name_tool -id "@rpath/$lib_name" "$lib" 2>/dev/null || true
done

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "🔍 Verifying patches..."

FAILED=0
for binary in "${FRAMEWORK_BINARIES[@]}"; do
    binary_name=$(basename "$binary")
    if otool -L "$binary" 2>/dev/null | grep -q "/opt/homebrew\|/usr/local"; then
        echo "❌ $binary_name still has hardcoded paths:"
        otool -L "$binary" | grep -E "/opt/homebrew|/usr/local" | head -5
        FAILED=1
    else
        echo "   ✅ $binary_name OK"
    fi
done

if [ "$FAILED" -eq 1 ]; then
    echo ""
    echo "❌ Some binaries still have hardcoded paths. Build may fail on other machines."
    exit 1
fi

# ============================================================================
# Copy to project and update Xcode
# ============================================================================
echo ""
echo "📂 Copying bundled libs to macos/Runner/Frameworks..."
PROJECT_FRAMEWORKS_DIR="macos/Runner/Frameworks"
mkdir -p "$PROJECT_FRAMEWORKS_DIR"

if ls "$LIBS_DIR"/*.dylib 1> /dev/null 2>&1; then
    cp "$LIBS_DIR"/*.dylib "$PROJECT_FRAMEWORKS_DIR/"
    echo "   Copied $(ls "$LIBS_DIR"/*.dylib | wc -l | tr -d ' ') libraries"
else
    echo "   No libraries to copy"
fi

echo ""
echo "📝 Updating Xcode project to embed libraries..."

cat <<'RUBY_EOF' > scripts/update_xcode.rb
require 'xcodeproj'

project_path = 'macos/Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'Runner' }
group = project.main_group['Frameworks'] || project.main_group.new_group('Frameworks')

puts "Adding linker flags..."
target.build_configurations.each do |config|
  config.build_settings['OTHER_LDFLAGS'] ||= '$(inherited)'
  flags = config.build_settings['OTHER_LDFLAGS']
  ['-Wl,-no_warn_duplicate_libraries', '-Wl,-ld_classic'].each do |flag|
    if flags.is_a?(String)
      flags = "#{flags} #{flag}" unless flags.include?(flag)
    elsif flags.is_a?(Array)
      flags << flag unless flags.include?(flag)
    end
  end
  config.build_settings['OTHER_LDFLAGS'] = flags
end

embed_phase = target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' || p.dst_subfolder_spec == 10 }
if embed_phase.nil?
  embed_phase = target.new_copy_files_build_phase('Embed Frameworks')
  embed_phase.dst_subfolder_spec = "10"
end

puts "Cleaning existing dylib references..."
group.files.to_a.each do |file_ref|
  if file_ref.path && file_ref.path.end_with?('.dylib')
    file_ref.remove_from_project
  end
end

frameworks_dir = 'macos/Runner/Frameworks'
Dir.glob("#{frameworks_dir}/*.dylib").each do |file|
  filename = File.basename(file)
  relative_path = file.sub(/^macos\//, '')
  file_ref = group.new_reference(relative_path)
  build_file = embed_phase.add_file_reference(file_ref)
  build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
  puts "   Added #{filename}"
end

project.save
puts "Xcode project updated."
RUBY_EOF

ruby scripts/update_xcode.rb
rm scripts/update_xcode.rb

echo ""
echo "🔄 Forcing pod install update..."
rm -f macos/Podfile.lock

echo ""
echo "✅ FFmpeg macOS fix completed successfully!"
echo "   Bundled libraries are in: $PROJECT_FRAMEWORKS_DIR"
