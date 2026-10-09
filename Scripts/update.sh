#!/bin/zsh
# Source-mode update: pulls the latest code from GitHub, rebuilds with whatever SDKs are on THIS Mac
# (Blackmagic DeckLink, NDI), replaces /Applications/Lumen.app and reopens it.
# Lumen runs this for you from Check for Updates… when it finds the git checkout it was built from.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || brew install xcodegen

# Use the GitHub CLI login for the private repo rather than whatever account the macOS keychain holds.
GIT=(git)
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  GIT=(git -c credential.helper= -c "credential.helper=!gh auth git-credential")
fi
"${GIT[@]}" pull --ff-only

xcodegen generate
xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Release -derivedDataPath build build | tail -1

osascript -e 'quit app "Lumen"' 2>/dev/null || true   # lets Lumen save its library first
for _ in {1..20}; do pgrep -x Lumen >/dev/null || break; sleep 0.5; done
pkill -x Lumen 2>/dev/null || true
rm -rf /Applications/Lumen.app
cp -R build/Build/Products/Release/Lumen.app /Applications/Lumen.app
mkdir -p "$HOME/Library/Application Support/Lumen"
git rev-parse HEAD > "$HOME/Library/Application Support/Lumen/installed-commit"
open /Applications/Lumen.app
echo "Updated to $(git rev-parse --short HEAD)."
