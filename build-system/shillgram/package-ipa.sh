#!/bin/bash
# Repackage the Bazel-built Telegram.ipa as SHILLGRAM-<version>-iOS.ipa with Payload/SHILLGRAM.app.
set -euo pipefail
REPO=/Volumes/TBuild/ios/Telegram-iOS
OUT="${OUT:-/Volumes/TBuild/ios/out}" # SHILLGRAM: OUT=... to package elsewhere
SRC_IPA="$REPO/bazel-bin/Telegram/Telegram.ipa"
[ -f "$SRC_IPA" ] || { echo "no $SRC_IPA"; exit 1; }
WORK=$(mktemp -d /Volumes/TBuild/ios/pkg.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
( cd "$WORK" && unzip -q "$SRC_IPA" )
mv "$WORK/Payload/Telegram.app" "$WORK/Payload/SHILLGRAM.app"
# iOS 27 SDK makes UIKit require UIScene lifecycle; Telegram-iOS still uses the app delegate window.
# Mark the binaries as linked against the iOS 26 SDK (as Telegram's own Xcode 26 builds are), then re-sign ad hoc.
APP="$WORK/Payload/SHILLGRAM.app"
for b in "$APP/Telegram" "$APP"/Frameworks/*.framework/* "$APP"/PlugIns/*.appex/*; do
  if [ -f "$b" ] && file "$b" | grep -q Mach-O; then
    xcrun vtool -set-build-version ios 13.0 26.0 -replace -output "$b.tmp" "$b" 2>/dev/null && mv "$b.tmp" "$b"
  fi
done
for f in "$APP"/Frameworks/*.framework "$APP"/PlugIns/*.appex; do [ -e "$f" ] && codesign -f -s - --preserve-metadata=entitlements "$f" >/dev/null 2>&1; done
codesign -f -s - --preserve-metadata=entitlements "$APP" >/dev/null 2>&1
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WORK/Payload/SHILLGRAM.app/Info.plist")
NAME="SHILLGRAM-$VERSION-iOS.ipa"
rm -f "$OUT/$NAME"
# keep only Payload (drop SwiftSupport/Symbols if present; sideloaders don't need them)
( cd "$WORK" && zip -qry "$OUT/$NAME" Payload )
echo "$OUT/$NAME"
