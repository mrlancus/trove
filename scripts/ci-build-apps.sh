#!/usr/bin/env bash
# Builds the Apple apps (CI has no Apple ID). Writes logs to build/logs and the products to
# build/out:
#   Trove-macOS.zip  universal; signed with Trove's own certificate when the MAC_CERT_P12 and
#                    MAC_CERT_PASSWORD secrets are set (so macOS keeps its permissions across
#                    updates), ad-hoc otherwise
#   update.json      the Mac app's self-update feed (Services/Updater.swift), only when the zip is
#                    signed with the certificate and UPDATE_SIGNING_KEY is set
#   Trove.ipa        unsigned, for Sideloadly/SideStore/AltStore, which sign it with your Apple ID
#   sidestore.json   a SideStore/AltStore source, so new builds show up as updates there
# Each build is version 0.1.<run number>, so every build is newer than the last.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs build/out
status=0

(cd App && xcodegen generate) > build/logs/xcodegen.log 2>&1 || { cat build/logs/xcodegen.log; exit 1; }

# Keep going after the first failing target, so one CI run reports every error.
defaults write com.apple.dt.Xcode IDEBuildingContinueBuildingAfterErrors -bool YES

BUILD=${GITHUB_RUN_NUMBER:-1}
VERSION="0.1.$BUILD"
RELEASE_URL="https://github.com/${GITHUB_REPOSITORY:-mrlancus/trove}/releases/download/latest"
TMP=${RUNNER_TEMP:-/tmp}
common=(-project App/Trove.xcodeproj -scheme Trove -configuration Release -derivedDataPath build/dd
        -skipPackagePluginValidation -skipMacroValidation MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD")

# Re-signs the app and its extensions (inside out, keeping each one's entitlements) with Trove's
# self-signed certificate. The same certificate every build means the same app to macOS.
sign_mac() {
  local app=$1 kc="$TMP/trove-signing.keychain-db" kcpass
  kcpass=$(uuidgen)
  security create-keychain -p "$kcpass" "$kc" || return 1
  security set-keychain-settings -lut 3600 "$kc"
  security unlock-keychain -p "$kcpass" "$kc"
  # codesign only finds the key in keychains on the search list, whatever --keychain says.
  # shellcheck disable=SC2046
  security list-keychains -d user -s "$kc" $(security list-keychains -d user | tr -d '"') || { echo "step failed: list-keychains"; return 1; }
  # Pasted secrets often pick up a stray space or newline; base64 and the hex password have none.
  local password
  password=$(printf '%s' "$MAC_CERT_PASSWORD" | tr -d '[:space:]')
  printf '%s' "$MAC_CERT_P12" | tr -d '[:space:]' | base64 --decode > "$TMP/trove-cert.p12"
  # Fingerprints only (no secret values), to compare with the file the secrets came from.
  echo "certificate file: $(wc -c < "$TMP/trove-cert.p12" | tr -d ' ') bytes, sha256 $(shasum -a 256 "$TMP/trove-cert.p12" | cut -c1-12); password: ${#password} characters"
  security import "$TMP/trove-cert.p12" -k "$kc" -P "$password" -T /usr/bin/codesign || { echo "step failed: import"; return 1; }
  rm -f "$TMP/trove-cert.p12"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpass" "$kc" > /dev/null || { echo "step failed: set-key-partition-list"; return 1; }
  # Names and hashes of the identities (public), to see what the certificate is called.
  security find-identity -p codesigning "$kc"
  local identity
  identity=$(security find-identity -p codesigning "$kc" | awk '/Trove Self-Signed/ { print $2; exit }')
  [ -n "$identity" ] || { echo "no signing identity in the keychain"; return 1; }
  shopt -s nullglob
  for bundle in "$app"/Contents/Frameworks/* "$app"/Contents/PlugIns/*.appex "$app"; do
    local ent="$TMP/trove-ent.plist" args=(--force --sign "$identity" --keychain "$kc" --options runtime --timestamp=none)
    rm -f "$ent"
    codesign -d --entitlements - --xml "$bundle" > "$ent" 2>/dev/null || true
    [ -s "$ent" ] && args+=(--entitlements "$ent")
    codesign "${args[@]}" "$bundle" || { echo "step failed: codesign $bundle"; return 1; }
  done
  shopt -u nullglob
  codesign --verify --deep --strict "$app" && codesign -d -r- "$app" || { echo "step failed: verify"; return 1; }
}

# SideStore refuses an app whose build number differs from the feed's, and the Mac updater compares
# build numbers, so every bundle must carry this build's numbers.
check_versions() {
  local bundle plist v b bad=0
  for bundle in "$1" "$1"/Contents/PlugIns/*.appex "$1"/PlugIns/*.appex; do
    plist="$bundle/Contents/Info.plist"; [ -f "$plist" ] || plist="$bundle/Info.plist"
    [ -f "$plist" ] || continue
    v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)
    b=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null)
    [ "$v" = "$VERSION" ] && [ "$b" = "$BUILD" ] || { echo "error: $plist is version $v ($b), expected $VERSION ($BUILD)"; bad=1; }
  done
  return $bad
}

echo "▶ macOS"
xcodebuild "${common[@]}" -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  build > build/logs/macos.log 2>&1 || status=1
MAC_APP=build/dd/Build/Products/Release/Trove.app
signed=no
[ -d "$MAC_APP" ] && { check_versions "$MAC_APP" >> build/logs/macos.log || status=1; }
if [ -d "$MAC_APP" ] && [ -n "${MAC_CERT_P12:-}" ] && [ -n "${MAC_CERT_PASSWORD:-}" ]; then
  if sign_mac "$MAC_APP" >> build/logs/macos.log 2>&1; then signed=yes; else echo "Signing failed, see macos.log"; status=1; fi
fi
if [ -d "$MAC_APP" ]; then
  ditto -c -k --keepParent "$MAC_APP" build/out/Trove-macOS.zip
fi
echo "Mac app signed with Trove's certificate: $signed"

# The self-update feed: Ed25519 over the zip, made with UPDATE_SIGNING_KEY (a base64 32-byte seed).
if [ "$signed" = yes ] && [ -n "${UPDATE_SIGNING_KEY:-}" ] && [ -f build/out/Trove-macOS.zip ]; then
  OPENSSL=$(brew --prefix openssl@3 2>/dev/null)/bin/openssl
  [ -x "$OPENSSL" ] || OPENSSL=openssl
  { printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20'; printf '%s' "$UPDATE_SIGNING_KEY" | tr -d '[:space:]' | base64 --decode; } > "$TMP/update-key.der"
  if "$OPENSSL" pkeyutl -sign -inkey "$TMP/update-key.der" -keyform DER -rawin -in build/out/Trove-macOS.zip -out "$TMP/update.sig"; then
    SIG=$(base64 < "$TMP/update.sig" | tr -d '\n') SIZE=$(stat -f%z build/out/Trove-macOS.zip) VERSION=$VERSION BUILD=$BUILD URL="$RELEASE_URL/Trove-macOS.zip" \
      python3 -c 'import json, os; print(json.dumps({"version": os.environ["VERSION"], "build": int(os.environ["BUILD"]), "url": os.environ["URL"],
        "size": int(os.environ["SIZE"]), "signature": os.environ["SIG"], "notes": "Built from " + os.environ.get("GITHUB_SHA", "")[:7] + "."}, indent=2))' \
      > build/out/update.json
  else
    echo "Couldn't sign the update"; status=1
  fi
  rm -f "$TMP/update-key.der" "$TMP/update.sig"
fi

echo "▶ iOS"
xcodebuild "${common[@]}" -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  build > build/logs/ios.log 2>&1 || status=1
if [ -d build/dd/Build/Products/Release-iphoneos/Trove.app ]; then
  check_versions build/dd/Build/Products/Release-iphoneos/Trove.app >> build/logs/ios.log || status=1
  rm -rf build/ipa && mkdir -p build/ipa/Payload
  cp -R build/dd/Build/Products/Release-iphoneos/Trove.app build/ipa/Payload/
  (cd build/ipa && zip -qry ../out/Trove.ipa Payload)
  # A SideStore/AltStore source: add $RELEASE_URL/sidestore.json in SideStore → Sources, and new
  # builds show up as updates that install over the old one (keeping its data).
  SIZE=$(stat -f%z build/out/Trove.ipa) VERSION=$VERSION BUILD=$BUILD URL="$RELEASE_URL/Trove.ipa" \
  INFO=build/dd/Build/Products/Release-iphoneos/Trove.app/Info.plist python3 - > build/out/sidestore.json <<'PY'
import datetime, json, os, plistlib
info = plistlib.load(open(os.environ["INFO"], "rb"))
privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}
print(json.dumps({
  "name": "Trove", "identifier": "com.mrlancus.trove.source", "subtitle": "Save anything, find it again.",
  "website": "https://trove-relay.lancus.workers.dev",
  "iconURL": "https://raw.githubusercontent.com/mrlancus/trove/main/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
  "apps": [{
    "name": "Trove", "bundleIdentifier": info["CFBundleIdentifier"], "developerName": "mrlancus",
    "subtitle": "Save anything, find it again.",
    "localizedDescription": "Your end-to-end encrypted second brain and notes.",
    "iconURL": "https://raw.githubusercontent.com/mrlancus/trove/main/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
    "tintColor": "#E8661A", "category": "productivity",
    "versions": [{
      "version": os.environ["VERSION"], "buildVersion": os.environ["BUILD"],
      "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
      "size": int(os.environ["SIZE"]), "downloadURL": os.environ["URL"], "minOSVersion": info.get("MinimumOSVersion", "18.0"),
      "localizedDescription": "Built from " + os.environ.get("GITHUB_SHA", "")[:7] + ".",
    }],
    "appPermissions": {"entitlements": ["com.apple.security.application-groups"], "privacy": privacy},
  }],
  "news": [],
}, indent=2))
PY
fi

# A short error report: every compiler error once, with file:line.
for platform in macos ios; do
  grep -E "(error|warning: .*concurren).*" build/logs/$platform.log | grep -E "^/|error:" | sed "s#$PWD/##" | sort -u \
    > build/logs/$platform-errors.txt || true
  echo "$platform: $(grep -c 'error:' build/logs/$platform-errors.txt || true) errors"
done
ls -la build/out
exit $status
