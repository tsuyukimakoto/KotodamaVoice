import Foundation
import KotodamaCore

@MainActor
final class UserDefaultsHotKeyPreference: HotKeyPreferencePersisting {
    private enum Key {
        static let keyCode = "hotKey.keyCode"
        static let modifiers = "hotKey.modifiers"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> HotKeyDescriptor? {
        guard defaults.object(forKey: Key.keyCode) != nil,
              defaults.object(forKey: Key.modifiers) != nil
        else {
            return nil
        }
        return HotKeyDescriptor(
            keyCode: UInt32(defaults.integer(forKey: Key.keyCode)),
            modifiers: UInt32(defaults.integer(forKey: Key.modifiers))
        )
    }

    func save(_ descriptor: HotKeyDescriptor) {
        defaults.set(Int(descriptor.keyCode), forKey: Key.keyCode)
        defaults.set(Int(descriptor.modifiers), forKey: Key.modifiers)
    }
}
