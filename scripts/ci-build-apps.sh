#!/usr/bin/env bash
# Builds the Apple apps without signing (CI has no Apple ID). Writes logs to build/logs and the
# products to build/out: Trove-macOS.zip (universal, ad-hoc signed) and Trove.ipa (unsigned, for
# sideloading with Sideloadly/AltStore, which signs it with your free Apple ID).
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs build/out
status=0

(cd App && xcodegen generate) > build/logs/xcodegen.log 2>&1 || { cat build/logs/xcodegen.log; exit 1; }

# Keep going after the first failing target, so one CI run reports every error.
defaults write com.apple.dt.Xcode IDEBuildingContinueBuildingAfterErrors -bool YES

common=(-project App/Trove.xcodeproj -scheme Trove -configuration Release -derivedDataPath build/dd
        -skipPackagePluginValidation -skipMacroValidation)

echo "▶ macOS"
xcodebuild "${common[@]}" -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  build > build/logs/macos.log 2>&1 || status=1
if [ -d build/dd/Build/Products/Release/Trove.app ]; then
  ditto -c -k --keepParent build/dd/Build/Products/Release/Trove.app build/out/Trove-macOS.zip
fi

echo "▶ iOS"
xcodebuild "${common[@]}" -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  build > build/logs/ios.log 2>&1 || status=1
if [ -d build/dd/Build/Products/Release-iphoneos/Trove.app ]; then
  rm -rf build/ipa && mkdir -p build/ipa/Payload
  cp -R build/dd/Build/Products/Release-iphoneos/Trove.app build/ipa/Payload/
  (cd build/ipa && zip -qry ../out/Trove.ipa Payload)
fi

# A short error report: every compiler error once, with file:line.
for platform in macos ios; do
  grep -E "(error|warning: .*concurren).*" build/logs/$platform.log | grep -E "^/|error:" | sed "s#$PWD/##" | sort -u \
    > build/logs/$platform-errors.txt || true
  echo "$platform: $(grep -c 'error:' build/logs/$platform-errors.txt || true) errors"
done
ls -la build/out
exit $status
