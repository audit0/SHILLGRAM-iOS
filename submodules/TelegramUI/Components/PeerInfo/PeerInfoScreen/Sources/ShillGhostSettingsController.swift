/*
 * SHILLGRAM: ghost mode («Режим призрака») — the settings screen.
 *
 * The same switches as the desktop client: the master switch and four
 * options (each on by default). App-wide, for every account; the values
 * live in TelegramCore's ShillGhost (UserDefaults suite "shillgram_ghost"),
 * which the network code reads. Russian when the app language is Russian,
 * English otherwise (as SHILLVPN).
 */
import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import ShillVpn

private final class ShillGhostSettingsArguments {
    let update: (ShillGhost.Option, Bool) -> Void

    init(update: @escaping (ShillGhost.Option, Bool) -> Void) {
        self.update = update
    }
}

private enum ShillGhostSettingsSection: Int32 {
    case master
    case options
}

private enum ShillGhostSettingsEntry: ItemListNodeEntry {
    case master(Bool)
    case masterFooter
    case optionsHeader
    case option(index: Int32, option: ShillGhost.Option, title: String, value: Bool, enabled: Bool)
    case optionsFooter

    var section: ItemListSectionId {
        switch self {
        case .master, .masterFooter:
            return ShillGhostSettingsSection.master.rawValue
        case .optionsHeader, .option, .optionsFooter:
            return ShillGhostSettingsSection.options.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .master:
            return 0
        case .masterFooter:
            return 1
        case .optionsHeader:
            return 2
        case let .option(index, _, _, _, _):
            return 3 + index
        case .optionsFooter:
            return 100
        }
    }

    static func ==(lhs: ShillGhostSettingsEntry, rhs: ShillGhostSettingsEntry) -> Bool {
        switch lhs {
        case let .master(value):
            if case .master(value) = rhs {
                return true
            }
            return false
        case .masterFooter:
            if case .masterFooter = rhs {
                return true
            }
            return false
        case .optionsHeader:
            if case .optionsHeader = rhs {
                return true
            }
            return false
        case let .option(index, option, title, value, enabled):
            if case .option(index, option, title, value, enabled) = rhs {
                return true
            }
            return false
        case .optionsFooter:
            if case .optionsFooter = rhs {
                return true
            }
            return false
        }
    }

    static func <(lhs: ShillGhostSettingsEntry, rhs: ShillGhostSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ShillGhostSettingsArguments
        switch self {
        case let .master(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: ShillVpn.tr("Ghost mode", "Режим призрака"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.update(.enabled, value)
            })
        case .masterFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(ShillVpn.tr("For every account in this app.", "Для всех аккаунтов в этом приложении.")), sectionId: self.section)
        case .optionsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: ShillVpn.tr("WHAT TO HIDE", "ЧТО СКРЫВАТЬ"), sectionId: self.section)
        case let .option(_, option, title, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.update(option, value)
            })
        case .optionsFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(ShillVpn.tr("Chats are read on this device only. Sending a message briefly shows you online — that is how Telegram works.", "Чаты будут прочитаны только на этом устройстве. Отправка сообщения ненадолго показывает вас в сети — так работает Telegram.")), sectionId: self.section)
        }
    }
}

private func shillGhostSettingsEntries() -> [ShillGhostSettingsEntry] {
    let isEnabled = ShillGhost.isEnabled
    var entries: [ShillGhostSettingsEntry] = []
    entries.append(.master(isEnabled))
    entries.append(.masterFooter)
    entries.append(.optionsHeader)
    let options: [(ShillGhost.Option, String)] = [
        (.noRead, ShillVpn.tr("Don't send read receipts", "Не отправлять «прочитано»")),
        (.noStories, ShillVpn.tr("Don't mark stories as viewed", "Не отмечать просмотр историй")),
        (.noOnline, ShillVpn.tr("Don't show «online»", "Не показывать «в сети»")),
        (.noTyping, ShillVpn.tr("Don't show «typing»", "Не показывать «печатает»"))
    ]
    for (index, (option, title)) in options.enumerated() {
        entries.append(.option(index: Int32(index), option: option, title: title, value: ShillGhost.value(option), enabled: isEnabled))
    }
    entries.append(.optionsFooter)
    return entries
}

func shillGhostSettingsController(context: AccountContext) -> ViewController {
    let arguments = ShillGhostSettingsArguments(update: { option, value in
        ShillGhost.set(option, value)
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        ShillGhost.updates
    )
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(ShillVpn.tr("Ghost mode", "Режим призрака")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: shillGhostSettingsEntries(), style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal)
}
