//
//  OrukeetServerManager.swift
//  leanring-buddy
//
//  Manages the lifecycle of the local sherpa-onnx Orukeet WebSocket server.
//

import Foundation
import AppKit

final class OrukeetServerManager: @unchecked Sendable {
    static let shared = OrukeetServerManager()
    let port: Int = 6006

    private var executionProcess: Process?
    private var ownsProcess = false
    private let stateQueue = DispatchQueue(label: "com.learningbuddy.orukeet.server")

    /// Resolved executable path for sherpa-onnx-ws.
    static var binaryPath: String? {
        let candidates = [
            "/Applications/OpenWhispr.app/Contents/Resources/bin/sherpa-onnx-ws-darwin-arm64",
            "/opt/homebrew/bin/sherpa-onnx-ws",
            "/usr/local/bin/sherpa-onnx-ws"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Directory containing Orukeet ONNX models.
    static var modelDirectoryURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".cache/openwhispr/parakeet-models/orukeet-v0.1.0"),
            home.appendingPathComponent("Library/Application Support/Clicky/models/orukeet")
        ]
        return candidates.first { dir in
            let requiredFiles = ["tokens.txt", "encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx"]
            return requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
    }

    var isConfigured: Bool {
        return Self.binaryPath != nil && Self.modelDirectoryURL != nil
    }

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        terminateServer()
    }

    @objc private func applicationWillTerminate() {
        terminateServer()
    }

    /// Checks if a WebSocket server is already listening on port 6006.
    func checkServerHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        request.httpMethod = "GET"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                // 426 Upgrade Required is returned by WebSocket servers when queried via HTTP
                return httpResponse.statusCode == 426 || (200...299).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    /// Ensures the server is active, starting it if not already running.
    @discardableResult
    func ensureServerRunning() async -> Bool {
        if await checkServerHealth() {
            return true
        }

        guard let binary = Self.binaryPath, let modelDir = Self.modelDirectoryURL else {
            return false
        }

        let launched = stateQueue.sync { () -> Bool in
            if let proc = executionProcess, proc.isRunning {
                return true
            }
            executionProcess = nil
            ownsProcess = false

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [
                "--tokens=\(modelDir.appendingPathComponent("tokens.txt").path)",
                "--encoder=\(modelDir.appendingPathComponent("encoder.int8.onnx").path)",
                "--decoder=\(modelDir.appendingPathComponent("decoder.int8.onnx").path)",
                "--joiner=\(modelDir.appendingPathComponent("joiner.int8.onnx").path)",
                "--model-type=nemo_transducer",
                "--port=\(port)",
                "--num-threads=4",
                "--num-work-threads=3"
            ]

            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                self.executionProcess = process
                self.ownsProcess = true
                print("🎙️ Orukeet: Spawning server on port \(port)...")
                return true
            } catch {
                print("❌ Orukeet: Failed to spawn server: \(error)")
                return false
            }
        }

        guard launched else { return false }

        // Poll server readiness asynchronously up to 3 seconds
        let maxAttempts = 30
        for _ in 0..<maxAttempts {
            if await checkServerHealth() {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func terminateServer() {
        stateQueue.sync {
            if ownsProcess, let proc = executionProcess, proc.isRunning {
                print("🛑 Orukeet: Terminating spawned server...")
                proc.terminate()
            }
            executionProcess = nil
            ownsProcess = false
        }
    }
}
