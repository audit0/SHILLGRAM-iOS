/*
 * SHILLGRAM: SHILLVPN built into the app.
 *
 * The user's SHILLVPN subscription (the link from the bot or the site
 * cabinet, or the app's own free trial) is fetched, its VLESS / Hysteria 2
 * entries become an Xray config, and the Xray core inside the app serves a
 * local SOCKS5 port with a random login. Telegram's own connection (every
 * account, and the login before any account) goes through that port. An
 * in-app proxy only: no system VPN, other apps are not touched.
 *
 * The link, the fetched entries and the cabinet key are secrets: they live
 * in the Keychain (SecretStore), the config goes to the core in memory, and
 * none of them is ever logged. The syslog lines under "SHILLVPN:" carry
 * states and the local port only.
 *
 * A port of the Android client (ShillVpn.java) and of the desktop one
 * (shillgramm/shill_vpn.cpp). Everything here runs on the main queue;
 * network and core work goes to background queues and comes back.
 */
import Foundation
import UIKit
import Network
import os.log

/// Where Telegram's proxy is changed; implemented next to the account manager.
public protocol ShillVpnProxyHost: AnyObject {
    /// Points every account (and the login) at 127.0.0.1:port.
    func shillVpnUseLocalProxy(port: Int, user: String, password: String)
    /// Drops our local proxy; brings back the user's own one or goes direct.
    /// Does nothing to a proxy the user chose themselves.
    func shillVpnDropLocalProxy()
}

public final class ShillVpn {
    public enum State {
        case none // No subscription yet.
        case off
        case loading // Fetching the subscription.
        case starting // The core is starting.
        case on
        case error
    }

    public struct Plan {
        public let title: String
        public let days: Int
        public let priceRub: Int
    }

    public final class ShopInfo {
        public var plans: [Plan] = []
        public var referralDays: Int = 0
        public var devices: Int = 0
    }

    public static let shared = ShillVpn()

    public static let site = XrayConfig.site
    public static let bot = "SHILLVPN_bot"
    public static let termsUrl = "https://shillvpn.site/legal/terms"
    public static let userPrefix = "shill"
    private static let portAttempts = 50 // x 150 ms: the core has 7.5 s to listen.
    private static let maxRestarts = 5
    private static let refreshInterval: TimeInterval = 6 * 3600
    private static let fetchTimeout: TimeInterval = 15
    private static let trialPolls = 30 // x 2 s: the site's worker issues the trial.
    private static let shopInfoTtl: TimeInterval = 6 * 3600
    private static let remindBefore: Int64 = 24 * 3600

    public let secrets = SecretStore()
    private let flags = UserDefaults(suiteName: "shillgram_vpn") ?? UserDefaults.standard
    private let io = DispatchQueue(label: "shillvpn.io", attributes: .concurrent)
    private let direct: URLSession

    public weak var proxyHost: ShillVpnProxyHost?
    /// Whether a Telegram account is signed in (set by the app).
    public var hasTelegramAccount = false
    /// Telegram's language when the user chose one; the system's otherwise.
    public var languageCode: String = Locale.preferredLanguages.first ?? "en"
    /// Shows the renewal box (set by the app); false when nothing can show it now.
    public var showRenewReminder: ((_ ended: Bool, _ left: Int64, _ info: ShopInfo?) -> Bool)?

    private var listeners: [Int: () -> Void] = [:]
    private var nextListenerId = 0

    private var link = ""
    private var token = ""
    private var body: Data? // Last fetched subscription body, as served.
    private var entries: [XrayConfig.Entry] = []
    public private(set) var expiresAt: Int64 = 0
    public private(set) var isEnabled = false

    private var cabinetKey = "" // Site cabinet of the app's own trial.
    private var remindedAt: Int64 = 0
    private var shopInfo: ShopInfo?
    private var shopInfoAt: Date?
    private var trialBusy = false

    private var coreRunning = false
    private var coreGeneration = 0
    private var port = 0
    private var user = ""
    private var password = ""
    private var restarts = 0
    private var started = false

    public private(set) var state: State = .none
    public private(set) var error = ""

