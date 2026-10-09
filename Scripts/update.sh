#!/bin/zsh
# Source-mode update: fetches the newest release tag from GitHub, rebuilds with whatever SDKs are on THIS Mac
# (Blackmagic DeckLink, NDI), swaps /Applications/Lumen.app and reopens it.
# Lumen runs this for you from Check for Updates… when it finds the git checkout it was built from.
#
# Safety: it only builds a tagged release (never an unfinished commit on main), it never quits Lumen while
# something is on the outputs (it waits, then gives up), and it keeps the old app until the new one starts.
set -euo pipefail
cd "$(dirname "$0")/.."
SUPPORT="$HOME/Library/Application Support/Lumen"
command -v xcodegen >/dev/null || brew install xcodegen

# Use the GitHub CLI login for the private repo rather than whatever account the macOS keychain holds.
GIT=(git)
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  GIT=(git -c credential.helper= -c "credential.helper=!gh auth git-credential")
fi
"${GIT[@]}" fetch --tags origin main
TAG=$(git tag -l 'v*' --sort=-v:refname | head -1)
if [ -n "$TAG" ]; then
  echo "Updating to release $TAG"
  git merge --ff-only "$TAG"
else
  echo "No release tags yet; updating to origin/main"
  git merge --ff-only origin/main
fi

xcodegen generate
xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Release -derivedDataPath build build | tail -1
NEW="build/Build/Products/Release/Lumen.app"
[ -d "$NEW" ] || { echo "Build failed; leaving the installed Lumen untouched."; exit 1; }

# The build takes minutes. Re-check, right now, that the show isn't live before touching the running app.
waited=0
while [ -e "$SUPPORT/live" ]; do
  if [ $waited -ge 1800 ]; then echo "Lumen has had something on screen for 30 minutes; not updating. Run this again later."; exit 1; fi
  [ $waited -eq 0 ] && echo "Lumen is live (something is on the outputs). Waiting for a break before restarting it…"
  sleep 5; waited=$((waited + 5))
done

osascript -e 'quit app "Lumen"' 2>/dev/null || true   # lets Lumen save its library first
for _ in {1..20}; do pgrep -x Lumen >/dev/null || break; sleep 0.5; done
pgrep -x Lumen >/dev/null && { echo "Lumen didn't quit (is something live?). Not updating."; exit 1; }

APP=/Applications/Lumen.app
rm -rf "$APP.old"
[ -d "$APP" ] && mv "$APP" "$APP.old"
if ! ditto "$NEW" "$APP"; then rm -rf "$APP"; [ -d "$APP.old" ] && mv "$APP.old" "$APP"; open "$APP"; echo "Copy failed; restored the previous version."; exit 1; fi
mkdir -p "$SUPPORT"
git rev-list -n 1 "${TAG:-origin/main}" > "$SUPPORT/installed-commit"
open "$APP"

# Keep the previous version until the new one has stayed up for 12 seconds.
up=0; ok=0
for _ in {1..40}; do
  sleep 1
  if pgrep -x Lumen >/dev/null; then up=$((up + 1)); else up=0; fi
  if [ $up -ge 12 ]; then ok=1; break; fi
done
if [ $ok = 1 ]; then
  rm -rf "$APP.old"
  echo "Updated to ${TAG:-$(git rev-parse --short HEAD)}."
else
  echo "The new version didn't stay running; restoring the previous one."
  pkill -x Lumen 2>/dev/null || true; sleep 1
  rm -rf "$APP"; [ -d "$APP.old" ] && mv "$APP.old" "$APP"; open "$APP"
  exit 1
fi
