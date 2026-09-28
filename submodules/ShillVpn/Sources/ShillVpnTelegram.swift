/*
 * SHILLGRAM: SHILLVPN built into the app — the Telegram side.
 *
 * Points Telegram's own proxy settings (the account manager's shared data,
 * the same place the Proxy screen writes) at the core's local SOCKS5 port,
 * so every account uses it; the login's network is updated directly, since
 * an unauthorized account does not follow the setting once it is up. The
 * user's own proxy is kept in the Keychain and comes back when SHILLVPN
 * turns off.
 */
import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import MtProtoKit
import Display
import TelegramPresentationData
import AccountContext

public final class ShillVpnTelegram: ShillVpnProxyHost {
    public static let shared = ShillVpnTelegram()

    private var accountManager: AccountManager<TelegramAccountManagerTypes>?
    private weak var unauthorizedNetwork: Network?

    private init() {
    }

    /// App start, once the account manager is up: attaches the proxy side
    /// and brings the core up when SHILLVPN was on.
    public func setup(accountManager: AccountManager<TelegramAccountManagerTypes>) {
        self.accountManager = accountManager
        ShillVpn.shared.proxyHost = self
        ShillVpn.debugLog("setup")
        ShillVpn.shared.start()
    }

    /// The login's network (nil once there is none): it gets the current
    /// proxy right away and every later change.
    public func setUnauthorizedNetwork(_ network: Network?) {
        self.unauthorizedNetwork = network
        guard let network = network, let accountManager = self.accountManager else {
            return
        }
        let _ = (accountManager.transaction { transaction -> ProxyServerSettings? in
            return transaction.getSharedData(SharedDataKeys.proxySettings)?.get(ProxySettings.self)?.effectiveActiveServer
        }
        |> deliverOnMainQueue).start(next: { [weak self, weak network] active in
            guard let self = self, let network = network, network === self.unauthorizedNetwork else {
                return
            }
            ShillVpnTelegram.apply(active, to: network)
        })
    }

    private let connectionDisposable = MetaDisposable()

