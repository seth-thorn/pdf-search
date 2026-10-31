#!/bin/bash
# Double-click to build PDF Search into /Applications.
cd "$(dirname "$0")"
{
  echo "=== $(date)"; sw_vers 2>/dev/null; swiftc --version 2>&1
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Apple's developer tools aren't installed yet — a window will ask to install them."
    echo "Click Install, wait for it to finish, then double-click this file again."
    xcode-select --install
    exit 1
  fi
  bash build.sh
} 2>&1 | tee build.log
if [ "${PIPESTATUS[0]}" -eq 0 ]; then
  echo; echo "Done — opening PDF Search."
  open "$(grep '^Built: ' build.log | tail -1 | cut -d' ' -f2-)"
else
  echo; echo "The build hit a problem — see build.log in this folder for details."
fi
