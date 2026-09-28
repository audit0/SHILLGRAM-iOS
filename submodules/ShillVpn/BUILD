load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# SHILLGRAM: SHILLVPN built into the app. The Xray core runs inside the app
# process (an iOS app cannot start processes and a sideloaded build has no
# Network Extension); Telegram connects through its local SOCKS5 port.

objc_library(
    name = "LibXrayBinding",
    enable_modules = True,
    module_name = "LibXrayBinding",
    srcs = glob([
        "Binding/Sources/**/*.m",
    ]),
    hdrs = glob([
        "Binding/PublicHeaders/**/*.h",
    ]),
    includes = [
        "Binding/PublicHeaders",
    ],
    deps = [
        "//third-party/libxray:libxray",
    ],
    sdk_frameworks = [
        "Foundation",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ShillVpn",
    module_name = "ShillVpn",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":LibXrayBinding",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/Postbox",
        "//submodules/TelegramCore",
        "//submodules/MtProtoKit",
        "//submodules/Display",
        "//submodules/TelegramPresentationData",
        "//submodules/AccountContext",
    ],
    visibility = [
        "//visibility:public",
    ],
)
