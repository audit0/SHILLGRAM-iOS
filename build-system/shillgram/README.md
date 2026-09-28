# SHILLGRAM for iPhone — build notes

Fork of TelegramMessenger/Telegram-iOS (master 6ad963e, app 12.9.2), built with Xcode 27.0 (27A266a).

1. `xcodebuild -downloadComponent MetalToolchain` (Xcode 27 ships without it).
2. Apply `patches/rules_swift-xcode27-implicit-strong-capture.patch` inside `build-system/bazel-rules/rules_swift`.
3. `gen-fake-profiles.sh` — self-signed profiles for `io.github.audit0.shillgram`.
4. Configuration JSON (api_id/api_hash) lives outside the repo: `/Volumes/TBuild/ios/config/shillgram-configuration.json`.
5. `build-shillgram.sh` (release_arm64, ad-hoc signature), then `package-ipa.sh` → `SHILLGRAM-<version>-iOS.ipa`.

The IPA is ad-hoc signed; AltStore/Sideloadly re-sign it with the user's Apple ID.
