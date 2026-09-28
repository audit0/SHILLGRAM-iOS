/*
 * SHILLGRAM: SHILLVPN built into the app.
 *
 * The subscription as Xray sees it: the token of a pasted link, the share
 * links of a fetched subscription body, and the Xray config serving a local
 * SOCKS5 port for Telegram. A port of the Android client (XrayConfig.java)
 * and of the desktop one (shillgramm/shill_vpn.cpp: TokenFromLink,
 * Outbound, HysteriaOutbound, applyBody, buildConfig); plain Foundation so
 * it is checked with `swift` on a Mac (SelfTest/run.sh).
 *
 * Nothing here logs: the links and bodies are secrets.
 */
import Foundation

public enum XrayConfig {
    public static let site = "https://shillvpn.site"

    /// One usable server of the subscription.
    public struct Entry: Equatable {
        public let title: String
        public let uri: String

        public init(title: String, uri: String) {
            self.title = title
            self.uri = uri
        }
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: "(?:^|/)([0-9a-f]{24}\\.[0-9a-f]{64})(?:$|[/?#])", options: [])
    private static let expirePattern = try! NSRegularExpression(pattern: "expire=(\\d+)", options: [])

    // MARK: - Links

    /// Accepts /sub/, /c/, /r/<app>/ links or the bare token.
    public static func tokenFromLink(_ link: String?) -> String? {
        guard let link = link else {
            return nil
        }
        let text = javaTrim(link)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = tokenPattern.firstMatch(in: text, options: [], range: range), let tokenRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[tokenRange])
    }

    /// Where the subscription body is served for this link and token.
    public static func subscriptionUrl(link: String?, token: String) -> String {
        let url = ShareUrl.parse(javaTrim(link ?? ""))
        if let url = url, url.scheme == "https", url.path.contains("/sub/"), url.path.hasSuffix(token) {
            return url.withoutQueryAndFragment
        }
        let origin: String
        if let url = url, url.scheme == "https", !url.host.isEmpty {
            origin = "https://" + url.host
        } else {
            origin = site
        }
        return origin + "/sub/" + token
    }

    /// Unix time from the subscription-userinfo header, 0 when absent.
    public static func expireFromUserInfo(_ header: String?) -> Int64 {
        guard let header = header else {
            return 0
        }
        let range = NSRange(header.startIndex..., in: header)
        guard let match = expirePattern.firstMatch(in: header, options: [], range: range), let valueRange = Range(match.range(at: 1), in: header) else {
            return 0
        }
        return Int64(header[valueRange]) ?? 0
    }

    // MARK: - Subscription body

    /// The share links of a body this app can use; empty when none.
    public static func parseBody(_ body: Data?) -> [Entry] {
        guard let body = body else {
            return []
        }
        var text = javaTrim(String(decoding: body, as: UTF8.self))
        if !text.contains("://") {
            let compact = text.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            if let decoded = decodeBase64(compact) {
                text = String(decoding: decoded, as: UTF8.self)
            }
        }
        var result: [Entry] = []
        for line in text.components(separatedBy: "\n") {
            let uri = javaTrim(line)
            if outbound(uri: uri, tag: "p") != nil {
                let url = ShareUrl.parse(uri)
                result.append(Entry(title: url?.fragment ?? "", uri: uri))
            }
        }
        return result
    }

    /// Standard or URL-safe Base64, padding optional; nil when invalid.
    static func decodeBase64(_ text: String) -> Data? {
        var out = Data()
        out.reserveCapacity(text.utf8.count * 3 / 4 + 3)
        var buffer: UInt32 = 0
        var bits = 0
        for c in text.utf8 {
            let value: UInt32
            switch c {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"):
                value = UInt32(c - UInt8(ascii: "A"))
            case UInt8(ascii: "a") ... UInt8(ascii: "z"):
                value = UInt32(c - UInt8(ascii: "a")) + 26
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                value = UInt32(c - UInt8(ascii: "0")) + 52
            case UInt8(ascii: "+"), UInt8(ascii: "-"):
                value = 62
            case UInt8(ascii: "/"), UInt8(ascii: "_"):
                value = 63
            case UInt8(ascii: "="):
                return out
            case UInt8(ascii: " "), UInt8(ascii: "\t"):
                continue
            default:
                return nil
            }
            buffer = ((buffer << 6) | value) & 0xFFFFFF
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }

    // MARK: - Xray outbounds

    /// One share link as an Xray outbound; nil for the info lines of the
    /// list and for what the bundled core does not open.
    public static func outbound(uri: String, tag: String) -> [String: Any]? {
        guard let url = ShareUrl.parse(uri) else {
            return nil
        }
        if url.scheme == "hysteria2" || url.scheme == "hy2" {
            return hysteriaOutbound(url: url, tag: tag)
        } else if url.scheme != "vless" {
            return nil
        }
        let host = url.host
        let port = url.port
        let id = url.userName
        if host.isEmpty || host == "0.0.0.0" || port <= 0 || id.utf16.count != 36 {
            // Info lines: "3 дня осталось" and such.
            return nil
        }
        let security = url.query("security")
        let network = url.query("type").isEmpty ? "tcp" : url.query("type")
        if network != "tcp" && network != "xhttp" {
            return nil
        }
        var user: [String: Any] = [
            "id": id,
            "encryption": "none"
        ]
        if !url.query("flow").isEmpty {
            user["flow"] = url.query("flow")
        }
        var stream: [String: Any] = ["network": network]
        let fingerprint = url.query("fp").isEmpty ? "chrome" : url.query("fp")
        if security == "reality" {
            stream["security"] = "reality"
            stream["realitySettings"] = [
                "serverName": url.query("sni"),
                "fingerprint": fingerprint,
                "publicKey": url.query("pbk"),
                "shortId": url.query("sid")
            ] as [String: Any]
        } else if security == "tls" {
            stream["security"] = "tls"
            stream["tlsSettings"] = [
                "serverName": url.query("sni").isEmpty ? host : url.query("sni"),
                "fingerprint": fingerprint
            ] as [String: Any]
        } else {
            // Plain VLESS is not something we serve.
            return nil
        }
        if network == "xhttp" {
            var xhttp: [String: Any] = [:]
            if !url.query("path").isEmpty {
                xhttp["path"] = url.query("path")
            }
            if !url.query("host").isEmpty {
                xhttp["host"] = url.query("host")
            }
            if !url.query("mode").isEmpty {
                xhttp["mode"] = url.query("mode")
            }
            if let extra = parseObject(url.query("extra")) {
                xhttp["extra"] = extra
            }
            stream["xhttpSettings"] = xhttp
        }
        return [
            "tag": tag,
            "protocol": "vless",
            "settings": [
                "vnext": [[
                    "address": host,
                    "port": port,
                    "users": [user]
                ] as [String: Any]]
            ] as [String: Any],
            "streamSettings": stream
        ]
    }

    /// Hysteria 2 (QUIC). Xray 26.9 names it "hysteria", version 2;
    /// "insecure" is gone from Xray, only a pinned certificate replaces the
    /// name check.
    private static func hysteriaOutbound(url: ShareUrl, tag: String) -> [String: Any]? {
        let host = url.host
        let port = url.port
        let auth = url.userInfo
        if host.isEmpty || host == "0.0.0.0" || port <= 0 || auth.isEmpty {
            return nil
        }
        if !url.query("obfs").isEmpty {
            // Salamander is not in the bundled core.
            return nil
        }
        var tls: [String: Any] = [
            "serverName": url.query("sni").isEmpty ? host : url.query("sni"),
            "alpn": ["h3"]
        ]
        let pin = url.query("pinSHA256")
        if !pin.isEmpty {
            tls["pinnedPeerCertSha256"] = pin
        } else if url.query("insecure") == "1" {
            return nil
        }
        return [
            "tag": tag,
            "protocol": "hysteria",
            "settings": [
                "version": 2,
                "address": host,
                "port": port
            ] as [String: Any],
            "streamSettings": [
                "network": "hysteria",
                "security": "tls",
                "tlsSettings": tls,
                "hysteriaSettings": [
                    "version": 2,
                    "auth": auth
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    // MARK: - The whole config

    /// The Xray config: a SOCKS5 inbound on 127.0.0.1:port with a login and
    /// password, every entry as an outbound and, with several of them, a
    /// leastPing balancer. No access log.
    public static func build(entries: [Entry], port: Int, user: String, password: String) -> String {
        var outbounds: [Any] = []
        var index = 0
        for entry in entries {
            if let outbound = outbound(uri: entry.uri, tag: "p\(index)") {
                outbounds.append(outbound)
                index += 1
            }
        }
        var config: [String: Any] = [
            // No access log: SHILLVPN keeps no history of connections.
            "log": [
                "loglevel": "warning",
                "access": "none"
            ] as [String: Any],
            "inbounds": [[
                "tag": "telegram",
                "listen": "127.0.0.1",
                "port": port,
                "protocol": "socks",
                "settings": [
                    "auth": "password",
                    "accounts": [[
                        "user": user,
                        "pass": password
                    ]],
                    "udp": false
                ] as [String: Any]
            ] as [String: Any]],
            "outbounds": outbounds
        ]
        if index > 1 {
            // Several entries: the core probes them and takes the quickest
            // one that answers, so a cut protocol does not stop Telegram.
            config["observatory"] = [
                "subjectSelector": ["p"],
                "probeURL": "https://www.gstatic.com/generate_204",
                "probeInterval": "2m",
                "enableConcurrency": true
            ] as [String: Any]
            config["routing"] = [
                "balancers": [[
                    "tag": "auto",
                    "selector": ["p"],
                    "strategy": ["type": "leastPing"],
                    "fallbackTag": "p0"
                ] as [String: Any]],
                "rules": [[
                    "type": "field",
                    "inboundTag": ["telegram"],
                    "balancerTag": "auto"
                ] as [String: Any]]
            ] as [String: Any]
        }
        return writeJson(config)
    }

    // MARK: - JSON

    public static func writeJson(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func parseObject(_ text: String?) -> [String: Any]? {
        guard let text = text, !text.isEmpty, let data = text.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    public static func parseObject(_ data: Data?) -> [String: Any]? {
        guard let data = data, !data.isEmpty else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    /// Java's String.trim(): drops the chars <= ' ' at both ends.
    static func javaTrim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end && scalars[start].value <= 0x20 {
            start = scalars.index(after: start)
        }
        while end > start && scalars[scalars.index(before: end)].value <= 0x20 {
            end = scalars.index(before: end)
        }
        return String(scalars[start ..< end])
    }
}

/// A share link, split the way QUrl does for these fields.
struct ShareUrl {
    var scheme = ""
    var userInfo = "" // Decoded.
    var userName = "" // Decoded, before ':'.
    var host = ""
    var port = -1
    var path = ""
    var rawQuery = ""
    var fragment = "" // Decoded.
    private(set) var withoutQueryAndFragment = ""

    static func parse(_ text: String) -> ShareUrl? {
        if text.isEmpty {
            return nil
        }
        guard let schemeEnd = text.range(of: "://"), schemeEnd.lowerBound > text.startIndex else {
            return nil
        }
        var url = ShareUrl()
        url.scheme = String(text[..<schemeEnd.lowerBound]).lowercased()
        for c in url.scheme {
            if !(c.isLetter || c.isNumber || c == "+" || c == "-" || c == ".") {
                return nil
            }
        }
        var rest = String(text[schemeEnd.upperBound...])
        if let hash = rest.firstIndex(of: "#") {
            guard let fragment = decode(String(rest[rest.index(after: hash)...])) else {
                return nil
            }
            url.fragment = fragment
            rest = String(rest[..<hash])
        }
        if let question = rest.firstIndex(of: "?") {
            url.rawQuery = String(rest[rest.index(after: question)...])
            rest = String(rest[..<question])
        }
        var authority = rest
        if let slash = rest.firstIndex(of: "/") {
            url.path = String(rest[slash...])
            authority = String(rest[..<slash])
        }
        var userPrefix = ""
        if let at = authority.lastIndex(of: "@") {
            let info = String(authority[..<at])
            userPrefix = info + "@"
            authority = String(authority[authority.index(after: at)...])
            guard let decoded = decode(info) else {
                return nil
            }
            url.userInfo = decoded
            let namePart: String
            if let colon = info.firstIndex(of: ":") {
                namePart = String(info[..<colon])
            } else {
                namePart = info
            }
            guard let name = decode(namePart) else {
                return nil
            }
            url.userName = name
        }
        var hostPart = authority
        var portPart: String?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else {
                return nil
            }
            hostPart = String(authority[authority.index(after: authority.startIndex) ..< close])
            let after = String(authority[authority.index(after: close)...])
            if after.hasPrefix(":") {
                portPart = String(after.dropFirst())
            } else if !after.isEmpty {
                return nil
            }
        } else {
            if let colon = authority.lastIndex(of: ":") {
                hostPart = String(authority[..<colon])
                portPart = String(authority[authority.index(after: colon)...])
            }
            if hostPart.contains(":") {
                return nil
            }
        }
        for scalar in hostPart.unicodeScalars {
            let v = scalar.value
            if v <= 0x20 || scalar == "/" || scalar == "\\" || scalar == "?" || scalar == "#" || scalar == "@" || scalar == "%" {
                return nil
            }
        }
        url.host = hostPart.lowercased()
        if let portPart = portPart, !portPart.isEmpty {
            guard let port = Int(portPart), port >= 0, port <= 65535 else {
                return nil
            }
            url.port = port
        }
        url.withoutQueryAndFragment = url.scheme + "://" + userPrefix + authority + url.path
        return url
    }

    /// The first value of a query item, percent-decoded ('+' kept).
    func query(_ key: String) -> String {
        if rawQuery.isEmpty {
            return ""
        }
        for item in rawQuery.components(separatedBy: "&") {
            let name: String?
            let value: String?
            if let equals = item.firstIndex(of: "=") {
                name = ShareUrl.decode(String(item[..<equals]))
                value = ShareUrl.decode(String(item[item.index(after: equals)...]))
            } else {
                name = ShareUrl.decode(item)
                value = ""
            }
            if name == key {
                return value ?? ""
            }
        }
        return ""
    }

    /// Percent-decoding as UTF-8; nil on a broken escape.
    static func decode(_ text: String) -> String? {
        if !text.contains("%") {
            return text
        }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "%") {
                if i + 2 >= bytes.count {
                    return nil
                }
                guard let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) else {
                    return nil
                }
                out.append((high << 4) | low)
                i += 3
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            return c - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"):
            return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"):
            return c - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }
}
