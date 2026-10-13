//
//  PermissionsManager.swift
//  leanring-buddy
//
//  Manages checking, polling, and status persistence for system permissions
//  (Accessibility, Screen Recording, Microphone, Screen Content).
//

import AVFoundation
import Foundation

final class PermissionsManager: PermissionsManaging {
    private(set) var hasAccessibilityPermission: Bool = false
    private(set) var hasScreenRecordingPermission: Bool = false
    private(set) var hasMicrophonePermission: Bool = false
    private(set) var hasScreenContentPermission: Bool = false

    var allPermissionsGranted: Bool {
        hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
    }

    private var pollingTimer: Timer?
    private var permissionChangeHandler: (() -> Void)?
    private let settingsStorage: SettingsStoring
    private let checkAccessibility: () -> Bool
    private let checkScreenRecording: () -> Bool
    private let checkMicrophone: () -> Bool
    private let pollingInterval: TimeInterval

    init(
        settingsStorage: SettingsStoring = UserDefaultsSettingsStorage(),
        pollingInterval: TimeInterval = 1.5,
        checkAccessibility: @escaping () -> Bool = { WindowPositionManager.hasAccessibilityPermission() },
        checkScreenRecording: @escaping () -> Bool = { WindowPositionManager.hasScreenRecordingPermission() },
        checkMicrophone: @escaping () -> Bool = {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    ) {
        self.settingsStorage = settingsStorage
        self.pollingInterval = pollingInterval
        self.checkAccessibility = checkAccessibility
        self.checkScreenRecording = checkScreenRecording
        self.checkMicrophone = checkMicrophone
        self.refreshPermissions()
    }

    func refreshPermissions() {
        let previousAccessibility = hasAccessibilityPermission
        let previousScreenRecording = hasScreenRecordingPermission
        let previousMicrophone = hasMicrophonePermission
        let previousScreenContent = hasScreenContentPermission

        hasAccessibilityPermission = checkAccessibility()
        hasScreenRecordingPermission = checkScreenRecording()
        hasMicrophonePermission = checkMicrophone()

        if !hasScreenContentPermission {
            hasScreenContentPermission = settingsStorage.bool(forKey: "hasScreenContentPermission")
        }

        let didChange = (previousAccessibility != hasAccessibilityPermission)
            || (previousScreenRecording != hasScreenRecordingPermission)
            || (previousMicrophone != hasMicrophonePermission)
            || (previousScreenContent != hasScreenContentPermission)

        if didChange {
            permissionChangeHandler?()
        }
    }

    func startPolling(onChange: @escaping () -> Void) {
        self.permissionChangeHandler = onChange
        stopPolling()

        refreshPermissions()

        let timer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.pollingTimer = timer
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    func markScreenContentPermissionGranted() {
        settingsStorage.set(true, forKey: "hasScreenContentPermission")
        hasScreenContentPermission = true
        permissionChangeHandler?()
    }

    deinit {
        stopPolling()
    }
}
