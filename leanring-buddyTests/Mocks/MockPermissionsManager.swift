//
//  MockPermissionsManager.swift
//  leanring-buddyTests
//
//  Mock implementation of PermissionsManaging for unit testing.
//

import Foundation
@testable import leanring_buddy

final class MockPermissionsManager: PermissionsManaging {
    var allPermissionsGranted: Bool = true
    var hasAccessibilityPermission: Bool = true
    var hasScreenRecordingPermission: Bool = true
    var hasMicrophonePermission: Bool = true
    var hasScreenContentPermission: Bool = true

    var refreshPermissionsCallCount: Int = 0
    var isPolling: Bool = false
    var pollingChangeHandler: (() -> Void)? = nil

    func refreshPermissions() {
        refreshPermissionsCallCount += 1
    }

    func startPolling(onChange: @escaping () -> Void) {
        isPolling = true
        pollingChangeHandler = onChange
    }

    func stopPolling() {
        isPolling = false
        pollingChangeHandler = nil
    }

    func simulatePermissionChange() {
        pollingChangeHandler?()
    }
}
