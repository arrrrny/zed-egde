# Script to build ZED editor from source for macOS with continuous update checking

ZED_REPO="zed-industries/zed"
CLONE_URL="git@github.com:zed-industries/zed.git"
CLONE_DIR="$HOME/zed_build"
INSTALL_DIR="/Applications/ZED EDGE.app"
SYMLINK_PATH="/usr/local/bin/zed"
BINARY_PATH="$CLONE_DIR/target/release/zed"
LOCAL_COMMIT_FILE="$CLONE_DIR/.last_built_commit"
CHECK_INTERVAL=60 # Check for updates every minute
BUILD_STATUS_FILE="/tmp/zed_build_status"
RUST_CACHE_DIR="$HOME/.cargo" # For caching dependencies
BUILD_PID_FILE="/tmp/zed_build.pid"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_LOGO_PATH="$SCRIPT_DIR/zed_edge_logo.png"
DEFAULT_WRAPPER_NAME="zed"

# Create a trap to cleanup on exit
cleanup() {
  echo "Cleaning up temporary files..."
  rm -f "$BUILD_STATUS_FILE" "$BUILD_PID_FILE"

  # Kill the update checker if it's running
  if [ -n "$UPDATE_CHECKER_PID" ]; then
    kill $UPDATE_CHECKER_PID 2>/dev/null || true
  fi

  echo "Cleanup completed."
}

trap cleanup EXIT INT TERM

