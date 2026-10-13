//
//  SettingsStoring.swift
//  leanring-buddy
//
//  Protocol abstraction for persistent key-value configuration storage.
//

import Foundation

protocol SettingsStoring: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func double(forKey key: String) -> Double
    func set(_ value: Double, forKey key: String)
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
}
