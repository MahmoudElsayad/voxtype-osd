#!/bin/sh
# Sets up Voxtype and VoxtypeOSD on a Mac. Safe to run again; finished steps are skipped.
set -eu
cd "$(dirname "$0")"

model="${VOXTYPE_MODEL:-large-v3-turbo}"

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }
command -v swiftc >/dev/null || { echo "Xcode Command Line Tools are required: xcode-select --install"; exit 1; }

if ! command -v voxtype >/dev/null; then
  echo "Installing Voxtype..."
  brew install --cask peteonrails/voxtype/voxtype
fi

if ! voxtype setup model --list 2>/dev/null | grep -q "$model"; then
  echo "Downloading the $model speech model..."
  voxtype setup --download --model "$model" --no-post-install
fi

# The app must exist before Voxtype's configuration points its post-process command at it.
./install.sh

configured=$(python3 -I setup/configure-voxtype.py)
echo "$configured"

if ! voxtype setup app-bundle --status 2>/dev/null | grep -q "App installed"; then
  voxtype setup app-bundle
elif [ "${configured#Updated}" != "$configured" ]; then
  echo "Restart Voxtype to load the new configuration: quit Voxtype from its menu bar icon, then open /Applications/Voxtype.app."
fi

if launchctl list | grep -q 'io.voxtype.daemon$'; then
  echo
  echo "Warning: a launchd agent (io.voxtype.daemon) also runs Voxtype."
  echo "It conflicts with Voxtype.app and stops the level meter and history from updating."
  echo "Remove it with: launchctl bootout gui/\$(id -u)/io.voxtype.daemon && rm ~/Library/LaunchAgents/io.voxtype.daemon.plist"
fi

cat <<'NEXT'

Next steps:
1. System Settings > Privacy & Security > Accessibility: turn on Voxtype and VoxtypeOSD.
2. System Settings > Privacy & Security > Input Monitoring: turn on Voxtype.
3. Hold right Command and speak. Allow Microphone access when macOS asks.
Open Settings from the gear in the VoxtypeOSD menu bar panel to change the keys.
NEXT
