/*
 * SHILLGRAM: SHILLVPN built into the app — the screen.
 *
 * The same states and buttons as the desktop SHILLVPN box and the Android
 * sheet (ShillVpnSheet.java): the free trial, «Купить SHILLVPN», a pasted
 * subscription link, then the connection status and the subscription's
 * actions. Plain UIKit, colored from Telegram's theme by the caller; the
 * controls use the system glass material on iOS 26 and later, the text
 * stays on a solid background.
 *
 * At app start without a working subscription it is the first screen, over
 * the login (the connection first, then the login); it is also opened from
 * Settings.
 */
import Foundation
import UIKit

public final class ShillVpnScreen: UIViewController, UITextFieldDelegate {
    public struct Palette {
        public var background: UIColor
        public var card: UIColor
        public var primaryText: UIColor
        public var secondaryText: UIColor
        public var accent: UIColor
        public var accentForeground: UIColor
        public var destructive: UIColor
        public var success: UIColor
        public var warning: UIColor
        public var isDark: Bool

        public init(background: UIColor, card: UIColor, primaryText: UIColor, secondaryText: UIColor, accent: UIColor, accentForeground: UIColor, destructive: UIColor, success: UIColor, warning: UIColor, isDark: Bool) {
            self.background = background
            self.card = card
            self.primaryText = primaryText
            self.secondaryText = secondaryText
            self.accent = accent
            self.accentForeground = accentForeground
            self.destructive = destructive
            self.success = success
            self.warning = warning
            self.isDark = isDark
        }
    }

    public enum Mode {
        /// App start: shown before the login, closed with «Продолжить» / «Позже».
        case firstScreen
        /// From Settings.
        case settings
    }

    private let mode: Mode
    private let palette: Palette
    private let openUrl: (String) -> Void
    private var listenerId: Int?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var subscribedLayout = false

    private var statusDot: UIView?
    private var statusLabel: UILabel?
    private var errorLabel: UILabel?
    private var trialButton: UIButton?
    private var connectButton: UIButton?
    private var toggleButton: UIButton?
    private var closeButton: UIButton?
    private var linkField: UITextField?
    private var linkBusy = false
    private var trialBusy = false

    /// openUrl: opens a site page or a t.me link (the caller decides where).
    public init(mode: Mode, palette: Palette, openUrl: @escaping (String) -> Void) {
        self.mode = mode
        self.palette = palette
        self.openUrl = openUrl
        super.init(nibName: nil, bundle: nil)
        if mode == .firstScreen {
            self.modalPresentationStyle = .fullScreen
            self.isModalInPresentation = true
        } else {
            self.modalPresentationStyle = .pageSheet
        }
        self.overrideUserInterfaceStyle = palette.isDark ? .dark : .light
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let listenerId = self.listenerId {
            ShillVpn.shared.removeListener(listenerId)
        }
    }