    private var restartWork: DispatchWorkItem?
    private var refreshWork: DispatchWorkItem?
    private var expiryWork: DispatchWorkItem?

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ShillVpn.fetchTimeout
        configuration.timeoutIntervalForResource = ShillVpn.fetchTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.direct = URLSession(configuration: configuration)
        self.loadFlags()
        self.loadSecrets()
        self.state = self.token.isEmpty ? .none : .off
    }

    // MARK: - Texts: the desktop Tr(en, ru) pairs.

    public var isRussian: Bool {
        return self.languageCode.lowercased().hasPrefix("ru")
    }

    public static func tr(_ en: String, _ ru: String) -> String {
        return ShillVpn.shared.isRussian ? ru : en
    }

    public static func daysText(_ days: Int) -> String {
        if !ShillVpn.shared.isRussian {
            return "\(days)" + (days == 1 ? " day" : " days")
        }
        return "\(days) " + russianPlural(days, one: "день", few: "дня", many: "дней")
    }

    public static func hoursText(_ hours: Int) -> String {
        if !ShillVpn.shared.isRussian {
            return "\(hours)" + (hours == 1 ? " hour" : " hours")
        }
        return "\(hours) " + russianPlural(hours, one: "час", few: "часа", many: "часов")
    }

    private static func russianPlural(_ n: Int, one: String, few: String, many: String) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 {
            return one
        } else if mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14) {
            return few
        }
        return many
    }

    /// Every page of the site opened from the app carries where it came
    /// from, so the site's statistics show what the app sells.
    public static func siteUrl(_ path: String, campaign: String?, fragment: String?) -> String {
        var result = site + path + "?utm_source=shillgram&utm_medium=app&utm_campaign=" + ((campaign ?? "").isEmpty ? "app" : campaign!)
        if let fragment = fragment, !fragment.isEmpty {
            result += "#" + fragment
        }
        return result
    }

    private static func now() -> Int64 {
        return Int64(Date().timeIntervalSince1970)
    }

    private static let log = OSLog(subsystem: "io.github.audit0.shillgram", category: "SHILLVPN")
    private static let debugQueue = DispatchQueue(label: "shillvpn.debuglog")

    /// States and the local port only: never a link, token, key or server.
    /// Goes to the system log and to Library/Caches/shillvpn-status.log
    /// (the last lines only), both readable when checking a device build.
    public static func debugLog(_ text: String) {
        os_log("SHILLVPN: %{public}@", log: log, type: .default, text)
        let line = "\(Date()) SHILLVPN: \(text)\n"
        debugQueue.async {
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return
            }
            let url = caches.appendingPathComponent("shillvpn-status.log")
            var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            content += line
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            if lines.count > 200 {
                content = lines.suffix(200).joined(separator: "\n") + "\n"
            }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Listeners (main queue). Each screen removes its own on close.

    public func addListener(_ listener: @escaping () -> Void) -> Int {
        let id = self.nextListenerId
        self.nextListenerId += 1
        self.listeners[id] = listener
        return id
    }

    public func removeListener(_ id: Int) {
        self.listeners.removeValue(forKey: id)
    }

    private func setState(_ state: State, _ error: String = "") {
        if self.state != state {
            ShillVpn.debugLog("state \(state)")
        }
        self.state = state
        self.error = error
        for listener in Array(self.listeners.values) {
            listener()
        }
    }

    private func after(_ delay: TimeInterval, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: f)
    }

    // MARK: - Lifecycle

    /// Application start, once the account manager is up: brings the core
    /// up again if it was on, drops a stale local proxy otherwise.
    public func start() {
        if self.started {
            return
        }
        self.started = true
        ShillVpn.debugLog("start, subscription \(self.token.isEmpty ? "none" : "kept"), \(self.isEnabled ? "enabled" : "disabled")")
        if self.isEnabled && !self.token.isEmpty {
            if !self.entries.isEmpty {
                self.launch() // From the kept list: works when the site is slow.
            }
            self.refresh()
        } else {
            // The core is not coming: do not wait on its port.
            self.proxyHost?.shillVpnDropLocalProxy()
        }
        self.scheduleExpiryCheck()
        self.after(10.0, { [weak self] in
            self?.checkReminder()
        })
    }

    /// The app came to the foreground: iOS may have taken the core's
    /// listening socket while the app was suspended. Checks it and starts
    /// the core again when it does not answer.
    public func applicationDidBecomeActive() {
        guard self.started, self.isEnabled, self.coreRunning, self.state == .on, self.port != 0 else {
            return
        }
        let checkPort = self.port
        let generation = self.coreGeneration
        self.io.async { [weak self] in
            let listening = ShillVpn.isListening(port: checkPort)
            DispatchQueue.main.async {
                guard let self = self, generation == self.coreGeneration, self.port == checkPort else {
                    return
                }
                if !listening {
                    ShillVpn.debugLog("core port stopped answering, restarting")
                    self.restarts = 0
                    self.launch()
                }
            }
        }
    }

    public var hasSubscription: Bool {
        return !self.token.isEmpty
    }

    public func statusText() -> String {
        let now = ShillVpn.now()
        let left = self.expiresAt > now ? ShillVpn.daysText(Int((self.expiresAt - now + 86399) / 86400)) : ""
        switch self.state {
        case .none:
            return ShillVpn.tr("Not connected", "Не подключён")
        case .off:
            if self.accessEnded {
                return ShillVpn.tr("Access ended · Telegram connects directly", "Доступ закончился · Telegram подключается напрямую")
            }
            return ShillVpn.tr("Off", "Выключен") + (left.isEmpty ? "" : " · " + left)
        case .loading:
            return ShillVpn.tr("Loading the subscription…", "Загружаю подписку…")
        case .starting:
            return ShillVpn.tr("Connecting…", "Подключаю…")
        case .on:
            if self.expiresAt != 0 && self.expiresAt <= now {
                return ShillVpn.tr("Access ended", "Доступ закончился")
            }
            return ShillVpn.tr("On", "Включён") + (left.isEmpty ? "" : " · " + left)
        case .error:
            return self.error
        }
    }

    /// Short line for menus: "SHILLVPN · 3 дня".
    public func menuText() -> String {
        let now = ShillVpn.now()
        if self.state == .none {
            return "SHILLVPN"
        } else if self.expiresAt > now {
            return "SHILLVPN · " + ShillVpn.daysText(Int((self.expiresAt - now + 86399) / 86400))
        } else if self.expiresAt != 0 {
            return "SHILLVPN · " + ShillVpn.tr("renew", "продлить")
        }
        return "SHILLVPN"
    }

    public var hasCabinet: Bool {
        return !self.cabinetKey.isEmpty
    }

    public func cabinetUrl(campaign: String) -> String {
        // The key goes in the fragment: it stays in the browser.
        return ShillVpn.siteUrl("/app/buy/", campaign: campaign, fragment: "k=" + self.cabinetKey)
    }

    /// Page on the site to connect another device (INCY, Happ...).
    public func connectPageUrl() -> String {
        return self.token.isEmpty ? ShillVpn.site + "/app/buy/" : ShillVpn.site + "/c/" + self.token
    }

    /// The paid time is over (the server's expire already counts the grace
    /// days): the tunnel is stopped and Telegram connects directly.
    public var accessEnded: Bool {
        return self.expiresAt != 0 && self.expiresAt <= ShillVpn.now()
    }

    /// Nothing that could carry Telegram: no subscription, or its time is over.
    public var needsConnection: Bool {
        return self.token.isEmpty || self.accessEnded
    }

    private func scheduleExpiryCheck() {
        self.expiryWork?.cancel()
        self.expiryWork = nil
        let now = ShillVpn.now()
        if self.expiresAt == 0 || self.expiresAt <= now {
            return
        }
        // A day before the end (the reminder) and at the end itself.
        let left = self.expiresAt - now
        let next = left > ShillVpn.remindBefore ? left - ShillVpn.remindBefore : left
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        self.expiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(min(next, 7 * 86400) + 5), execute: work)
    }

    /// Once a day before the end and every 12 hours after it: a box with the
    /// live prices and «Продлить».
    public func checkReminder() {
        if self.token.isEmpty || self.expiresAt == 0 {
            return
        }
        let now = ShillVpn.now()
        let left = self.expiresAt - now
        let ended = left <= 0
        if !ended && left > ShillVpn.remindBefore {
            return
        }
        let due: Bool
        if ended {
            due = self.remindedAt == 0 || self.remindedAt < self.expiresAt || now - self.remindedAt >= 12 * 3600
        } else {
            due = self.remindedAt == 0 || now - self.remindedAt >= 20 * 3600
        }
        guard due, let show = self.showRenewReminder else {
            return
        }
        self.loadShopInfo { [weak self] info in
            guard let self = self else {
                return
            }
            if show(ended, left, info) {
                self.remindedAt = now
                self.saveFlags()
            }
        }
    }

    // MARK: - shillvpn.site

    /// shop_info of the site, kept for 6 hours; done(nil) when unknown.
    public func loadShopInfo(_ done: @escaping (ShopInfo?) -> Void) {
        if let shopInfo = self.shopInfo, let at = self.shopInfoAt, Date().timeIntervalSince(at) < ShillVpn.shopInfoTtl {
            done(shopInfo)
            return
        }
        self.api(["action": "shop_info"], viaCore: false) { [weak self] reply in
            guard let self = self else {
                return
            }
            guard let reply = reply, ShillVpn.bool(reply, "ok") else {
                done(self.shopInfo)
                return
            }
            let info = ShopInfo()
            for value in (reply["plans"] as? [Any]) ?? [] {
                guard let plan = value as? [String: Any] else {
                    continue
                }
                let days = ShillVpn.number(plan, "days")
                let price = ShillVpn.number(plan, "price_rub")
                if days > 0 && price > 0 {
                    info.plans.append(Plan(title: ShillVpn.string(plan, "title"), days: days, priceRub: price))
                }
            }
            info.referralDays = ShillVpn.number(reply, "referral_days")
            info.devices = ShillVpn.number(reply, "devices")
            if !info.plans.isEmpty {
                self.shopInfo = info
                self.shopInfoAt = Date()
            }
            done(self.shopInfo)
        }
    }

    /// A session through our own tunnel (iOS 17+: SOCKS5 with a login).
    private func tunnelSession() -> URLSession? {
        guard #available(iOS 17.0, *), self.coreRunning, self.port != 0, let nwPort = NWEndpoint.Port(rawValue: UInt16(self.port)) else {
            return nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ShillVpn.fetchTimeout
        configuration.timeoutIntervalForResource = ShillVpn.fetchTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let proxy = ProxyConfiguration(socksv5Proxy: NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort))
        proxy.applyCredential(username: self.user, password: self.password)
        configuration.proxyConfigurations = [proxy]
        return URLSession(configuration: configuration)
    }

    /// POST to shillvpn.site/app/api; done(nil) when out of reach.
    private func api(_ request: [String: Any], viaCore: Bool, done: @escaping ([String: Any]?) -> Void) {
        let session: URLSession
        if viaCore {
            guard let tunnel = self.tunnelSession() else {
                done(nil)
                return
            }
            session = tunnel
        } else {
            session = self.direct
        }
        guard let url = URL(string: ShillVpn.site + "/app/api") else {
            done(nil)
            return
        }
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.setValue("SHILLGRAM/1.0", forHTTPHeaderField: "User-Agent")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = Data(XrayConfig.writeJson(request).utf8)
        session.dataTask(with: http) { [weak self] data, response, _ in
            // The error is never logged: the request may carry the cabinet key.
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = XrayConfig.parseObject(data)
            DispatchQueue.main.async {
                if viaCore {
                    session.finishTasksAndInvalidate()
                }
                guard let self = self else {
                    return
                }
                if code == 429 || code == 503 {
                    // Plain text from the front server: wait and ask again.
                    done(["ok": false, "error": "busy"])
                } else if let object = object {
                    done(object)
                } else if !viaCore && self.coreRunning && self.port != 0 && self.state == .on {
                    // The site is out of reach directly: through our own tunnel.
                    self.api(request, viaCore: true, done: done)
                } else {
                    done(nil)
                }
            }
        }.resume()
    }

    // MARK: - The free trial

    private static func trialError(_ code: String) -> String {
        if code == "trial_used" {
            return tr("This device has already had its free days. Buy SHILLVPN on the site or paste your subscription link.", "На этом устройстве бесплатные дни уже были. Купите SHILLVPN на сайте или вставьте ссылку подписки.")
        } else if code == "busy" || code == "pow" {
            return tr("Too many requests right now. Try again in a few minutes.", "Сейчас много запросов. Попробуйте через несколько минут.")
        } else if code == "closed" || code == "unavailable" {
            return tr("Free days are not given out right now. Buy SHILLVPN on the site or paste your subscription link.", "Бесплатные дни сейчас не выдаются. Купите SHILLVPN на сайте или вставьте ссылку подписки.")
        }
        return tr("Free days in the app are coming soon. For now take 3 days in @SHILLVPN_bot and paste the subscription link here.", "Бесплатные дни в приложении скоро появятся. Пока возьмите 3 дня в @SHILLVPN_bot и вставьте ссылку подписки сюда.")
    }

    /// One trial per device: the site keeps only a hash of this value, and
    /// the value itself is a keyed hash of the device id, never the id.
    /// The id is random, kept in the Keychain (it outlives a reinstall).
    private func deviceId() -> String {
        var id = self.secrets.readString("device") ?? ""
        if id.isEmpty {
            var bytes = [UInt8](repeating: 0, count: 16)
            if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
                bytes = Array(UUID().uuidString.utf8.prefix(16))
            }
            id = TrialWork.hex(bytes)
            self.secrets.write("device", id)
        }
        return TrialWork.deviceHash(Data(id.utf8))
    }

    /// First launch: three free days for this device from shillvpn.site (one
    /// per device, the site decides). done("") once the tunnel runs on the
    /// new subscription.
    public func startTrial(_ done: @escaping (String) -> Void) {
        if self.trialBusy {
            return
        }
        self.trialBusy = true
        let finish: (String) -> Void = { [weak self] error in
            self?.trialBusy = false
            done(error)
        }
        if !self.cabinetKey.isEmpty {
            // Taken before, the app closed while the site prepared it.
            self.waitTrialReady(attempt: 0, done: finish)
            return
        }
        ShillVpn.debugLog("trial requested")
        let device = self.deviceId()
        let hour = ShillVpn.now() / 3600
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let work = TrialWork.solve(prefix: TrialWork.prefix(device: device, hour: hour))
            DispatchQueue.main.async {
                self?.requestTrial(device: device, hour: hour, work: work, finish: finish)
            }
        }
    }

    private func requestTrial(device: String, hour: Int64, work: String, finish: @escaping (String) -> Void) {
        self.api([
            "action": "shop_app_trial",
            "device": device,
            "accept_terms": true,
            "lang": self.isRussian ? "ru" : "en",
            "pow_hour": hour,
            "pow": work
        ], viaCore: false) { [weak self] reply in
            guard let self = self else {
                return
            }
            guard let reply = reply else {
                finish(ShillVpn.tr("shillvpn.site does not open from this network. Buy SHILLVPN from another network or from your phone and paste the subscription link here.", "shillvpn.site не открывается из этой сети. Купите SHILLVPN из другой сети или с телефона и вставьте ссылку подписки сюда."))
                return
            }
            let key = ShillVpn.string(reply, "key")
            if !ShillVpn.bool(reply, "ok") || key.isEmpty {
                finish(ShillVpn.trialError(ShillVpn.string(reply, "error")))
                return
            }
            self.cabinetKey = key
            self.secrets.write("cabinet", key)
            self.waitTrialReady(attempt: 0, done: finish)
        }
    }

    private func waitTrialReady(attempt: Int, done: @escaping (String) -> Void) {
        self.api([
            "action": "shop_app_status",
            "key": self.cabinetKey
        ], viaCore: false) { [weak self] reply in
            guard let self = self else {
                return
            }
            if let reply = reply, ShillVpn.bool(reply, "ok") {
                let status = ShillVpn.string(reply["subscription"] as? [String: Any], "status")
                if status == "expired" {
                    done(ShillVpn.tr("The free days of this device are over. Buy SHILLVPN to go on.", "Бесплатные дни на этом устройстве закончились. Купите SHILLVPN, чтобы продолжить."))
                    return
                }
                let url = ShillVpn.string(reply, "subscription_url")
                if ShillVpn.bool(reply, "ready") && XrayConfig.tokenFromLink(url) != nil {
                    ShillVpn.debugLog("trial ready")
                    self.setLink(url, done: done)
                    return
                }
            } else if let reply = reply, ShillVpn.string(reply, "error") == "bad_key" {
                self.cabinetKey = ""
                self.secrets.remove("cabinet")
                done(ShillVpn.trialError(""))
                return
            }
            if attempt + 1 >= ShillVpn.trialPolls {
                done(ShillVpn.tr("The free days are still being prepared. Try again in a minute.", "Бесплатные дни ещё готовятся. Попробуйте через минуту."))
                return
            }
            self.after(2.0, { [weak self] in
                self?.waitTrialReady(attempt: attempt + 1, done: done)
            })
        }
    }

    // MARK: - The subscription

    /// Accepts /sub/, /c/, /r/<app>/ links or the bare token; fetches it,
    /// keeps it and turns the tunnel on. done("") on success.
    public func setLink(_ newLink: String, done: @escaping (String) -> Void) {
        guard let newToken = XrayConfig.tokenFromLink(newLink) else {
            done(ShillVpn.tr("This is not a SHILLVPN subscription link.", "Это не ссылка подписки SHILLVPN."))
            return
        }
        let wasLink = self.link
        let wasToken = self.token
        self.link = XrayConfig.javaTrim(newLink)
        self.token = newToken
        self.setState(.loading)
        self.fetch { [weak self] error in
            guard let self = self else {
                return
            }
            if !error.isEmpty {
                self.link = wasLink
                self.token = wasToken
                self.setState(self.token.isEmpty ? .none : .off)
                done(error)
                return
            }
            self.saveSecrets()
            self.isEnabled = true
            self.saveFlags()
            self.restarts = 0
            self.scheduleExpiryCheck()
            self.launch()
            done("")
        }
    }

    public func setEnabled(_ value: Bool) {
        if self.token.isEmpty || self.isEnabled == value {
            return
        }
        self.isEnabled = value
        self.saveFlags()
        if value {
            self.restarts = 0
            if self.entries.isEmpty {
                self.refresh()
            } else {
                self.launch()
            }
        } else {
            self.stopCore()
            self.setState(.off)
        }
    }

    public func refresh() {
        if self.token.isEmpty {
            return
        }
        self.refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        self.refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ShillVpn.refreshInterval, execute: work)
        let was = self.body
        if self.state != .on {
            self.setState(.loading)
        }
        self.fetch { [weak self] error in
            guard let self = self else {
                return
            }
            if !error.isEmpty {
                if self.state == .loading {
                    self.setState(self.entries.isEmpty ? .error : .off, error)
                    if self.isEnabled && !self.entries.isEmpty {
                        self.launch()
                    }
                }
                return
            }
            self.saveSecrets()
            if self.accessEnded {
                // Not a hostage: without paid time Telegram goes direct.
                self.stopCore()
                self.setState(.off)
            } else if !self.isEnabled {
                self.setState(.off)
            } else if self.body != was || !self.coreRunning {
                self.launch()
            } else {
                self.setState(.on) // Same list: refreshes the days left.
            }
            self.scheduleExpiryCheck()
            self.checkReminder()
        }
    }

    public func forget() {
        self.setEnabled(false)
        self.link = ""
        self.token = ""
        self.body = nil
        self.entries = []
        self.expiresAt = 0
        self.secrets.remove("link")
        self.secrets.remove("body")
        self.saveFlags()
        self.setState(.none)
    }

    private func fetch(_ done: @escaping (String) -> Void) {
        let url = XrayConfig.subscriptionUrl(link: self.link, token: self.token)
        self.fetchVia(url, viaCore: false, done: done)
    }

    private func fetchVia(_ urlString: String, viaCore: Bool, done: @escaping (String) -> Void) {
        let session: URLSession
        if viaCore {
            guard let tunnel = self.tunnelSession() else {
                done(ShillVpn.tr("Could not reach shillvpn.site. Check the internet and try again.", "Не удалось связаться с shillvpn.site. Проверьте интернет и попробуйте ещё раз."))
                return
            }
            session = tunnel
        } else {
            session = self.direct
        }
        guard let url = URL(string: urlString) else {
            done(ShillVpn.tr("This is not a SHILLVPN subscription link.", "Это не ссылка подписки SHILLVPN."))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("ShillGramm/1.0", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, _ in
            // Never logged: the error text may carry the link.
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            let userInfo = http?.value(forHTTPHeaderField: "subscription-userinfo")
            let payload = code == 200 ? data : nil
            let parsed = payload.map { XrayConfig.parseBody($0) } ?? []
            DispatchQueue.main.async {
                if viaCore {
                    session.finishTasksAndInvalidate()
                }
                guard let self = self else {
                    return
                }
                if code == 200, let payload = payload {
                    if parsed.isEmpty {
                        done(ShillVpn.tr("The subscription has no servers this app can use.", "В подписке нет серверов, которые открывает приложение."))
                        return
                    }
                    self.body = payload
                    self.entries = parsed
                    self.expiresAt = XrayConfig.expireFromUserInfo(userInfo)
                    self.saveFlags()
                    ShillVpn.debugLog("subscription fetched, \(parsed.count) servers")
                    done("")
                } else if code == 404 || code == 403 {
                    done(ShillVpn.tr("The link is not valid anymore. Take a new one in @SHILLVPN_bot or in the cabinet on the site.", "Ссылка больше не действует. Возьмите новую в @SHILLVPN_bot или в кабинете на сайте."))
                } else if !viaCore && self.coreRunning && self.port != 0 {
                    // The site is out of reach directly: try through the tunnel.
                    self.fetchVia(urlString, viaCore: true, done: done)
                } else {
                    ShillVpn.debugLog("subscription fetch failed, http \(code)")
                    done(ShillVpn.tr("Could not reach shillvpn.site. Check the internet and try again.", "Не удалось связаться с shillvpn.site. Проверьте интернет и попробуйте ещё раз."))
                }
            }
        }.resume()
    }

    // MARK: - The core

    private static func randomString(_ length: Int) -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
            for i in 0 ..< length {
                bytes[i] = UInt8.random(in: 0 ... 255)
            }
        }
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    private func launch() {
        if !self.isEnabled || self.entries.isEmpty {
            return
        } else if self.accessEnded {
            self.stopCore()
            self.setState(.off)
            return
        }
        self.killCore()
        self.port = ShillVpn.freePort()
        if self.port == 0 {
            self.proxyHost?.shillVpnDropLocalProxy()
            self.setState(.error, ShillVpn.tr("No free local port for the VPN.", "Нет свободного локального порта для VPN."))
            return
        }
        self.user = ShillVpn.userPrefix + ShillVpn.randomString(8)
        self.password = ShillVpn.randomString(24)
        self.setState(.starting)

        self.coreGeneration += 1
        let generation = self.coreGeneration
        let config = XrayConfig.build(entries: self.entries, port: self.port, user: self.user, password: self.password)
        ShillXrayCore.start(configJson: config) { [weak self] ok in
            guard let self = self, generation == self.coreGeneration else {
                return
            }
            if ok {
                self.coreRunning = true
                self.waitForPort(attempt: 0, generation: generation)
            } else {
                ShillVpn.debugLog("core did not start")
                self.coreFinished()
            }
        }
    }

    private func waitForPort(attempt: Int, generation: Int) {
        if generation != self.coreGeneration || !self.coreRunning {
            return
        }
        let checkPort = self.port
        self.io.async { [weak self] in
            let listening = ShillVpn.isListening(port: checkPort)
            DispatchQueue.main.async {
                guard let self = self, generation == self.coreGeneration, self.coreRunning, self.port == checkPort else {
                    return
                }
                if listening {
                    ShillVpn.debugLog("core started on port \(checkPort)")
                    self.proxyHost?.shillVpnUseLocalProxy(port: self.port, user: self.user, password: self.password)
                    self.setState(.on)
                    self.after(60.0, { [weak self] in
                        if let self = self, generation == self.coreGeneration {
                            self.restarts = 0
                        }
                    })
                } else if attempt + 1 < ShillVpn.portAttempts {
                    self.after(0.15, { [weak self] in
                        self?.waitForPort(attempt: attempt + 1, generation: generation)
                    })
                } else {
                    self.proxyHost?.shillVpnDropLocalProxy()
                    self.setState(.error, ShillVpn.tr("The VPN core did not start.", "Ядро VPN не запустилось."))
                }
            }
        }
    }

    private func coreFinished() {
        self.coreRunning = false
        if !self.isEnabled {
            return
        }
        self.restarts += 1
        if self.restarts <= ShillVpn.maxRestarts {
            self.setState(.starting)
            self.restartWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.launch()
            }
            self.restartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(self.restarts * self.restarts), execute: work)
        } else {
            self.proxyHost?.shillVpnDropLocalProxy()
            self.setState(.error, ShillVpn.tr("The VPN core keeps stopping. Turn it off and on again.", "Ядро VPN останавливается. Выключите и включите его снова."))
        }
    }

    /// Stops the running core without touching Telegram's proxy.
    private func killCore() {
        self.restartWork?.cancel()
        self.restartWork = nil
        self.coreGeneration += 1 // Its end is not a crash to restart from.
        if self.coreRunning {
            self.coreRunning = false
            ShillXrayCore.stop()
        }
    }

    private func stopCore() {
        self.killCore()
        self.proxyHost?.shillVpnDropLocalProxy()
    }

    // MARK: - Local sockets

    private static func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            return 0
        }
        defer { close(fd) }
        var address = loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if bound != 0 {
            return 0
        }
        var result = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &result) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        if named != 0 {
            return 0
        }
        return Int(UInt16(bigEndian: result.sin_port))
    }

    /// Whether something accepts TCP on 127.0.0.1:port (500 ms at most).
    static func isListening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            return false
        }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var address = loopbackAddress(port: port)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if connected == 0 {
            return true
        }
        if errno != EINPROGRESS {
            return false
        }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        if poll(&descriptor, 1, 500) <= 0 {
            return false
        }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) != 0 {
            return false
        }
        return socketError == 0
    }

    // MARK: - Storage

    private func saveSecrets() {
        self.secrets.write("link", self.link)
        if let body = self.body {
            self.secrets.write("body", body)
        }
    }

    private func loadSecrets() {
        if let key = self.secrets.readString("cabinet") {
            self.cabinetKey = key
        }
        guard let savedLink = self.secrets.readString("link"), let savedToken = XrayConfig.tokenFromLink(savedLink) else {
            return
        }
        self.link = savedLink
        self.token = savedToken
        if let savedBody = self.secrets.read("body") {
            let parsed = XrayConfig.parseBody(savedBody)
            if !parsed.isEmpty {
                self.body = savedBody
                self.entries = parsed
            }
        }
    }

    private func saveFlags() {
        self.flags.set(self.isEnabled, forKey: "enabled")
        self.flags.set(NSNumber(value: self.expiresAt), forKey: "expires")
        self.flags.set(NSNumber(value: self.remindedAt), forKey: "reminded")
    }

    private func loadFlags() {
        self.isEnabled = self.flags.bool(forKey: "enabled")
        self.expiresAt = (self.flags.object(forKey: "expires") as? NSNumber)?.int64Value ?? 0
        self.remindedAt = (self.flags.object(forKey: "reminded") as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - JSON helpers

    static func bool(_ object: [String: Any]?, _ key: String) -> Bool {
        return (object?[key] as? NSNumber)?.boolValue ?? false
    }

    static func string(_ object: [String: Any]?, _ key: String) -> String {
        return (object?[key] as? String) ?? ""
    }

    static func number(_ object: [String: Any]?, _ key: String) -> Int {
        return (object?[key] as? NSNumber)?.intValue ?? 0
    }
}
