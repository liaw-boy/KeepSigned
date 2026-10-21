#!/bin/bash
# Builds a signed update for the version in VERSION:
#   dist/KeepSigned-<version>.zip, dist/KeepSigned.zip (same file) and dist/appcast.xml
# Upload all three to the GitHub release tagged v<version>; this script never tags or uploads.
# KeepSigned.zip has a fixed name so .../releases/latest/download/KeepSigned.zip always works.
#
# The EdDSA private key is read from the login keychain (create it once with
# build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys).
# Local testing only: with KEEPSIGNED_LOCAL_TEST=1 these env vars override the
# defaults, and output goes to dist/test/ with a -TEST suffix so it can't be
# mistaken for a release. Without the flag they are refused.
#   SPARKLE_FEED_URL, SPARKLE_PUBLIC_KEY   baked into the app's Info.plist
#   DOWNLOAD_URL_PREFIX                    where the zip will be downloaded from
#   SPARKLE_KEY_FILE                       private key file instead of the keychain
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_URL="https://github.com/liaw-boy/KeepSigned"
DERIVED="build/release"
BIN="build/SourcePackages/artifacts/sparkle/Sparkle/bin"

die() { echo "error: $*" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^([0-9]+)\.([0-9]{1,2})\.([0-9]{1,2})$ ]] || die "VERSION must look like 1.2.3 (minor/patch < 100)"
# Sparkle compares CFBundleVersion, so derive a number that always grows with the version.
BUILD=$(( BASH_REMATCH[1] * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[3]} ))
FEED_URL="$REPO_URL/releases/latest/download/appcast.xml"
PUBLIC_KEY="$(sed -n 's/^ *SPARKLE_PUBLIC_KEY: *"\{0,1\}\([A-Za-z0-9+\/=]*\)"\{0,1\} *$/\1/p' project.yml)"
OUT="dist"
SUFFIX=""

if [[ "${KEEPSIGNED_LOCAL_TEST:-}" == 1 ]]; then
  OUT="dist/test"
  SUFFIX="-TEST"
  safe_url='^https?://[A-Za-z0-9.:/_~%-]+$'
  echo "*** LOCAL TEST BUILD: not for release ***"
else
  for v in SPARKLE_FEED_URL SPARKLE_PUBLIC_KEY DOWNLOAD_URL_PREFIX SPARKLE_KEY_FILE; do
    [[ -z "${!v:-}" ]] || die "$v is set; unset it, or set KEEPSIGNED_LOCAL_TEST=1 for a test build"
  done
  safe_url='^https://[A-Za-z0-9.:/_~%-]+$'
fi
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-$REPO_URL/releases/download/v$VERSION}"
FEED_URL="${SPARKLE_FEED_URL:-$FEED_URL}"
PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-$PUBLIC_KEY}"

# Values that end up in XML or Info.plist: only plain URL / base64 characters.
[[ "$DOWNLOAD_URL_PREFIX" =~ $safe_url ]] || die "bad DOWNLOAD_URL_PREFIX"
# Keep this Mac's paths (and so the user name) out of the shipped binary:
# remap source/build paths and strip symbols.
overrides=(MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD"
  OTHER_SWIFT_FLAGS="-file-prefix-map $PWD/=./"
  OTHER_CFLAGS="-ffile-prefix-map=$PWD/=./"
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=non-global
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym)
if [[ -n "${SPARKLE_FEED_URL:-}" ]]; then
  [[ "$SPARKLE_FEED_URL" =~ $safe_url ]] || die "bad SPARKLE_FEED_URL"
  overrides+=(SPARKLE_FEED_URL="$SPARKLE_FEED_URL")
