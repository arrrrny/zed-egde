#!/bin/bash

# Script to build Forklift from source

SOURCE_DIR="/Users/ahmettok/Developer/zed"
BINARY_PATH="$SOURCE_DIR/target/release/forklift"
INSTALL_DIR="/Applications/Forklift.app"

# Check for required dependencies
check_dependency() {
    if ! command -v $1 &> /dev/null; then
        echo "$1 is required but not installed."
        if [ "$1" = "pkg-config" ]; then
            echo "Installing pkg-config using Homebrew..."
            if ! command -v brew &> /dev/null; then
                echo "Error: Homebrew is not installed. Please install Homebrew first."
                exit 1
            fi
            brew install pkg-config
        else
            echo "Please install $1 to continue."
            exit 1
        fi
    fi
}

# Check for required tools
check_dependency "pkg-config"

# Use local directory
if [ ! -d "$SOURCE_DIR" ]; then
  echo "Error: Source directory $SOURCE_DIR does not exist"
  exit 1
fi

# Build the project
cd "$SOURCE_DIR"
echo "Building Forklift..."
cargo build --release

# Install the binary
if [ -f "$BINARY_PATH" ]; then
  echo "Installing Forklift..."
  mkdir -p "$INSTALL_DIR/Contents/MacOS"
  cp "$BINARY_PATH" "$INSTALL_DIR/Contents/MacOS/"
  echo "Forklift has been installed to $INSTALL_DIR"
else
  echo "Build failed. Binary not found."
  exit 1
fi