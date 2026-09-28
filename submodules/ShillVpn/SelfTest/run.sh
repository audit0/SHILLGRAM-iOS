#!/usr/bin/env bash
# SHILLGRAM: checks the SHILLVPN subscription parser, Xray config builder and
# trial proof of work with plain Swift on the Mac, against synthetic links.
# Optional: XRAY=/path/to/xray also lets Xray itself test the generated
# config (xray run -test).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "${OUT}"' EXIT
xcrun swiftc -O -o "${OUT}/selftest" \
  "${DIR}/../Sources/XrayConfig.swift" "${DIR}/../Sources/TrialWork.swift" "${DIR}/main.swift"
"${OUT}/selftest" "${OUT}/config.json"
if [[ -n "${XRAY:-}" ]]; then
  "${XRAY}" run -test -config "${OUT}/config.json"
fi
