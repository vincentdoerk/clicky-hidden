//
//  PermissionsManaging.swift
//  leanring-buddy
//
//  Protocol abstraction for system permission status management and polling.
//

import Foundation

protocol PermissionsManaging: AnyObject {
    var allPermissionsGranted: Bool { get }
    var hasAccessibilityPermission: Bool { get }
    var hasScreenRecordingPermission: Bool { get }
    var hasMicrophonePermission: Bool { get }
    var hasScreenContentPermission: Bool { get }

    func refreshPermissions()
    func startPolling(onChange: @escaping () -> Void)
    func stopPolling()
    func markScreenContentPermissionGranted()
}
