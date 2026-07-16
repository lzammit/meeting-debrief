#!/usr/bin/env bash
# Save the current clipboard image to docs/screenshots/<name>.png
# Usage: copy a screenshot to the clipboard (⌘⇧⌃4), then: ./tools/save-clip.sh main
set -euo pipefail
name="${1:?usage: save-clip.sh <name>  (e.g. main, popup, settings, transcript)}"
dir="$(cd "$(dirname "$0")/../docs/screenshots" && pwd)"
osascript >/dev/null 2>&1 \
  -e "set p to (POSIX file \"$dir/$name.png\")" \
  -e "set d to (the clipboard as «class PNGf»)" \
  -e "set fh to open for access p with write permission" \
  -e "set eof fh to 0" -e "write d to fh" -e "close access fh"
echo "saved $dir/$name.png"