fi
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  [[ "$SPARKLE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "bad SPARKLE_PUBLIC_KEY"
  overrides+=(SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY")
fi
sign_args=()
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
  [[ "$SPARKLE_KEY_FILE" == /* && "$SPARKLE_KEY_FILE" != "$PWD"/* ]] || die "SPARKLE_KEY_FILE must be an absolute path outside the repo"
  [[ "$(stat -f '%Lp' "$SPARKLE_KEY_FILE")" == 600 ]] || die "SPARKLE_KEY_FILE must have mode 600"
  sign_args=(--ed-key-file "$SPARKLE_KEY_FILE")
fi

command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"
xcodegen generate --quiet
xcodebuild -resolvePackageDependencies -project KeepSigned.xcodeproj -scheme KeepSigned \
  -derivedDataPath build >/dev/null
[[ -x "$BIN/sign_update" ]] || die "Sparkle tools missing in $BIN"

echo "Building KeepSigned $VERSION ($BUILD)…"
rm -rf "$DERIVED"
xcodebuild build -project KeepSigned.xcodeproj -scheme KeepSigned -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" "${overrides[@]}" -quiet
APP="$DERIVED/Build/Products/Release/KeepSigned.app"
codesign --verify --deep --strict "$APP" || die "code signature check failed"

# Nothing from this Mac may ship: no home path, user name or local build path.
for needle in "$HOME" "/Users/" "$(id -un)" "$PWD"; do
  if grep -r -a -q -F -- "$needle" "$APP"; then
    die "the app contains '$needle' (personal path or user name); not packaging it"
  fi
done

# The built app must point at exactly the feed and key intended above.
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[[ -n "$PUBLIC_KEY" ]] || die "SPARKLE_PUBLIC_KEY is empty in project.yml"
[[ "$(plist SUPublicEDKey)" == "$PUBLIC_KEY" ]] || die "SUPublicEDKey in the app doesn't match"
[[ "$(plist SUFeedURL)" == "$FEED_URL" ]] || die "SUFeedURL in the app doesn't match"
[[ "$(plist SURequireSignedFeed)" == true ]] || die "SURequireSignedFeed must be on"

mkdir -p "$OUT"
NAME="KeepSigned-$VERSION$SUFFIX.zip"
ZIP="$OUT/$NAME"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Prints: sparkle:edSignature="..." length="..."
SIGNATURE="$("$BIN/sign_update" ${sign_args[@]+"${sign_args[@]}"} "$ZIP")"
[[ "$SIGNATURE" =~ ^sparkle:edSignature=\"[A-Za-z0-9+/=]+\"\ (sparkle:)?length=\"[0-9]+\"$ ]] || die "unexpected sign_update output"
MIN_OS="$(plist LSMinimumSystemVersion)"
[[ "$MIN_OS" =~ ^[0-9.]+$ ]] || die "unexpected LSMinimumSystemVersion"

# Release notes: this version's "- " bullets from CHANGELOG.md, HTML-escaped,
# shown in Sparkle's update window (and covered by the appcast signature).
NOTES="$(awk -v v="## $VERSION" '$0 == v {on=1; next} /^## / {on=0} on && /^- /' CHANGELOG.md \
  | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's#^- \(.*\)#<li>\1</li>#')"
[[ -n "$NOTES" ]] || die "CHANGELOG.md has no '## $VERSION' section with '- ' items"

APPCAST="$OUT/appcast.xml"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>KeepSigned</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>
$NOTES
</ul>]]></description>
      <enclosure url="$DOWNLOAD_URL_PREFIX/$NAME" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML

# The app requires a signed feed (SURequireSignedFeed); this embeds the signature.
"$BIN/sign_update" ${sign_args[@]+"${sign_args[@]}"} "$APPCAST" >/dev/null
grep -q 'sparkle-signatures' "$APPCAST" || die "appcast was not signed"

cp "$ZIP" "$OUT/KeepSigned$SUFFIX.zip"

echo "Done: $ZIP, $OUT/KeepSigned$SUFFIX.zip and $APPCAST"
[[ -z "$SUFFIX" ]] && echo "Next (manual): create release v$VERSION on GitHub and upload all three files."
true
