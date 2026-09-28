#!/bin/bash
# Build SHILLGRAM for iPhone (release_arm64, ad-hoc signed). Config JSON with API keys lives outside the repo.
set -e
cd /Volumes/TBuild/ios/Telegram-iOS
# The Xray core of the built-in SHILLVPN (not in git): builds once, then "up to date".
build-system/shillgram/build-libxray.sh
CONF="${1:-release_arm64}"
shift || true
exec python3 build-system/Make/Make.py --overrideXcodeVersion \
  --bazelUserRoot=/Volumes/TBuild/ios/.cache/bazel \
  --bazelArguments="--@build_bazel_rules_apple//apple/build_settings:signing_certificate_name=- --copt=-Wno-#warnings --cxxopt=-Wno-#warnings" \
  build --continueOnError \
  --configurationPath=/Volumes/TBuild/ios/config/shillgram-configuration.json \
  --codesigningInformationPath=/Volumes/TBuild/ios/codesigning \
  --buildNumber=1 --configuration="$CONF" "$@"