    /// Writes Telegram's connection state changes to the SHILLVPN status
    /// lines: whether Telegram got online and through which kind of route
    /// (the in-app port, another proxy, or direct), never an address.
    public func watchConnection(_ network: Network?) {
        guard let network = network else {
            self.connectionDisposable.set(nil)
            return
        }
        self.connectionDisposable.set((network.connectionStatus
        |> map { status -> String in
            func route(_ address: String?) -> String {
                guard let address = address else {
                    return "direct"
                }
                return address.hasPrefix("127.0.0.1") ? "via SHILLVPN" : "via another proxy"
            }
            switch status {
            case .waitingForNetwork:
                return "waiting for network"
            case let .connecting(proxyAddress, proxyHasConnectionIssues):
                return "connecting " + route(proxyAddress) + (proxyHasConnectionIssues ? ", proxy has issues" : "")
            case let .updating(proxyAddress):
                return "updating " + route(proxyAddress)
            case let .online(proxyAddress):
                return "online " + route(proxyAddress)
            }
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { text in
            ShillVpn.debugLog("telegram " + text)
        }))
    }

    static func isOurs(_ server: ProxyServerSettings) -> Bool {
        guard server.host == "127.0.0.1", case let .socks5(username, _) = server.connection, let user = username else {
            return false
        }
        return user.hasPrefix(ShillVpn.userPrefix)
    }

    public func shillVpnUseLocalProxy(port: Int, user: String, password: String) {
        guard let accountManager = self.accountManager else {
            return
        }
        let ours = ProxyServerSettings(host: "127.0.0.1", port: Int32(port), connection: .socks5(username: user, password: password))
        let _ = (accountManager.transaction { transaction -> ProxyServerSettings? in
            var previous: ProxyServerSettings?
            let _ = updateProxySettingsInteractively(transaction: transaction, { current in
                var updated = current
                if current.enabled, let active = current.activeServer, !ShillVpnTelegram.isOurs(active) {
                    // Someone's own proxy: bring it back when we turn off.
                    previous = active
                }
                updated.servers.removeAll(where: { ShillVpnTelegram.isOurs($0) })
                updated.servers.insert(ours, at: 0)
                updated.activeServer = ours
                updated.enabled = true
                // Calls are UDP: the local port serves TCP only.
                updated.useForCalls = false
                return updated
            })
            return previous
        }
        |> deliverOnMainQueue).start(next: { [weak self] previous in
            if let previous = previous, let data = try? JSONEncoder().encode(previous) {
                ShillVpn.shared.secrets.write("previous_proxy", data)
            }
            if let network = self?.unauthorizedNetwork {
                ShillVpnTelegram.apply(ours, to: network)
            }
        })
    }

    public func shillVpnDropLocalProxy() {
        guard let accountManager = self.accountManager else {
            return
        }
        let saved = ShillVpn.shared.secrets.read("previous_proxy").flatMap { try? JSONDecoder().decode(ProxyServerSettings.self, from: $0) }
        let _ = (accountManager.transaction { transaction -> (changed: Bool, active: ProxyServerSettings?) in
            var changed = false
            var active: ProxyServerSettings?
            let _ = updateProxySettingsInteractively(transaction: transaction, { current in
                var updated = current
                let oursActive = current.activeServer.map { ShillVpnTelegram.isOurs($0) } ?? false
                updated.servers.removeAll(where: { ShillVpnTelegram.isOurs($0) })
                if oursActive {
                    changed = true
                    if let saved = saved, !ShillVpnTelegram.isOurs(saved) {
                        if !updated.servers.contains(saved) {
                            updated.servers.insert(saved, at: 0)
                        }
                        updated.activeServer = saved
                        updated.enabled = true
                        active = saved
                    } else {
                        updated.activeServer = nil
                        updated.enabled = false
                        active = nil
                    }
                }
                return updated
            })
            return (changed, active)
        }
        |> deliverOnMainQueue).start(next: { [weak self] result in
            guard result.changed else {
                return
            }
            ShillVpn.shared.secrets.remove("previous_proxy")
            if let network = self?.unauthorizedNetwork {
                ShillVpnTelegram.apply(result.active, to: network)
            }
        })
    }

    private static func apply(_ server: ProxyServerSettings?, to network: Network) {
        let updated: MTSocksProxySettings? = server.flatMap { server in
            switch server.connection {
            case let .socks5(username, password):
                return MTSocksProxySettings(ip: server.host, port: UInt16(clamping: server.port), username: username, password: password, secret: nil)
            case let .mtp(secret):
                return MTSocksProxySettings(ip: server.host, port: UInt16(clamping: server.port), username: nil, password: nil, secret: secret)
            }
        }
        network.context.updateApiEnvironment { [weak network] environment in
            let current = environment?.socksProxySettings
            let updateNetwork: Bool
            if let current = current, let updated = updated {
                updateNetwork = !current.isEqual(updated)
            } else {
                updateNetwork = (current != nil) != (updated != nil)
            }
            if updateNetwork {
                network?.dropConnectionStatus()
                return environment?.withUpdatedSocksProxySettings(updated)
            } else {
                return nil
            }
        }
    }

    // MARK: - Screens

    /// Telegram's language when the user chose one; the system's otherwise
    /// (a fresh install is English until the user picks a language).
    public static func updateLanguage(_ presentationData: PresentationData) {
        let code = presentationData.strings.baseLanguageCode
        if !code.isEmpty && code != "en" {
            ShillVpn.shared.languageCode = code
        } else {
            ShillVpn.shared.languageCode = Locale.preferredLanguages.first ?? "en"
        }
    }

    public static func palette(_ theme: PresentationTheme) -> ShillVpnScreen.Palette {
        return ShillVpnScreen.Palette(
            background: theme.list.blocksBackgroundColor,
            card: theme.list.itemBlocksBackgroundColor,
            primaryText: theme.list.itemPrimaryTextColor,
            secondaryText: theme.list.itemSecondaryTextColor,
            accent: theme.list.itemAccentColor,
            accentForeground: theme.list.itemCheckColors.foregroundColor,
            destructive: theme.list.itemDestructiveColor,
            success: UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1.0),
            warning: UIColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1.0),
            isDark: theme.overallDarkAppearance
        )
    }

    /// A t.me link opens inside Telegram when an account is signed in; the
    /// site opens in the browser.
    public static func openUrl(_ url: String, sharedContext: SharedAccountContext, context: AccountContext?) {
        if url.hasPrefix("https://t.me/"), let context = context {
            let presentationData = sharedContext.currentPresentationData.with { $0 }
            let navigationController = sharedContext.mainWindow?.viewController as? NavigationController
            sharedContext.openExternalUrl(context: context, urlContext: .generic, url: url, forceExternal: false, presentationData: presentationData, navigationController: navigationController, dismissInput: {})
        } else {
            sharedContext.applicationBindings.openUrl(url)
        }
    }

    public static func makeScreen(mode: ShillVpnScreen.Mode, sharedContext: SharedAccountContext, context: AccountContext?) -> ShillVpnScreen {
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        updateLanguage(presentationData)
        weak var screenRef: ShillVpnScreen?
        let screen = ShillVpnScreen(mode: mode, palette: palette(presentationData.theme), openUrl: { url in
            if url.hasPrefix("https://t.me/"), context != nil, let screen = screenRef {
                // Telegram's own screens open under this one: close it first.
                screen.dismiss(animated: true, completion: {
                    openUrl(url, sharedContext: sharedContext, context: context)
                })
            } else {
                openUrl(url, sharedContext: sharedContext, context: context)
            }
        })
        screenRef = screen
        return screen
    }

    public static func present(mode: ShillVpnScreen.Mode, sharedContext: SharedAccountContext, context: AccountContext?) {
        guard let window = sharedContext.mainWindow else {
            return
        }
        window.presentNative(makeScreen(mode: mode, sharedContext: sharedContext, context: context))
    }

    /// The renewal box, shown over whatever is on screen while the app is active.
    public static func installReminder(sharedContext: SharedAccountContext, currentContext: @escaping () -> AccountContext?) {
        ShillVpn.shared.showRenewReminder = { [weak sharedContext] ended, left, info in
            guard let sharedContext = sharedContext, UIApplication.shared.applicationState == .active, let window = sharedContext.mainWindow else {
                return false
            }
            updateLanguage(sharedContext.currentPresentationData.with { $0 })
            let alert = ShillVpnScreen.renewAlert(ended: ended, left: left, info: info, openUrl: { [weak sharedContext] url in
                if let sharedContext = sharedContext {
                    openUrl(url, sharedContext: sharedContext, context: currentContext())
                }
            })
            window.presentNative(alert)
            return true
        }
    }
}
