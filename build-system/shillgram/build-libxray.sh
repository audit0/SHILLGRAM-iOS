#!/bin/bash
# SHILLGRAM: builds the Xray core for the built-in SHILLVPN as a static C
# library (XTLS/libXray, MPL-2.0, cgo c-archive with its CGoInvoke/CGoFree
# entry points) and places it in third-party/libxray/prebuilt/, which is not
# in git. iOS apps cannot start processes, so the core runs inside the app.
#
# libXray is pinned to a tag and its commit; it pins Xray-core itself
# (v26.9.9, the same core as the Android and desktop builds).
# Updating = change TAG and COMMIT.
#
# Needs Go (brew install go) and Xcode. About 3-5 minutes per slice.
#   build-libxray.sh           iphoneos arm64 (device builds)
#   build-libxray.sh --sim     also iphonesimulator arm64
set -euo pipefail

TAG="v26.9.9"
COMMIT="50b95979f5db551bd273165cf469e5daaf791341"
MIN_IOS="13.0"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ROOT}/third-party/libxray/prebuilt"
WORK="${LIBXRAY_WORK:-$(cd "${ROOT}/.." && pwd)/.libxray}"
SRC="${WORK}/src"
STAMP="${OUT}/.stamp-${TAG}-${COMMIT}"

SLICES=("iphoneos")
if [[ "${1:-}" == "--sim" ]]; then
  SLICES+=("iphonesimulator")
fi

up_to_date=1
for sdk in "${SLICES[@]}"; do
  [[ -f "${OUT}/${sdk}-arm64/libXray.a" && -f "${STAMP}-${sdk}" ]] || up_to_date=0
done
if [[ "${up_to_date}" == 1 ]]; then
  echo "libXray ${TAG}: up to date"
  exit 0
fi

command -v go >/dev/null || { echo "Go is missing: brew install go" >&2; exit 1; }

if [[ ! -d "${SRC}/.git" ]]; then
  mkdir -p "${WORK}"
  git clone -q --branch "${TAG}" https://github.com/XTLS/libXray.git "${SRC}"
fi
actual="$(git -C "${SRC}" rev-parse HEAD)"
if [[ "${actual}" != "${COMMIT}" ]]; then
  git -C "${SRC}" fetch -q --depth 1 origin "${COMMIT}"
  git -C "${SRC}" checkout -q "${COMMIT}"
fi
[[ "$(git -C "${SRC}" rev-parse HEAD)" == "${COMMIT}" ]] || { echo "libXray is not at ${COMMIT}" >&2; exit 1; }

export GOPATH="${WORK}/gopath"
export GOCACHE="${WORK}/gocache"
export GOFLAGS="-mod=mod"
export GOTOOLCHAIN=local
cd "${SRC}"
go mod download

for sdk in "${SLICES[@]}"; do
  lib="${OUT}/${sdk}-arm64/libXray.a"
  if [[ -f "${lib}" && -f "${STAMP}-${sdk}" ]]; then
    echo "libXray ${TAG} ${sdk}: up to date"
    continue
  fi
  echo "libXray ${TAG} ${sdk}: building"
  sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  if [[ "${sdk}" == "iphoneos" ]]; then
    min="-miphoneos-version-min=${MIN_IOS}"
  else
    min="-mios-simulator-version-min=${MIN_IOS}"
  fi
  flags="-isysroot ${sdk_path} ${min} -arch arm64"
  mkdir -p "${OUT}/${sdk}-arm64"
  GOOS=ios GOARCH=arm64 CGO_ENABLED=1 GOFLAGS="-mod=mod -tags=ios" \
    CC="xcrun --sdk ${sdk} --toolchain ${sdk} clang" \
    CXX="xcrun --sdk ${sdk} --toolchain ${sdk} clang++" \
    CGO_CFLAGS="${flags}" CGO_CXXFLAGS="${flags}" \
    CGO_LDFLAGS="${flags} -Wl,-Bsymbolic-functions" \
    go build -trimpath -ldflags "-s -w -buildid=" -buildmode=c-archive \
      -o "${lib}" ./cgo_bridge
  mkdir -p "${OUT}/include"
  cp "${OUT}/${sdk}-arm64/libXray.h" "${OUT}/include/libXray.h"
  rm -f "${OUT}/${sdk}-arm64/libXray.h"
  touch "${STAMP}-${sdk}"
  ls -l "${lib}"
done
git -C "${SRC}" checkout -q -- go.mod go.sum 2>/dev/null || true
echo "libXray ${TAG}: ok"
