#!/bin/bash

echo "Setting up Capsule dependencies for Linux..."

# Update package list
sudo apt-get update

# Install Flutter Linux requirements
echo "Installing Flutter Linux requirements..."
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev

# Install MediaKit dependencies (libmpv)
echo "Installing MediaKit dependencies..."
sudo apt-get install -y libmpv-dev mpv

# Install FFmpeg (required for video processing)
echo "Installing FFmpeg..."
sudo apt-get install -y ffmpeg

# Install Camera dependencies (GStreamer)
echo "Installing Camera dependencies..."
sudo apt-get install -y libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly gstreamer1.0-libav gstreamer1.0-tools \
    gstreamer1.0-x gstreamer1.0-alsa gstreamer1.0-gl

echo "Setup complete! You can now run the app with 'flutter run -d linux'"