# SHILLGRAM for iPhone — build notes

Fork of TelegramMessenger/Telegram-iOS (master 6ad963e, app 12.9.2), built with Xcode 27.0 (27A266a).

1. `xcodebuild -downloadComponent MetalToolchain` (Xcode 27 ships without it).
2. Apply `patches/rules_swift-xcode27-implicit-strong-capture.patch` inside `build-system/bazel-rules/rules_swift`.
3. `gen-fake-profiles.sh` — self-signed profiles for `io.github.audit0.shillgram`.
4. Configuration JSON (api_id/api_hash) lives outside the repo: `/Volumes/TBuild/ios/config/shillgram-configuration.json`.
5. `build-libxray.sh` — the Xray core of the built-in SHILLVPN (XTLS/libXray v26.9.9, MPL-2.0, cgo c-archive) into `third-party/libxray/prebuilt/` (not in git; needs `brew install go`, add `--sim` for simulator builds). `build-shillgram.sh` runs it first.
6. `build-shillgram.sh` (release_arm64, ad-hoc signature), then `package-ipa.sh` → `SHILLGRAM-<version>-iOS.ipa`.

SHILLVPN (`submodules/ShillVpn`): the core runs inside the app process (no Network Extension with a free Apple ID) and serves a SOCKS5 port on 127.0.0.1 with a random login; Telegram's proxy setting points at it for every account and for the login. Without a working subscription the SHILLVPN screen is the first screen at launch. Parser/config/proof-of-work self-test: `submodules/ShillVpn/SelfTest/run.sh` (`XRAY=/path/to/xray` also runs `xray run -test` on the generated config). Status lines (`SHILLVPN: …`: states, the local port, whether Telegram is online and by which route; never links, keys or servers) go to the system log and to `Library/Caches/shillvpn-status.log` in the app container (`xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier io.github.audit0.shillgram --source Library/Caches/shillvpn-status.log …`).

The IPA is ad-hoc signed; AltStore/Sideloadly re-sign it with the user's Apple ID.

Ghost mode («Режим призрака», as in the desktop client): `submodules/TelegramCore/Sources/ShillGhost.swift` reads the app-wide switches (UserDefaults suite `shillgram_ghost`, every account); the network hooks are tagged `// SHILLGRAM: ghost` (`grep -rn "SHILLGRAM: ghost" submodules`). Settings → «Режим призрака» (`PeerInfoScreen/Sources/ShillGhostSettingsController.swift`). `OUT=/some/dir package-ipa.sh` packages the IPA elsewhere than `out/`.
