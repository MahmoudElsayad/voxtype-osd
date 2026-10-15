#!/bin/sh
# Builds the app, copies it to ~/Applications, opens it, and adds it to Login Items.
set -eu
cd "$(dirname "$0")"
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
open "$target"

osascript -e 'tell application "System Events"' \
  -e 'if not (exists login item "VoxtypeOSD") then make login item at end with properties {path:"'"$target"'", hidden:true}' \
  -e 'end tell' >/dev/null
echo "Installed $target"
