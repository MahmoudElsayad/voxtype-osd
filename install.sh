#!/bin/sh
# Builds the app, copies it to ~/Applications, opens it, and adds it to Login Items.
set -eu
cd "$(dirname "$0")"
if ! command -v media-control >/dev/null 2>&1 &&
   [ ! -x /opt/homebrew/bin/media-control ] && [ ! -x /usr/local/bin/media-control ]; then
  brew_path=$(command -v brew || true)
  if [ -z "$brew_path" ]; then
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [ -x "$candidate" ]; then brew_path="$candidate"; break; fi
    done
  fi
  if [ -z "$brew_path" ]; then
    echo "Install Homebrew from https://brew.sh, then run ./install.sh again." >&2
    exit 1
  fi
  "$brew_path" install media-control
fi
./build.sh

target="$HOME/Applications/VoxtypeOSD.app"
pid=$(pgrep -f "$target/Contents/MacOS/VoxtypeOSD" || true)
if [ -n "$pid" ]; then
  kill $pid
  # Opening the app while the old copy is still quitting fails with error -600.
  while kill -0 $pid 2>/dev/null; do sleep 0.2; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$target"
cp -R build/VoxtypeOSD.app "$target"
if ! open "$target"; then
  # Launch Services can still consider the previous instance to be quitting.
  sleep 1
  open "$target"
fi

osascript -e 'tell application "System Events"' \
  -e 'if not (exists login item "VoxtypeOSD") then make login item at end with properties {path:"'"$target"'", hidden:true}' \
  -e 'end tell' >/dev/null
echo "Installed $target"
