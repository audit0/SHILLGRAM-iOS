/*
 * SHILLGRAM: a plain-Swift check of the SHILLVPN parser, Xray config builder
 * and trial proof of work against synthetic (fake) share links, ported from
 * the Android self-test (scripts/vpn_selftest/VpnSelfTest.java). Run
 * SelfTest/run.sh. Nothing here is a real server, token or key.
 */
import Foundation
import CommonCrypto

var failures = 0

func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok {
        failures += 1
    }
}

func child(_ object: [String: Any]?, _ key: String) -> [String: Any]? {
    return object?[key] as? [String: Any]
}

func list(_ object: [String: Any]?, _ key: String) -> [Any] {
    return (object?[key] as? [Any]) ?? []
}

func string(_ object: [String: Any]?, _ key: String) -> String {
    return (object?[key] as? String) ?? ""
}

func number(_ object: [String: Any]?, _ key: String) -> Int {
    return (object?[key] as? NSNumber)?.intValue ?? 0
}

func bool(_ object: [String: Any]?, _ key: String) -> Bool {
    return (object?[key] as? NSNumber)?.boolValue ?? false
}

let token = "0123456789abcdef01234567." + String(repeating: "ab", count: 32)

// Tokens from the link forms the desktop accepts.
check(XrayConfig.tokenFromLink("https://example.test/sub/" + token) == token, "token from /sub/ link")
check(XrayConfig.tokenFromLink("https://example.test/c/" + token + "?x=1") == token, "token from /c/ link with query")
check(XrayConfig.tokenFromLink("  " + token + "  ") == token, "bare token")
check(XrayConfig.tokenFromLink("https://example.test/sub/" + token + "x") == nil, "token with junk after it is rejected")
check(XrayConfig.tokenFromLink("hello") == nil, "not a link")

check(XrayConfig.subscriptionUrl(link: "https://example.test/sub/" + token + "?a=b#c", token: token) == "https://example.test/sub/" + token, "subscription url keeps a /sub/ link, drops query")
check(XrayConfig.subscriptionUrl(link: "https://example.test/c/" + token, token: token) == "https://example.test/sub/" + token, "subscription url from /c/ link uses its host")
check(XrayConfig.subscriptionUrl(link: token, token: token) == "https://shillvpn.site/sub/" + token, "bare token goes to shillvpn.site")
check(XrayConfig.expireFromUserInfo("upload=0; download=0; total=0; expire=1790000000") == 1790000000, "expire from subscription-userinfo")

// A synthetic subscription: REALITY/TCP, XHTTP via CDN (tls), Hysteria 2,
// an info line (0.0.0.0), plain VLESS (not served), vmess (not opened).
let uuid = "11111111-2222-3333-4444-555555555555"
let reality = "vless://" + uuid + "@203.0.113.10:443?security=reality&type=tcp&flow=xtls-rprx-vision"
    + "&sni=www.example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123abcd#%D0%9D%D0%B8%D0%B4%D0%B5%D1%80%D0%BB%D0%B0%D0%BD%D0%B4%D1%8B"
let xhttp = "vless://" + uuid + "@cdn.example.test:443?security=tls&type=xhttp&sni=cdn.example.test"
    + "&path=%2Fxh&host=cdn.example.test&mode=packet-up&extra=%7B%22xPaddingBytes%22%3A%22100-1000%22%7D#CDN"
let hy2 = "hysteria2://secret-auth@198.51.100.7:8443?sni=hy.example.test&pinSHA256=" + String(repeating: "cd", count: 32) + "#HY2"
let info = "vless://" + uuid + "@0.0.0.0:1?security=reality&type=tcp#3%20%D0%B4%D0%BD%D1%8F"
let plain = "vless://" + uuid + "@203.0.113.11:80?type=tcp#plain"
let vmess = "vmess://eyJhZGQiOiIxLjIuMy40In0="
let listText = [reality, xhttp, hy2, info, plain, vmess].joined(separator: "\n") + "\n"
let body = Data(listText.utf8).base64EncodedData()

