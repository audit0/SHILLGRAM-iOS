#!/bin/bash
# Repackage the Bazel-built Telegram.ipa as SHILLGRAM-<version>-iOS.ipa with Payload/SHILLGRAM.app.
set -euo pipefail
REPO=/Volumes/TBuild/ios/Telegram-iOS
OUT=/Volumes/TBuild/ios/out
SRC_IPA="$REPO/bazel-bin/Telegram/Telegram.ipa"
[ -f "$SRC_IPA" ] || { echo "no $SRC_IPA"; exit 1; }
WORK=$(mktemp -d /Volumes/TBuild/ios/pkg.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
( cd "$WORK" && unzip -q "$SRC_IPA" )
mv "$WORK/Payload/Telegram.app" "$WORK/Payload/SHILLGRAM.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WORK/Payload/SHILLGRAM.app/Info.plist")
NAME="SHILLGRAM-$VERSION-iOS.ipa"
rm -f "$OUT/$NAME"
# keep only Payload (drop SwiftSupport/Symbols if present; sideloaders don't need them)
( cd "$WORK" && zip -qry "$OUT/$NAME" Payload )
echo "$OUT/$NAME"
