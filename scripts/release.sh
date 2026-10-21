#!/bin/bash
# Cuts a release: CHANGELOG's Unreleased becomes <version>, README's What's new follows,
# Info.plist gets the new version, the app is tested, built and zipped, and the result is
# committed and tagged. Pushing and the GitHub release happen only after you confirm.
#
#   scripts/release.sh 0.2.0            release
#   scripts/release.sh 0.2.0 --dry-run  show what would change, then put everything back
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
DRY_RUN="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/release.sh <major.minor.patch> [--dry-run]" >&2
  exit 1
fi

PLIST=Resources/Info.plist
DATE="$(date +%Y-%m-%d)"
ZIP="build/Kabuk-$VERSION.zip"

if [[ "$DRY_RUN" != "--dry-run" ]]; then
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "Releases are cut from main." >&2; exit 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "The working tree has uncommitted changes." >&2; exit 1; }
  ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "Tag v$VERSION already exists." >&2; exit 1; }
fi
python3 scripts/changelog.py unreleased || { echo "CHANGELOG.md has nothing under Unreleased." >&2; exit 1; }

BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"

apply() {
  python3 scripts/changelog.py release "$VERSION" "$DATE"
  python3 scripts/changelog.py readme "$VERSION"
  # In place, so the plist keeps its layout (PlistBuddy would rewrite the whole file).
  SHORT="$VERSION" BUNDLE="$((BUILD + 1))" perl -0pi -e '
    s|(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*|$1$ENV{SHORT}|;
    s|(<key>CFBundleVersion</key>\s*<string>)[^<]*|$1$ENV{BUNDLE}|' "$PLIST"
}

if [[ "$DRY_RUN" == "--dry-run" ]]; then
  BACKUP="$(mktemp -d)"
  cp CHANGELOG.md README.md "$PLIST" "$BACKUP/"
  trap 'cp "$BACKUP/CHANGELOG.md" "$BACKUP/README.md" .; cp "$BACKUP/Info.plist" "$PLIST"; rm -rf "$BACKUP"' EXIT
  apply
  git --no-pager diff -- CHANGELOG.md README.md "$PLIST"
  echo
  echo "Release notes for v$VERSION:"
  python3 scripts/changelog.py notes "$VERSION"
  echo
  echo "Dry run: nothing was committed, and the files are back as they were."
  exit 0
fi

apply
swift test
scripts/build-app.sh release
rm -f "$ZIP"
ditto -c -k --keepParent build/Kabuk.app "$ZIP"

git add CHANGELOG.md README.md "$PLIST"
git commit -m "Release $VERSION"
git tag -a "v$VERSION" -m "Kabuk $VERSION"
echo "Committed and tagged v$VERSION. The app is at $ZIP."

read -r -p "Push main and v$VERSION, and publish the GitHub release? [y/N] " answer
if [[ "$answer" != [yY] ]]; then
  echo "Not pushed. When ready: git push origin main v$VERSION, then rerun the gh release command below."
  echo "  gh release create v$VERSION $ZIP --title \"Kabuk $VERSION\" --notes-file <(python3 scripts/changelog.py notes $VERSION)"
  exit 0
fi
git push origin main "v$VERSION"
NOTES="$(mktemp)"
python3 scripts/changelog.py notes "$VERSION" > "$NOTES"
gh release create "v$VERSION" "$ZIP" --title "Kabuk $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"