let entries = XrayConfig.parseBody(body)
check(entries.count == 3, "base64 body: 3 usable entries (got \(entries.count))")
check(!entries.isEmpty && entries[0].title == "Нидерланды", "entry title decoded from fragment")
check(XrayConfig.parseBody(Data(listText.utf8)).count == 3, "plain-text body parses the same")
let urlSafe = Data(listText.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
check(XrayConfig.parseBody(Data(urlSafe.utf8)).count == 3, "url-safe base64 without padding")
check(XrayConfig.parseBody(Data("not a subscription".utf8)).isEmpty, "junk body gives no entries")

let config = XrayConfig.build(entries: entries, port: 10808, user: "shilltest", password: "pass-word")
let root = XrayConfig.parseObject(config)
check(root != nil, "config is valid JSON")
check(string(child(root, "log"), "access") == "none", "no access log")
let inbound = list(root, "inbounds").first as? [String: Any]
check(string(inbound, "listen") == "127.0.0.1" && number(inbound, "port") == 10808 && string(inbound, "protocol") == "socks", "socks inbound on 127.0.0.1")
let socks = child(inbound, "settings")
check(string(socks, "auth") == "password" && !bool(socks, "udp") && socks?["udp"] != nil, "socks auth=password, udp off")
let outbounds = list(root, "outbounds")
check(outbounds.count == 3, "3 outbounds")
let o0 = outbounds.first as? [String: Any]
let s0 = child(o0, "streamSettings")
check(string(o0, "tag") == "p0" && string(s0, "security") == "reality" && string(child(s0, "realitySettings"), "publicKey") == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "reality outbound")
let vnext0 = list(child(o0, "settings"), "vnext").first as? [String: Any]
let user0 = list(vnext0, "users").first as? [String: Any]
check(string(user0, "flow") == "xtls-rprx-vision" && string(user0, "encryption") == "none", "vless user flow")
check(number(vnext0, "port") == 443 && string(vnext0, "address") == "203.0.113.10", "vless address and port")
let s1 = child(outbounds.count > 1 ? outbounds[1] as? [String: Any] : nil, "streamSettings")
let xh = child(s1, "xhttpSettings")
check(string(s1, "network") == "xhttp" && string(xh, "path") == "/xh" && string(child(xh, "extra"), "xPaddingBytes") == "100-1000", "xhttp settings with extra object")
let o2 = outbounds.count > 2 ? outbounds[2] as? [String: Any] : nil
check(string(o2, "protocol") == "hysteria"
    && string(child(child(o2, "streamSettings"), "tlsSettings"), "pinnedPeerCertSha256") == String(repeating: "cd", count: 32)
    && string(child(child(o2, "streamSettings"), "hysteriaSettings"), "auth") == "secret-auth", "hysteria 2 outbound with pinned cert")
check(root?["observatory"] != nil && root?["routing"] != nil, "several entries: observatory + leastPing balancer")
let single = XrayConfig.parseObject(XrayConfig.build(entries: Array(entries.prefix(1)), port: 10808, user: "shilltest", password: "pw"))
check(single != nil && single?["routing"] == nil, "one entry: no balancer")

// Hysteria with insecure=1 and no pin is refused, as on desktop.
check(XrayConfig.outbound(uri: "hysteria2://a@198.51.100.7:8443?insecure=1", tag: "p") == nil, "insecure hysteria refused")
check(XrayConfig.outbound(uri: "vless://short@203.0.113.10:443?security=tls", tag: "p") == nil, "bad uuid refused")
check(XrayConfig.outbound(uri: "hysteria2://a@198.51.100.7:8443?obfs=salamander&pinSHA256=00", tag: "p") == nil, "salamander refused")
check(XrayConfig.outbound(uri: "vless://" + uuid + "@[2001:db8::1]:443?security=tls&type=tcp", tag: "p") != nil, "ipv6 host in brackets")

// JSON round trip of escapes.
let tricky = "a\"b\\c\nd\u{0001}é"
check(string(XrayConfig.parseObject(XrayConfig.writeJson(["k": tricky])), "k") == tricky, "json string escapes round trip")

// Device hash is the same HMAC as Java's TrialWork.deviceHash.
check(TrialWork.deviceHash(Data("fake-device".utf8)).count == 64, "device hash is hex sha256")

// Proof of work: a solution has 24 zero bits.
let prefix = TrialWork.prefix(device: TrialWork.deviceHash(Data("fake-device".utf8)), hour: 480000)
let started = Date()
let work = TrialWork.solve(prefix: prefix)
var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
let payload = prefix + Array(work.utf8)
CC_SHA256(payload, CC_LONG(payload.count), &hash)
check(hash[0] == 0 && hash[1] == 0 && hash[2] == 0, "proof of work solved in \(Int(Date().timeIntervalSince(started) * 1000)) ms")

if CommandLine.arguments.count > 1 {
    try? Data(config.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
