//
//  MockSettingsStorage.swift
//  leanring-buddyTests
//
//  In-memory dictionary-backed implementation of SettingsStoring for unit testing.
//

import Foundation
@testable import leanring_buddy

final class MockSettingsStorage: SettingsStoring {
    private var storageDictionary: [String: Any] = [:]

    func string(forKey key: String) -> String? {
        storageDictionary[key] as? String
    }

    func set(_ value: String?, forKey key: String) {
        if let value {
            storageDictionary[key] = value
        } else {
            storageDictionary.removeValue(forKey: key)
        }
    }

    func double(forKey key: String) -> Double {
        storageDictionary[key] as? Double ?? 0.0
    }

    func set(_ value: Double, forKey key: String) {
        storageDictionary[key] = value
    }

    func bool(forKey key: String) -> Bool {
        storageDictionary[key] as? Bool ?? false
    }

    func set(_ value: Bool, forKey key: String) {
        storageDictionary[key] = value
    }

    func reset() {
        storageDictionary.removeAll()
    }

    func hasValue(forKey key: String) -> Bool {
        storageDictionary[key] != nil
    }
}
