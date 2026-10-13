//
//  UserDefaultsSettingsStorage.swift
//  leanring-buddy
//
//  UserDefaults backed implementation of SettingsStoring.
//

import Foundation

final class UserDefaultsSettingsStorage: SettingsStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func set(_ value: String?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func double(forKey key: String) -> Double {
        defaults.double(forKey: key)
    }

    func set(_ value: Double, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
