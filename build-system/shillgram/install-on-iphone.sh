#!/bin/bash
# Sign SHILLGRAM with the owner's free Apple ID (Personal Team profile from signstub) and install it on the USB iPhone.
# Re-run every 7 days: rebuilds the stub to refresh the profile, re-signs, installs.
set -euo pipefail
DEV=${DEV:-00008130-001A792A34C0001C}
IPA=${1:-/Volumes/TBuild/ios/out/SHILLGRAM-12.9.2-iOS.ipa}
cd /Volumes/TBuild/ios/signstub
TEAM=$(grep -m1 -oE "DEVELOPMENT_TEAM = [A-Z0-9]+" Stub.xcodeproj/project.pbxproj | awk '{print $3}')
xcodebuild -project Stub.xcodeproj -scheme Stub -destination "id=$DEV" -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM=$TEAM build >/dev/null
STUB=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 6 -path "*Stub*/Build/Products/Debug-iphoneos/Stub.app" -not -path "*/Index.noindex/*" | head -1)
W=$(mktemp -d /Volumes/TBuild/ios/resign.XXXX); trap 'rm -rf "$W"' EXIT; cd "$W"
cp "$STUB/embedded.mobileprovision" p.mobileprovision
security cms -D -i p.mobileprovision > p.plist
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' p.plist > ent.plist
unzip -q "$IPA"; A=Payload/SHILLGRAM.app
rm -rf "$A/PlugIns"; find "$A" -name _CodeSignature -type d -prune -exec rm -rf {} +
cp p.mobileprovision "$A/embedded.mobileprovision"
ID=$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')
for f in "$A"/Frameworks/*.framework; do codesign -f -s "$ID" "$f" >/dev/null; done
codesign -f -s "$ID" --entitlements ent.plist "$A" >/dev/null
xcrun devicectl device install app --device "$DEV" "$A" | grep -E "bundleID"
xcrun devicectl device process launch --device "$DEV" --terminate-existing io.github.audit0.shillgram | tail -1
