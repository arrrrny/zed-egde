#!/bin/bash
# quick_build_debug.sh - Simple script to build and install ZED in debug mode without any checks
# Assumes the repository is already cloned and up to date

# Configuration
CLONE_DIR="$HOME/zed_build"
INSTALL_DIR="/Applications/ZED EDGE.app"
BINARY_PATH="$CLONE_DIR/target/debug/zed"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_LOGO_PATH="$SCRIPT_DIR/zed_edge_logo.png"
WRAPPER_NAME="zed"
SYMLINK_PATH="/usr/local/bin/$WRAPPER_NAME"

# Check if repo exists
if [ ! -d "$CLONE_DIR" ]; then
  echo "Error: Repository directory does not exist at $CLONE_DIR"
  echo "Please run the full build script first to clone the repository."
  exit 1
fi

# Set log level for debug output (only show deepseek debug logs)
export RUST_LOG=language_models::provider::deepseek=debug
# Optionally, set up env_logger if needed (for Rust apps)
# export RUST_LOG_STYLE=always

# Build ZED (debug)
build_zed() {
  echo "Building ZED in debug mode..."
  cd "$CLONE_DIR"

  # Set environment variables for faster compilation
  export RUSTFLAGS="-C target-cpu=native"
  export CARGO_INCREMENTAL=1

  # Configure cargo to use all available cores
  cores=$(sysctl -n hw.ncpu)
  cores=${cores:-4} # Default if we can't detect

  echo "Using $cores CPU cores for build..."

  # Run the build in debug mode
  echo "This may take a while..."
  cargo build

  if [ $? -ne 0 ]; then
    echo "Build failed."
    exit 1
  fi

  echo "Build completed successfully."
}

run_zed() {
  echo "Running ZED in debug mode..."
  "$BINARY_PATH"
}

# Main execution
echo "🔨 Starting debug build process..."
build_zed
echo "🚀 Running ZED EDGE in debug mode..."
run_zed

echo "✅ Quick debug build and run completed successfully!"
