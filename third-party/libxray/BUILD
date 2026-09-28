# SHILLGRAM: the Xray core of the built-in SHILLVPN (XTLS/libXray v26.9.9,
# MPL-2.0) as a static C library. The archives are not in git: run
# build-system/shillgram/build-libxray.sh (add --sim for simulator builds).

cc_library(
    name = "libxray",
    srcs = select({
        "//build-system:ios_sim_arm64": ["prebuilt/iphonesimulator-arm64/libXray.a"],
        "//conditions:default": ["prebuilt/iphoneos-arm64/libXray.a"],
    }),
    hdrs = ["prebuilt/include/libXray.h"],
    includes = ["prebuilt/include"],
    linkopts = [
        "-lresolv",
        "-framework CoreFoundation",
        "-framework Security",
    ],
    visibility = ["//visibility:public"],
)
