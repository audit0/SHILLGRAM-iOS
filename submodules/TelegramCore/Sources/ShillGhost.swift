import Foundation
import SwiftSignalKit

/// SHILLGRAM: ghost mode («Режим призрака»), the same switches as the desktop
/// client. App-wide (every account), kept in UserDefaults suite
/// "shillgram_ghost"; the settings screen writes the same keys through set().
///
/// Each check is effective only while the master switch is on:
/// - noRead: chats are read on this device only, the server is not told
///   (messages.readHistory, channels.readHistory, readDiscussion,
///   readSavedHistory, readMessageContents, view counters);
/// - noStories: stories are not marked as viewed;
/// - noOnline: the account always reports "offline";
/// - noTyping: no "typing", upload progress or emoji-interaction actions.
///
/// Reads go through UserDefaults (thread-safe, cached in memory), so the
/// checks are cheap enough for every network operation.
public enum ShillGhost {
    public enum Option: String, CaseIterable {
        case enabled
        case noRead
        case noStories
        case noOnline
        case noTyping
    }

    private static let defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "shillgram_ghost") ?? UserDefaults.standard
        defaults.register(defaults: [
            Option.enabled.rawValue: false,
            Option.noRead.rawValue: true,
            Option.noStories.rawValue: true,
            Option.noOnline.rawValue: true,
            Option.noTyping.rawValue: true
        ])
        return defaults
    }()

    private static let version = ValuePromise<Int32>(0, ignoreRepeated: false)
    private static let versionCounter = Atomic<Int32>(value: 0)

    /// The stored value of a switch (an option keeps its value while the master switch is off).
    public static func value(_ option: Option) -> Bool {
        return self.defaults.bool(forKey: option.rawValue)
    }

    public static func set(_ option: Option, _ value: Bool) {
        if self.value(option) == value {
            return
        }
        self.defaults.set(value, forKey: option.rawValue)
        let current = self.versionCounter.modify { $0 + 1 }
        self.version.set(current)
    }

    /// Fires now and after every change of any switch.
    public static var updates: Signal<Int32, NoError> {
        return self.version.get()
    }

    public static var isEnabled: Bool {
        return self.value(.enabled)
    }

    private static func effective(_ option: Option) -> Bool {
        return self.isEnabled && self.value(option)
    }

    public static var noRead: Bool {
        return self.effective(.noRead)
    }

    private static let readsHiddenKey = "readsHidden"

    /// Called when a read was kept from the server; remembered (also across launches) so that read-state
    /// checks keep a local state that is ahead of the server instead of retrying, even after ghost mode is off.
    public static func noteReadHidden() {
        if !self.defaults.bool(forKey: self.readsHiddenKey) {
            self.defaults.set(true, forKey: self.readsHiddenKey)
        }
    }

    /// Whether the server's read state may be behind this device's because of ghost mode.
    public static var serverMayLagReads: Bool {
        return self.noRead || self.defaults.bool(forKey: self.readsHiddenKey)
    }

    public static var noStories: Bool {
        return self.effective(.noStories)
    }

    public static var noOnline: Bool {
        return self.effective(.noOnline)
    }

    public static var noTyping: Bool {
        return self.effective(.noTyping)
    }
}

/// SHILLGRAM: ghost: in a request chain, replaces the (lazy, not yet started) read request with its
/// placeholder result while reads are hidden, so the local part of the operation still runs.
func shillGhostUnlessNoRead<T>(_ placeholder: T) -> (Signal<T, NoError>) -> Signal<T, NoError> {
    return { signal in
        if ShillGhost.noRead {
            return .single(placeholder)
        }
        return signal
    }
}