    public override var preferredStatusBarStyle: UIStatusBarStyle {
        return self.palette.isDark ? .lightContent : .darkContent
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = self.palette.background
        self.view.tintColor = self.palette.accent

        self.scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.alwaysBounceVertical = true
        self.scrollView.keyboardDismissMode = .interactive
        self.view.addSubview(self.scrollView)

        self.stack.axis = .vertical
        self.stack.alignment = .fill
        self.stack.spacing = 12.0
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.addSubview(self.stack)

        let content = self.scrollView.contentLayoutGuide
        let frame = self.scrollView.frameLayoutGuide
        let readable = self.view.readableContentGuide
        NSLayoutConstraint.activate([
            self.scrollView.topAnchor.constraint(equalTo: self.view.topAnchor),
            self.scrollView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            self.scrollView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.scrollView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.stack.topAnchor.constraint(equalTo: content.topAnchor, constant: self.mode == .firstScreen ? 32.0 : 24.0),
            self.stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24.0),
            self.stack.leadingAnchor.constraint(equalTo: readable.leadingAnchor, constant: 4.0),
            self.stack.trailingAnchor.constraint(equalTo: readable.trailingAnchor, constant: -4.0),
            self.stack.widthAnchor.constraint(lessThanOrEqualTo: frame.widthAnchor, constant: -32.0)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardFrameChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardFrameChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)

        self.listenerId = ShillVpn.shared.addListener { [weak self] in
            self?.stateChanged()
        }
        self.rebuild()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ShillVpn.debugLog("screen visible (\(self.mode == .firstScreen ? "first screen" : "settings"), \(self.subscribedLayout ? "subscribed" : "no subscription"))")
    }

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
            return
        }
        let keyboardFrame = self.view.convert(frameValue.cgRectValue, from: nil)
        let overlap = notification.name == UIResponder.keyboardWillHideNotification ? 0.0 : max(0.0, self.view.bounds.maxY - keyboardFrame.minY - self.view.safeAreaInsets.bottom)
        self.scrollView.contentInset.bottom = overlap
        self.scrollView.verticalScrollIndicatorInsets.bottom = overlap
        if overlap > 0.0, let field = self.linkField, field.isFirstResponder {
            let rect = field.convert(field.bounds, to: self.scrollView).insetBy(dx: 0.0, dy: -80.0)
            self.scrollView.scrollRectToVisible(rect, animated: true)
        }
    }

    // MARK: - State

    private func stateChanged() {
        let vpn = ShillVpn.shared
        if self.subscribedLayout != vpn.hasSubscription {
            if !self.linkBusy && !self.trialBusy {
                self.rebuild()
            }
            return
        }
        self.updateStatus()
        if let toggleButton = self.toggleButton {
            self.setTitle(toggleButton, vpn.isEnabled ? ShillVpn.tr("Turn off", "Выключить") : ShillVpn.tr("Turn on", "Включить"))
        }
        self.updateCloseTitle()
    }

    private func updateStatus() {
        let vpn = ShillVpn.shared
        self.statusLabel?.text = vpn.statusText()
        let color: UIColor
        switch vpn.state {
        case .on:
            color = vpn.accessEnded ? self.palette.warning : self.palette.success
        case .loading, .starting:
            color = self.palette.warning
        case .error:
            color = self.palette.destructive
        case .none, .off:
            color = self.palette.secondaryText
        }
        self.statusDot?.backgroundColor = color
        self.statusLabel?.textColor = vpn.state == .error ? self.palette.destructive : self.palette.secondaryText
    }

    private func updateCloseTitle() {
        guard let closeButton = self.closeButton else {
            return
        }
        if self.mode == .firstScreen {
            self.setTitle(closeButton, ShillVpn.tr("Continue", "Продолжить"))
        } else {
            self.setTitle(closeButton, ShillVpn.tr("Close", "Закрыть"))
        }
    }

    private func rebuild() {
        for view in self.stack.arrangedSubviews {
            self.stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        self.statusDot = nil
        self.statusLabel = nil
        self.errorLabel = nil
        self.trialButton = nil
        self.connectButton = nil
        self.toggleButton = nil
        self.closeButton = nil
        self.linkField = nil
        self.subscribedLayout = ShillVpn.shared.hasSubscription

        self.addHeader()
        if self.subscribedLayout {
            self.buildSubscribed()
        } else {
            self.buildNoSubscription()
        }
        self.updateStatus()
    }

    private func addHeader() {
        let title = UILabel()
        title.text = "SHILLVPN"
        title.font = UIFont.systemFont(ofSize: 34.0, weight: .bold)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = self.palette.primaryText
        title.accessibilityTraits = .header
        self.stack.addArrangedSubview(title)

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8.0
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = 4.0
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8.0),
            dot.heightAnchor.constraint(equalToConstant: 8.0)
        ])
        dot.isAccessibilityElement = false
        let status = self.makeLabel("", style: .subheadline, color: self.palette.secondaryText)
        row.addArrangedSubview(dot)
        row.addArrangedSubview(status)
        self.stack.addArrangedSubview(row)
        self.stack.setCustomSpacing(16.0, after: row)
        self.statusDot = dot
        self.statusLabel = status
    }

    private func buildNoSubscription() {
        let intro = self.makeLabel(ShillVpn.tr(
            "If Telegram does not open for you, connect SHILLVPN. One subscription works here, on your phone and on your computer, and Telegram in SHILLGRAM works right away.",
            "Если Telegram у вас не открывается, подключите SHILLVPN. Одна подписка работает здесь, на телефоне и на компьютере, а Telegram в SHILLGRAM заработает сразу."
        ), style: .body, color: self.palette.primaryText)
        self.stack.addArrangedSubview(self.card([intro]))

        let trial = self.makeButton(ShillVpn.tr("Get 3 days free", "Получить 3 дня бесплатно"), prominent: true, action: #selector(self.trialPressed))
        self.trialButton = trial
        self.stack.addArrangedSubview(trial)

        let termsText = ShillVpn.tr("One trial per device. By taking it you accept the terms.", "Одна проба на устройство. Получая её, вы принимаете условия.")
        let termsWord = ShillVpn.tr("terms", "условия")
        let terms = self.makeLabel("", style: .footnote, color: self.palette.secondaryText)
        let attributed = NSMutableAttributedString(string: termsText, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote),
            .foregroundColor: self.palette.secondaryText
        ])
        let range = (termsText as NSString).range(of: termsWord)
        if range.location != NSNotFound {
            attributed.addAttributes([.foregroundColor: self.palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        terms.attributedText = attributed
        terms.isUserInteractionEnabled = true
        terms.accessibilityTraits = .link
        terms.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.termsPressed)))
        self.stack.addArrangedSubview(terms)

        let buy = self.makeButton(ShillVpn.tr("Buy SHILLVPN", "Купить SHILLVPN"), prominent: false, action: #selector(self.buyPressed))
        self.stack.addArrangedSubview(buy)
        self.stack.setCustomSpacing(24.0, after: buy)

        let hint = self.makeLabel(ShillVpn.tr(
            "Already have a subscription? Paste its link from @SHILLVPN_bot or from the cabinet on shillvpn.site.",
            "Уже есть подписка? Вставьте ссылку из @SHILLVPN_bot или из личного кабинета на shillvpn.site."
        ), style: .footnote, color: self.palette.secondaryText)
        self.stack.addArrangedSubview(hint)

        let field = UITextField()
        field.placeholder = ShillVpn.tr("Subscription link", "Ссылка подписки")
        field.attributedPlaceholder = NSAttributedString(string: field.placeholder ?? "", attributes: [.foregroundColor: self.palette.secondaryText])
        field.font = UIFont.preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = self.palette.primaryText
        field.backgroundColor = self.palette.card
        field.layer.cornerRadius = 12.0
        field.keyboardType = .URL
        field.textContentType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.keyboardAppearance = self.palette.isDark ? .dark : .light
        field.leftView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 14.0, height: 1.0))
        field.leftViewMode = .always
        field.delegate = self
        field.accessibilityLabel = ShillVpn.tr("Subscription link", "Ссылка подписки")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 50.0).isActive = true
        self.linkField = field
        self.stack.addArrangedSubview(field)

        let error = self.makeLabel("", style: .footnote, color: self.palette.destructive)
        error.isHidden = true
        self.errorLabel = error
        self.stack.addArrangedSubview(error)

        let connect = self.makeButton(ShillVpn.tr("Connect", "Подключить"), prominent: true, action: #selector(self.connectPressed))
        self.connectButton = connect
        self.stack.addArrangedSubview(connect)

        let later = self.makeButton(ShillVpn.tr("Later", "Позже"), prominent: false, action: #selector(self.closePressed))
        self.stack.addArrangedSubview(later)
    }

    private func buildSubscribed() {
        let vpn = ShillVpn.shared
        var rows: [UIView] = []
        rows.append(self.makeRow(ShillVpn.tr("Renew subscription", "Продлить подписку"), action: #selector(self.renewPressed)))
        if !vpn.hasCabinet && vpn.hasTelegramAccount {
            // The bot's referral program belongs to the Telegram account
            // whose subscription this is; the app's own site cabinet has none.
            let invite = self.makeRow(ShillVpn.tr("Invite a friend: bonus days for both of you", "Пригласить друга: бонусные дни и вам, и ему"), action: #selector(self.invitePressed))
            rows.append(invite)
            vpn.loadShopInfo { [weak self, weak invite] info in
                guard let self = self, let invite = invite, let info = info, info.referralDays > 0 else {
                    return
                }
                self.setTitle(invite, String(format: ShillVpn.tr("Invite a friend: +%@ to their first payment, bonus days for you", "Пригласить друга: ему +%@ к первой оплате, вам бонусные дни"), ShillVpn.daysText(info.referralDays)))
            }
        }
        rows.append(self.makeRow(ShillVpn.tr("Connect a phone or another device", "Подключить телефон или другое устройство"), action: #selector(self.connectDevicePressed)))
        rows.append(self.makeRow(ShillVpn.tr("Update the server list", "Обновить список серверов"), action: #selector(self.updatePressed)))
        rows.append(self.makeRow(ShillVpn.tr("Use another link", "Сменить ссылку"), action: #selector(self.anotherLinkPressed)))
        self.stack.addArrangedSubview(self.card(rows, spacing: 0.0, insets: UIEdgeInsets(top: 4.0, left: 16.0, bottom: 4.0, right: 16.0)))

        let toggle = self.makeButton(vpn.isEnabled ? ShillVpn.tr("Turn off", "Выключить") : ShillVpn.tr("Turn on", "Включить"), prominent: false, action: #selector(self.togglePressed))
        self.toggleButton = toggle
        self.stack.addArrangedSubview(toggle)

        let close = self.makeButton("", prominent: true, action: #selector(self.closePressed))
        self.closeButton = close
        self.stack.addArrangedSubview(close)
        self.updateCloseTitle()
    }

    // MARK: - Actions

    @objc private func trialPressed() {
        guard let trialButton = self.trialButton, !self.trialBusy else {
            return
        }
        self.view.endEditing(true)
        self.showError(nil)
        self.trialBusy = true
        self.setLoading(trialButton, true)
        ShillVpn.shared.startTrial { [weak self] error in
            guard let self = self else {
                return
            }
            self.trialBusy = false
            if error.isEmpty {
                self.rebuild()
            } else {
                if let trialButton = self.trialButton {
                    self.setLoading(trialButton, false)
                }
                self.showError(error)
            }
        }
    }

    @objc private func connectPressed() {
        guard !self.linkBusy, let field = self.linkField else {
            return
        }
        let link = XrayConfig.javaTrim(field.text ?? "")
        if XrayConfig.tokenFromLink(link) == nil {
            self.shake(field)
            self.showError(ShillVpn.tr("This is not a SHILLVPN subscription link.", "Это не ссылка подписки SHILLVPN."))
            return
        }
        self.view.endEditing(true)
        self.linkBusy = true
        self.showError(nil)
        if let connectButton = self.connectButton {
            self.setLoading(connectButton, true)
        }
        ShillVpn.shared.setLink(link) { [weak self] error in
            guard let self = self else {
                return
            }
            self.linkBusy = false
            if error.isEmpty {
                self.rebuild()
            } else {
                if let connectButton = self.connectButton {
                    self.setLoading(connectButton, false)
                }
                if let field = self.linkField {
                    self.shake(field)
                }
                self.showError(error)
            }
        }
    }

    @objc private func termsPressed() {
        self.openUrl(ShillVpn.termsUrl)
    }

    @objc private func buyPressed() {
        self.openUrl(ShillVpn.siteUrl("/app/buy/", campaign: "buy", fragment: nil))
    }

    @objc private func renewPressed() {
        self.openUrl(ShillVpnScreen.renewUrl(campaign: "box"))
    }

    @objc private func invitePressed() {
        self.openUrl("https://t.me/" + ShillVpn.bot + "?start=invite")
    }

    @objc private func connectDevicePressed() {
        self.openUrl(ShillVpn.shared.connectPageUrl())
    }

    @objc private func updatePressed() {
        ShillVpn.shared.refresh()
    }

    @objc private func anotherLinkPressed() {
        ShillVpn.shared.forget()
        self.rebuild()
    }

    @objc private func togglePressed() {
        let vpn = ShillVpn.shared
        vpn.setEnabled(!vpn.isEnabled)
        self.stateChanged()
    }

    @objc private func closePressed() {
        self.view.endEditing(true)
        self.dismiss(animated: true)
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        self.connectPressed()
        return false
    }

    /// Renew: the SHILLVPN Mini App when logged in, the site cabinet
    /// otherwise. campaign: where the purchase started, for utm_campaign.
    public static func renewUrl(campaign: String) -> String {
        let vpn = ShillVpn.shared
        let source = campaign.isEmpty ? "renew" : campaign
        if vpn.hasCabinet {
            // The app's own trial is a site account, not the Telegram one.
            return vpn.cabinetUrl(campaign: source)
        } else if vpn.hasTelegramAccount {
            // The bot's Mini App right in the app: Stars, SBP, crypto.
            return "https://t.me/" + ShillVpn.bot + "?startapp"
        }
        return ShillVpn.siteUrl("/app/buy/", campaign: source, fragment: nil)
    }

    // MARK: - The renewal reminder

    public static func renewAlert(ended: Bool, left: Int64, info: ShillVpn.ShopInfo?, openUrl: @escaping (String) -> Void) -> UIAlertController {
        let ru = ShillVpn.shared.isRussian
        let hours = Int(max(1, (left + 3599) / 3600))
        var text: String
        if ended {
            text = ShillVpn.tr(
                "Your SHILLVPN access has ended. Telegram now connects directly and may not open on some networks. Renew to bring the protection back.",
                "Доступ к SHILLVPN закончился. Telegram подключается напрямую и в некоторых сетях может не открываться. Продлите, чтобы защита вернулась."
            )
        } else {
            text = String(format: ShillVpn.tr(
                "SHILLVPN access ends in %@. Renew so that Telegram in SHILLGRAM and VPN on your other devices keep working without a break.",
                "Доступ к SHILLVPN закончится через %@. Продлите, чтобы Telegram в SHILLGRAM и VPN на других устройствах работали без перерыва."
            ), ShillVpn.hoursText(hours))
        }
        if let info = info, !info.plans.isEmpty {
            // The longest plan first: the lowest price per month.
            let plans = info.plans.sorted(by: { $0.days > $1.days })
            let best = plans[0]
            let cheapest = plans[plans.count - 1]
            let perMonth = Int((Double(best.priceRub) * 30.0 / Double(best.days)).rounded())
            text += "\n\n"
            if best.days > 45 {
                text += String(format: ShillVpn.tr("%@ — %ld ₽, about %ld ₽ a month", "%@ — %ld ₽, это около %ld ₽ в месяц"), planTitle(best, ru: ru), best.priceRub, perMonth)
            } else {
                text += String(format: "%@ — %ld ₽", planTitle(best, ru: ru), best.priceRub)
            }
            if cheapest.days != best.days {
                text += "\n" + String(format: "%@ — %ld ₽", planTitle(cheapest, ru: ru), cheapest.priceRub)
            }
        }
        let alert = UIAlertController(title: "SHILLVPN", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ShillVpn.tr("Later", "Позже"), style: .cancel))
        alert.addAction(UIAlertAction(title: ShillVpn.tr("Renew", "Продлить"), style: .default, handler: { _ in
            openUrl(renewUrl(campaign: ended ? "ended" : "reminder"))
        }))
        return alert
    }

    private static func planTitle(_ plan: ShillVpn.Plan, ru: Bool) -> String {
        let months = max(1, Int((Double(plan.days) / 30.0).rounded()))
        if ru && !plan.title.isEmpty {
            return plan.title
        }
        return "\(months)" + (months == 1 ? " month" : " months")
    }

    // MARK: - Views

    private func makeLabel(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func card(_ views: [UIView], spacing: CGFloat = 8.0, insets: UIEdgeInsets = UIEdgeInsets(top: 14.0, left: 16.0, bottom: 14.0, right: 16.0)) -> UIView {
        let container = UIView()
        container.backgroundColor = self.palette.card
        container.layer.cornerRadius = 16.0
        container.layer.cornerCurve = .continuous
        let inner = UIStackView(arrangedSubviews: views)
        inner.axis = .vertical
        inner.spacing = spacing
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            inner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right)
        ])
        return container
    }

    /// A row of the subscription card: accent text, like Telegram's action cells.
    private func makeRow(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(self.palette.accent, for: .normal)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.contentHorizontalAlignment = .leading
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 46.0).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makeButton(_ title: String, prominent: Bool, action: Selector) -> UIButton {
        let button: UIButton
        if #available(iOS 15.0, *) {
            var configuration: UIButton.Configuration
            if #available(iOS 26.0, *) {
                configuration = prominent ? .prominentGlass() : .glass()
            } else {
                configuration = prominent ? .filled() : .gray()
                configuration.cornerStyle = .large
            }
            if prominent {
                configuration.baseBackgroundColor = self.palette.accent
                configuration.baseForegroundColor = self.palette.accentForeground
            } else {
                configuration.baseForegroundColor = self.palette.accent
            }
            configuration.title = title
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var updated = attributes
                updated.font = UIFont.preferredFont(forTextStyle: .headline)
                return updated
            }
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 14.0, leading: 16.0, bottom: 14.0, trailing: 16.0)
            button = UIButton(configuration: configuration)
            if prominent {
                button.tintColor = self.palette.accent
            }
        } else {
            button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
            button.layer.cornerRadius = 12.0
            if prominent {
                button.backgroundColor = self.palette.accent
                button.setTitleColor(self.palette.accentForeground, for: .normal)
            } else {
                button.backgroundColor = self.palette.card
                button.setTitleColor(self.palette.accent, for: .normal)
            }
        }
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50.0).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func setTitle(_ button: UIButton, _ title: String) {
        if #available(iOS 15.0, *), button.configuration != nil {
            button.configuration?.title = title
        } else {
            button.setTitle(title, for: .normal)
        }
        button.accessibilityLabel = title
    }

    private func setLoading(_ button: UIButton, _ loading: Bool) {
        button.isEnabled = !loading
        if #available(iOS 15.0, *), button.configuration != nil {
            button.configuration?.showsActivityIndicator = loading
        } else {
            button.alpha = loading ? 0.6 : 1.0
        }
    }

    private func showError(_ error: String?) {
        guard let errorLabel = self.errorLabel else {
            if let error = error, !error.isEmpty {
                // The subscribed layout has no error line: the status shows it.
                self.statusLabel?.text = error
            }
            return
        }
        if let error = error, !error.isEmpty {
            errorLabel.text = error
            errorLabel.isHidden = false
            UIAccessibility.post(notification: .announcement, argument: error)
        } else {
            errorLabel.text = nil
            errorLabel.isHidden = true
        }
    }

    private func shake(_ view: UIView) {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.duration = 0.4
        animation.values = [-8.0, 8.0, -6.0, 6.0, -3.0, 3.0, 0.0]
        view.layer.add(animation, forKey: "shake")
    }
}
