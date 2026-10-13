//
//  PermissionManagerTests.swift
//  leanring-buddyTests
//
//  Unit tests for PermissionsManager.
//

import Testing
@testable import leanring_buddy

struct PermissionManagerTests {
    @Test func permissionsManagerReportsAllGrantedWhenAllCheckersReturnTrue() throws {
        let mockStorage = MockSettingsStorage()
        mockStorage.set(true, forKey: "hasScreenContentPermission")

        let manager = PermissionsManager(
            settingsStorage: mockStorage,
            pollingInterval: 10.0,
            checkAccessibility: { true },
            checkScreenRecording: { true },
            checkMicrophone: { true }
        )

        manager.refreshPermissions()

        #expect(manager.hasAccessibilityPermission)
        #expect(manager.hasScreenRecordingPermission)
        #expect(manager.hasMicrophonePermission)
        #expect(manager.hasScreenContentPermission)
        #expect(manager.allPermissionsGranted)
    }

    @Test func permissionsManagerReportsFalseWhenAnyPermissionMissing() throws {
        let mockStorage = MockSettingsStorage()
        mockStorage.set(true, forKey: "hasScreenContentPermission")

        let manager = PermissionsManager(
            settingsStorage: mockStorage,
            pollingInterval: 10.0,
            checkAccessibility: { false },
            checkScreenRecording: { true },
            checkMicrophone: { true }
        )

        #expect(!manager.hasAccessibilityPermission)
        #expect(!manager.allPermissionsGranted)
    }

    @Test func permissionsManagerRefreshDetectsChangesAndTriggersHandler() throws {
        let mockStorage = MockSettingsStorage()
        mockStorage.set(true, forKey: "hasScreenContentPermission")

        var isAccessibilityGranted = false
        var changeHandlerTriggerCount = 0

        let manager = PermissionsManager(
            settingsStorage: mockStorage,
            pollingInterval: 10.0,
            checkAccessibility: { isAccessibilityGranted },
            checkScreenRecording: { true },
            checkMicrophone: { true }
        )

        manager.startPolling {
            changeHandlerTriggerCount += 1
        }

        #expect(!manager.hasAccessibilityPermission)

        // Simulate user granting accessibility permission in System Settings
        isAccessibilityGranted = true
        manager.refreshPermissions()

        #expect(manager.hasAccessibilityPermission)
        #expect(changeHandlerTriggerCount > 0)

        manager.stopPolling()
    }

    @Test func permissionsManagerMarkScreenContentPermissionGrantedUpdatesState() throws {
        let mockStorage = MockSettingsStorage()

        let manager = PermissionsManager(
            settingsStorage: mockStorage,
            pollingInterval: 10.0,
            checkAccessibility: { true },
            checkScreenRecording: { true },
            checkMicrophone: { true }
        )

        #expect(!manager.hasScreenContentPermission)

        manager.markScreenContentPermissionGranted()

        #expect(manager.hasScreenContentPermission)
        #expect(mockStorage.bool(forKey: "hasScreenContentPermission"))
        #expect(manager.allPermissionsGranted)
    }
}
