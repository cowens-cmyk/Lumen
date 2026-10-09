#!/bin/zsh
# Publishes a new version:  Scripts/release.sh 0.3.0 "What changed"
# Bumps the version, builds the signed DMG, commits, tags, pushes, and creates a GitHub release with the DMG
# attached. Every Mac running Lumen then offers the update (toolbar button + Lumen ▸ Check for Updates…).
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-Lumen $V}"
REPO="cowens-cmyk/Lumen"
# Always publish as the church account, whichever gh account is active.
export GH_TOKEN="${GH_TOKEN:-$(gh auth token --hostname github.com --user cowens-cmyk 2>/dev/null || gh auth token)}"

BUILD=$(( $(grep -E '^ *CURRENT_PROJECT_VERSION:' project.yml | head -1 | tr -dc '0-9') + 1 ))
sed -i '' -E "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$V\"/; s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
./Scripts/make_dmg.sh
git add -A
git diff --cached --quiet || git commit -m "Release $V" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git tag "v$V"
git -c credential.helper= -c "credential.helper=!gh auth git-credential" push origin main "v$V"
gh release create "v$V" "dist/Lumen-$V.dmg" --repo "$REPO" --title "Lumen $V" --notes "$NOTES"
echo "Released $V"