# Check dependencies and suggest installation methods
check_dependencies() {
  echo "Checking dependencies..."

  missing_deps=()

  # Check each required dependency
  for cmd in git cargo node cmake; do
    if ! command -v $cmd &> /dev/null; then
      missing_deps+=("$cmd")
    fi
  done

  # If there are missing dependencies, suggest installation methods and exit
  if [ ${#missing_deps[@]} -gt 0 ]; then
    echo "Error: The following dependencies are missing:"
    for dep in "${missing_deps[@]}"; do
      echo "  - $dep"
    done

    echo -e "\nInstallation instructions:"
    echo "  For git: brew install git"
    echo "  For cargo: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    echo "  For node: brew install node"
    echo "  For cmake: brew install cmake"
    echo -e "\nPlease install the missing dependencies and try again."
    exit 1
  fi

  echo "All dependencies are installed."
}

# Get latest commit hash from main branch
get_latest_commit() {
    if [ -d "$CLONE_DIR" ]; then
        echo "Updating existing repository..."
        cd "$CLONE_DIR"
        git fetch origin main
        latest_commit=$(git rev-parse origin/main)
    else
        echo "Getting latest commit from remote repository..."
        latest_commit=$(git ls-remote "$CLONE_URL" main | cut -f1)
    fi

  if [ -z "$latest_commit" ]; then
    echo "Failed to fetch latest commit."
    return 1
  fi

  echo "Latest commit on main branch: $latest_commit"
  return 0
}

# Get current installed version and commit
get_current_version() {
  if [ -e "$INSTALL_DIR/Contents/Info.plist" ]; then
    current_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INSTALL_DIR/Contents/Info.plist" 2>/dev/null || echo "unknown")
    echo "Currently installed version: $current_version"
  else
    echo "ZED is not currently installed in Applications folder"
  fi

  # Check if we have a record of last built commit
  if [ -f "$LOCAL_COMMIT_FILE" ]; then
    current_commit=$(cat "$LOCAL_COMMIT_FILE")
    echo "Last built commit: ${current_commit:0:8}"
  else
    current_commit=""
    echo "No record of previously built commit"
  fi
}

# Check if we need to build by comparing commits
check_for_updates() {
  if [ -z "$current_commit" ]; then
    echo "No previous build detected. Proceeding with build..."
    return 0
  fi

  if [ "$current_commit" == "$latest_commit" ]; then
    echo "You already have the latest version built (commit ${latest_commit:0:8})."
    read -p "Do you want to rebuild anyway? (y/N): " rebuild
    if [[ $rebuild != "y" && $rebuild != "Y" ]]; then
      echo "Build skipped. You can run the existing binary with: $BINARY_PATH"
      exit 0
    fi
    echo "Proceeding with rebuild..."
  else
    echo "New version available (your build: ${current_commit:0:8}, latest: ${latest_commit:0:8})"
    read -p "Do you want to build the latest version? (Y/n): " build_latest
    if [[ $build_latest == "n" || $build_latest == "N" ]]; then
      echo "Build skipped. You can run the existing binary with: $BINARY_PATH"
      exit 0
    fi
    echo "Proceeding with build of latest version..."
  fi

  return 0
}

# Clone or update the repository
setup_repository() {
  if [ ! -d "$CLONE_DIR" ]; then
    echo "Cloning ZED repository..."
    git clone "$CLONE_URL" "$CLONE_DIR"
    if [ $? -ne 0 ]; then
      echo "Failed to clone repository."
      echo "If you're having SSH issues, you can try using HTTPS instead by modifying CLONE_URL in the script to:"
      echo "https://github.com/zed-industries/zed.git"
      exit 1
    fi
  else
    echo "Updating ZED repository..."
    cd "$CLONE_DIR"
    git checkout main
    git pull origin main
    if [ $? -ne 0 ]; then
      echo "Failed to update repository."
      exit 1
    fi
  fi

  # Save the current commit we're building from
  current_build_commit=$(git rev-parse HEAD)
  echo "$current_build_commit" > "$BUILD_STATUS_FILE"

  echo "Repository is up to date."
}

# Function to check for updates continuously
check_for_updates_during_build() {
  local current_build_commit="$1"
  local build_pid="$2"

  echo "Starting update checker with PID $$"
  echo $$ > "$BUILD_PID_FILE"

  while true; do
    # Sleep for the check interval
    sleep $CHECK_INTERVAL

    # Check if the build process is still running
    if ! ps -p $build_pid > /dev/null; then
      echo "Build process completed or terminated. Stopping update checker."
      break
    fi

    # Check for new commits
    cd "$CLONE_DIR" || {
      echo "Error: Could not change to repository directory."
      continue
    }

    # Fetch updates with error handling
    if ! git fetch origin main; then
      echo "Warning: Failed to fetch updates, will try again in $CHECK_INTERVAL seconds..."
      continue
    fi

    latest_remote_commit=$(git rev-parse origin/main)

    if [ -z "$latest_remote_commit" ]; then
      echo "Warning: Failed to get latest commit hash, will try again in $CHECK_INTERVAL seconds..."
      continue
    fi

    if [ "$latest_remote_commit" != "$current_build_commit" ]; then
      echo "⚠️ New commit detected during build! ⚠️"
      echo "Current building: ${current_build_commit:0:8}"
      echo "New commit available: ${latest_remote_commit:0:8}"

      # Kill the build process
      echo "Stopping current build to start fresh with the latest code..."
      kill $build_pid

      # Update the build status file
      echo "RESTART_NEEDED" > "$BUILD_STATUS_FILE"
      break
    else
      echo "No new commits detected. Continuing build... [$(date)]"
    fi
  done
}

# Optimize Rust build
optimize_rust_build() {
  # Set environment variables for faster compilation
  export RUSTFLAGS="-C target-cpu=native"

  # Enable incremental compilation for faster rebuilds
  export CARGO_INCREMENTAL=1

  echo "Using standard Rust compilation with incremental builds..."

  # Configure cargo to use all available cores
  cores=$(sysctl -n hw.ncpu)
  if [ -z "$cores" ]; then
    cores=4 # Default if we can't detect
  fi

  # Create or update Cargo config for better performance
  mkdir -p "$CLONE_DIR/.cargo"
  cat > "$CLONE_DIR/.cargo/config.toml" << EOF
[build]
jobs = $cores
# Let environment variable control incremental compilation

[target.x86_64-apple-darwin]
rustflags = ["-C", "target-cpu=native"]

[target.aarch64-apple-darwin]
rustflags = ["-C", "target-cpu=native"]

[profile.release]
codegen-units = 1
lto = "thin"
debug = false
strip = true  # Strip symbols for smaller binary

[cache]
# Shared cache for sccache
dir = "$RUST_CACHE_DIR/sccache"
EOF

  # Ensure cache directories exist with proper permissions
  mkdir -p "$RUST_CACHE_DIR/sccache"

  echo "Optimized Rust build configuration created with $cores cores."
}

# Build ZED using Rust with --release flag
build_zed() {
  echo "Building ZED with --release flag..."
  cd "$CLONE_DIR"

  # Apply build optimizations
  optimize_rust_build

  # Get the current build commit
  current_build_commit=$(cat "$BUILD_STATUS_FILE")

  # Start the update checker in background
  check_for_updates_during_build "$current_build_commit" $$ &
  UPDATE_CHECKER_PID=$!

  # Run the build with release flag
  echo "This may take a while..."
  cargo build --release
  build_result=$?

  # Kill the update checker
  if [ -n "$UPDATE_CHECKER_PID" ]; then
    kill $UPDATE_CHECKER_PID 2>/dev/null || true
  fi

  # Check if we need to restart the build due to new commits
  if [ -f "$BUILD_STATUS_FILE" ] && [ "$(cat "$BUILD_STATUS_FILE")" == "RESTART_NEEDED" ]; then
    echo "Build was interrupted because new code is available."
    echo "Restarting build process with the latest code..."
    exec "$0" # Restart the entire script
    exit 0
  fi

  if [ $build_result -ne 0 ]; then
    echo "Build failed."
    exit 1
  fi

  # Store the commit hash we just built
  echo "$current_build_commit" > "$LOCAL_COMMIT_FILE"

  echo "Build completed successfully."
}


# Install the built application
install_zed() {
  echo "Installing ZED..."

  # Check if the binary exists
  if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Binary not found at $BINARY_PATH"
    echo "The build may have completed but the output is not where expected."
    exit 1
  fi

  # Create app structure if needed and install
  APP_STRUCTURE=false

  # First check if a Zed.app bundle was created in the build output
  if [ -d "$CLONE_DIR/target/release/Zed.app" ]; then
    echo "Found Zed.app bundle in build output."
    APP_STRUCTURE=true

    # Backup any existing installation
    if [ -d "$INSTALL_DIR" ]; then
      echo "Backing up existing installation..."
      # Remove old backup if it exists
      if [ -d "$INSTALL_DIR.bak" ]; then
        echo "Removing old backup..."
        sudo rm -rf "$INSTALL_DIR.bak" 2>/dev/null
      fi
      # Create backup of current installation
      echo "Creating backup of current installation to $INSTALL_DIR.bak"
      sudo cp -R "$INSTALL_DIR" "$INSTALL_DIR.bak"
      # Now remove the current installation
      echo "Removing existing installation..."
      sudo rm -rf "$INSTALL_DIR" 2>/dev/null
    fi

    # Create a temporary copy to customize
    TMP_BUNDLE="$CLONE_DIR/ZED EDGE.app"
    echo "Creating customized app bundle..."
    cp -R "$CLONE_DIR/target/release/Zed.app" "$TMP_BUNDLE"

    # Use the logo file
    echo "Adding ZED EDGE logo to app bundle..."
    mkdir -p "$TMP_BUNDLE/Contents/Resources"

    # Convert PNG to ICNS
    TMP_ICONSET="$CLONE_DIR/tmp.iconset"
    mkdir -p "$TMP_ICONSET"
    echo $LOCAL_LOGO_PATH
    # Generate different sizes
    sips -z 16 16 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_16x16.png" &>/dev/null
    sips -z 32 32 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_16x16@2x.png" &>/dev/null
    sips -z 32 32 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_32x32.png" &>/dev/null
    sips -z 64 64 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_32x32@2x.png" &>/dev/null
    sips -z 128 128 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_128x128.png" &>/dev/null
    sips -z 256 256 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_128x128@2x.png" &>/dev/null
    sips -z 256 256 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_256x256.png" &>/dev/null
    sips -z 512 512 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_256x256@2x.png" &>/dev/null
    sips -z 512 512 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_512x512.png" &>/dev/null
    sips -z 1024 1024 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_512x512@2x.png" &>/dev/null

    # Convert to icns
    iconutil -c icns "$TMP_ICONSET" -o "$TMP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$TMP_ICONSET"

    # Update app display name in Info.plist
    if [ -f "$TMP_BUNDLE/Contents/Info.plist" ]; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 'ZED EDGE'" "$TMP_BUNDLE/Contents/Info.plist" 2>/dev/null
      /usr/libexec/PlistBuddy -c "Set :CFBundleName 'ZED EDGE'" "$TMP_BUNDLE/Contents/Info.plist" 2>/dev/null
      # Set the icon file name explicitly
      /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$TMP_BUNDLE/Contents/Info.plist" 2>/dev/null
    fi

    # Copy the customized app to the Applications directory
    sudo cp -R "$TMP_BUNDLE" "$INSTALL_DIR"
    rm -rf "$TMP_BUNDLE"

    if [ $? -ne 0 ]; then
      echo "Installation failed. You may need admin privileges to copy to /Applications."
      exit 1
    fi

    # Touch the application to clear icon cache
    sudo touch "$INSTALL_DIR"

    # Create wrapper script for CLI access
    echo "Creating command-line wrapper script..."
    # First remove existing symlink or file if present
    sudo rm -f "$SYMLINK_PATH"
    # Create a simple wrapper script if user wanted it
    if [ "$CREATE_CLI_WRAPPER" = true ]; then
      echo "Creating command-line wrapper at $SYMLINK_PATH..."
      sudo echo '#!/bin/bash' > "$SYMLINK_PATH"
      sudo echo 'if [ $# -eq 0 ]; then' >> "$SYMLINK_PATH"
      sudo echo '    # No arguments, just open the app' >> "$SYMLINK_PATH"
      sudo echo '    open "/Applications/ZED EDGE.app"' >> "$SYMLINK_PATH"
      sudo echo 'else' >> "$SYMLINK_PATH"
      sudo echo '    # Open with arguments' >> "$SYMLINK_PATH"
      sudo echo '    open -a "ZED EDGE" "$@"' >> "$SYMLINK_PATH"
      sudo echo 'fi' >> "$SYMLINK_PATH"
      # Make sure it's executable
      sudo chmod +x "$SYMLINK_PATH"
    fi
  else
    echo "No Zed.app bundle found in build output. Creating one now..."

    # Create a temporary app bundle structure
    TMP_APP_DIR="$CLONE_DIR/ZED EDGE.app"
    mkdir -p "$TMP_APP_DIR/Contents/MacOS"
    mkdir -p "$TMP_APP_DIR/Contents/Resources"

    # Create Info.plist
    cat > "$TMP_APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>zed</string>
    <key>CFBundleIdentifier</key>
    <string>dev.zed.Zed</string>
    <key>CFBundleName</key>
    <string>ZED EDGE</string>
    <key>CFBundleDisplayName</key>
    <string>ZED EDGE</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.14</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

    # Copy the binary to the app bundle
    cp "$BINARY_PATH" "$TMP_APP_DIR/Contents/MacOS/"

    # Use ZED EDGE logo
    echo "Adding ZED EDGE logo to app bundle..."

    # Convert PNG to ICNS
    TMP_ICONSET="$CLONE_DIR/tmp.iconset"
    mkdir -p "$TMP_ICONSET"

    # Generate different sizes
    sips -z 16 16 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_16x16.png" &>/dev/null
    sips -z 32 32 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_16x16@2x.png" &>/dev/null
    sips -z 32 32 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_32x32.png" &>/dev/null
    sips -z 64 64 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_32x32@2x.png" &>/dev/null
    sips -z 128 128 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_128x128.png" &>/dev/null
    sips -z 256 256 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_128x128@2x.png" &>/dev/null
    sips -z 256 256 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_256x256.png" &>/dev/null
    sips -z 512 512 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_256x256@2x.png" &>/dev/null
    sips -z 512 512 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_512x512.png" &>/dev/null
    sips -z 1024 1024 "$LOCAL_LOGO_PATH" --out "$TMP_ICONSET/icon_512x512@2x.png" &>/dev/null

    # Convert to icns
    iconutil -c icns "$TMP_ICONSET" -o "$TMP_APP_DIR/Contents/Resources/AppIcon.icns"
    rm -rf "$TMP_ICONSET"

    # Backup any existing installation
    if [ -d "$INSTALL_DIR" ]; then
      echo "Backing up existing installation..."
      # Remove old backup if it exists
      if [ -d "$INSTALL_DIR.bak" ]; then
        echo "Removing old backup..."
        sudo rm -rf "$INSTALL_DIR.bak" 2>/dev/null
      fi
      # Create backup of current installation
      echo "Creating backup of current installation to $INSTALL_DIR.bak"
      sudo cp -R "$INSTALL_DIR" "$INSTALL_DIR.bak"
      # Now remove the current installation
      echo "Removing existing installation..."
      sudo rm -rf "$INSTALL_DIR" 2>/dev/null
    fi

    # Copy the app bundle to the Applications directory
    echo "Installing ZED EDGE.app to Applications folder..."
    sudo cp -R "$TMP_APP_DIR" "$INSTALL_DIR"

    if [ $? -ne 0 ]; then
      echo "Installation failed. You may need admin privileges to copy to /Applications."
      exit 1
    fi

    # Clean up temporary app bundle
    rm -rf "$TMP_APP_DIR"

    # Touch the application to clear icon cache
    sudo touch "$INSTALL_DIR"

    # Create wrapper script for CLI access if user wanted it
    if [ "$CREATE_CLI_WRAPPER" = true ]; then
      echo "Creating command-line wrapper at $SYMLINK_PATH..."
      # First remove existing symlink or file if present
      sudo rm -f "$SYMLINK_PATH"
      # Create a simple wrapper script
      sudo echo '#!/bin/bash' > "$SYMLINK_PATH"
      sudo echo 'if [ $# -eq 0 ]; then' >> "$SYMLINK_PATH"
      sudo echo '    # No arguments, just open the app' >> "$SYMLINK_PATH"
      sudo echo '    open "/Applications/ZED EDGE.app"' >> "$SYMLINK_PATH"
      sudo echo 'else' >> "$SYMLINK_PATH"
      sudo echo '    # Open with arguments' >> "$SYMLINK_PATH"
      sudo echo '    open -a "ZED EDGE" "$@"' >> "$SYMLINK_PATH"
      sudo echo 'fi' >> "$SYMLINK_PATH"
      # Make sure it's executable
      sudo chmod +x "$SYMLINK_PATH"
    fi

    APP_STRUCTURE=true
  fi

  echo "Installation completed successfully."

  # Force macOS to clear icon caches and refresh the Dock
  echo "Clearing icon caches and refreshing Dock..."

  # Clear icon caches
  sudo rm -rf /Library/Caches/com.apple.iconservices.store
  sudo find /private/var/folders/ -name com.apple.dock.iconcache -exec rm -rf {} \; 2>/dev/null || true
  sudo find /private/var/folders/ -name com.apple.iconservices -exec rm -rf {} \; 2>/dev/null || true

  # Restart icon services and Finder
  sudo killall iconservicesd
  killall Finder

  # Wait a moment for services to restart
  sleep 3

  # Force the Dock to add the app and restart
  if [ "$APP_STRUCTURE" = true ]; then
    echo "Launching ZED EDGE..."
    # Launch the app
    open "$INSTALL_DIR"
    echo "ZED EDGE has been launched! You can also run it from your Applications folder or using the command: $WRAPPER_NAME"
  else
    echo "Launching ZED EDGE..."
    # Launch the binary directly
    "$BINARY_PATH" &
    echo "ZED EDGE has been launched! You can also run it directly using: $BINARY_PATH"
  fi
}

# Main execution
main() {
  check_dependencies

  # Ask user if they want to create a command-line wrapper
  echo "ZED EDGE can be launched from the command line using a wrapper script."
  read -p "Would you like to create a command-line wrapper? (Y/n): " create_wrapper
  if [[ $create_wrapper == "n" || $create_wrapper == "N" ]]; then
    CREATE_CLI_WRAPPER=false
    echo "Command-line wrapper will not be created."
  else
    CREATE_CLI_WRAPPER=true

    # Ask for wrapper name
    read -p "Enter the name for the command line wrapper (default: $DEFAULT_WRAPPER_NAME): " wrapper_name
    WRAPPER_NAME=${wrapper_name:-$DEFAULT_WRAPPER_NAME}
    SYMLINK_PATH="/usr/local/bin/$WRAPPER_NAME"

    echo "Command-line wrapper will be created as: $WRAPPER_NAME"
  fi
  export CREATE_CLI_WRAPPER
  export WRAPPER_NAME
  export SYMLINK_PATH

  if ! get_latest_commit; then
    echo "Failed to get latest commit information."
    exit 1
  fi

  get_current_version
  check_for_updates

  setup_repository
  build_zed
  install_zed

  echo "ZED EDGE has been successfully built from the main branch."
  
  # Display backup information if a backup was created
  if [ -d "$INSTALL_DIR.bak" ]; then
    echo ""
    echo "---------------------------------------------------------------------"
    echo "A backup of your previous ZED EDGE installation has been saved to:"
    echo "$INSTALL_DIR.bak"
    echo ""
    echo "To restore from backup, you can run:"
    echo "sudo rm -rf \"$INSTALL_DIR\" && sudo mv \"$INSTALL_DIR.bak\" \"$INSTALL_DIR\""
    echo "---------------------------------------------------------------------"
  fi
}

# Run the script
main
