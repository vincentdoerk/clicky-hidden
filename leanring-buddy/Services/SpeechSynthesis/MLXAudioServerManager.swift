//
//  MLXAudioServerManager.swift
//  leanring-buddy
//
//  Manages the lifecycle of the local mlx_audio.server process on Apple Silicon.
//  If a server is already running on the configured port, Clicky connects to it.
//  If no server is running, Clicky launches mlx_audio.server as a child process
//  and terminates it cleanly when Clicky exits, ensuring background resources
//  are released automatically.
//

import AppKit
import Foundation

@MainActor
final class MLXAudioServerManager {
    static let shared = MLXAudioServerManager()

    /// Default port used for local MLX Audio TTS server.
    private static let defaultLocalServerPort: Int = 8765

    /// Candidate file system paths where Python interpreters for mlx_audio.server are located.
    private static var candidatePythonExecutablePaths: [String] {
        let userHomeDirectory = FileManager.default.homeDirectoryForCurrentUser
        return [
            userHomeDirectory.appendingPathComponent(".local/share/uv/tools/mlx-audio/bin/python").path,
            userHomeDirectory.appendingPathComponent(".local/bin/python3").path,
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3"
        ]
    }

    /// Candidate file system paths where mlx_audio.server is typically installed.
    private static var candidateServerScriptPaths: [String] {
        let userHomeDirectory = FileManager.default.homeDirectoryForCurrentUser
        return [
            userHomeDirectory.appendingPathComponent(".local/share/uv/tools/mlx-audio/bin/mlx_audio.server").path,
            userHomeDirectory.appendingPathComponent(".local/bin/mlx_audio.server").path,
            "/opt/homebrew/bin/mlx_audio.server",
            "/usr/local/bin/mlx_audio.server"
        ]
    }

    /// Resolved path to the Python interpreter if available.
    static var resolvedPythonExecutablePath: String? {
        return candidatePythonExecutablePaths.first { candidatePath in
            FileManager.default.isExecutableFile(atPath: candidatePath)
        }
    }

    /// Resolved path to the mlx_audio.server executable or script if installed.
    static var resolvedServerScriptPath: String? {
        return candidateServerScriptPaths.first { candidatePath in
            FileManager.default.fileExists(atPath: candidatePath)
        }
    }

    /// Resolved path to the mlx_audio.server executable if installed.
    static var resolvedExecutablePath: String? {
        return candidateServerScriptPaths.first { candidatePath in
            FileManager.default.isExecutableFile(atPath: candidatePath)
        }
    }

    /// The port on which mlx_audio.server runs.
    let serverPort: Int

    /// Base URL for contacting the local server.
    let serverBaseURL: URL

    /// The child process spawned by Clicky, if any.
    private var managedServerProcess: Process?

    /// Active pipe for standard output logging.
    private var managedStandardOutputPipe: Pipe?

    /// Active pipe for standard error logging.
    private var managedStandardErrorPipe: Pipe?

    /// True only if Clicky started this server process itself (so we only terminate what we own).
    private var didStartServerProcessByApp: Bool = false

    /// Background task monitoring launch readiness, if startup is in progress.
    private var serverStartupTask: Task<Bool, Never>?

    init() {
        let configuredPortString = AppBundleConfiguration.stringValue(forKey: "LocalTTSServerPort")
        let resolvedPort = configuredPortString.flatMap(Int.init) ?? Self.defaultLocalServerPort
        self.serverPort = resolvedPort

        let configuredBaseURLString = AppBundleConfiguration.stringValue(forKey: "LocalTTSServerBaseURL")
            ?? "http://127.0.0.1:\(resolvedPort)"
        self.serverBaseURL = URL(string: configuredBaseURLString) ?? URL(string: "http://127.0.0.1:\(resolvedPort)")!

        // Register for application termination notification to ensure child process cleanup
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.shutdownManagedServerProcess()
        }
    }

    /// Checks if the local MLX Audio server is reachable and answering HTTP requests.
    func isServerReachable() async -> Bool {
        let modelsEndpointURL = serverBaseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: modelsEndpointURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5

        do {
            let (_, urlResponse) = try await URLSession.shared.data(for: request)
            if let httpResponse = urlResponse as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                return true
            }
        } catch {
            // Connection failed or timed out
        }
        return false
    }

    /// Ensures that an MLX Audio server is up and answering.
    /// If none is answering and an executable exists, launches a child process and waits for it.
    @discardableResult
    func ensureServerIsRunning() async -> Bool {
        if await isServerReachable() {
            return true
        }

        if let existingStartupTask = serverStartupTask {
            return await existingStartupTask.value
        }

        let newStartupTask = Task<Bool, Never> { [weak self] () -> Bool in
            guard let self = self else { return false }

            let executableURL: URL
            let launchArguments: [String]

            let serverLogDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("mlx_audio_logs")
            try? FileManager.default.createDirectory(at: serverLogDirectoryURL, withIntermediateDirectories: true)
            let serverLogDirectoryPath = serverLogDirectoryURL.path

            if let pythonPath = Self.resolvedPythonExecutablePath,
               let scriptPath = Self.resolvedServerScriptPath {
                executableURL = URL(fileURLWithPath: pythonPath)
                launchArguments = [
                    scriptPath,
                    "--host", "127.0.0.1",
                    "--port", String(self.serverPort),
                    "--log-dir", serverLogDirectoryPath
                ]
            } else if let executablePath = Self.resolvedExecutablePath {
                executableURL = URL(fileURLWithPath: executablePath)
                launchArguments = [
                    "--host", "127.0.0.1",
                    "--port", String(self.serverPort),
                    "--log-dir", serverLogDirectoryPath
                ]
            } else {
                print("⚠️ MLX Audio: neither Python interpreter nor mlx_audio.server script found in candidate paths: \(Self.candidateServerScriptPaths)")
                return false
            }

            print("🔊 MLX Audio: launching server via \(executableURL.path) on port \(self.serverPort)...")

            let newProcess = Process()
            newProcess.executableURL = executableURL
            newProcess.currentDirectoryURL = serverLogDirectoryURL
            newProcess.arguments = launchArguments

            // Inherit current environment so Python can locate uv packages and libraries
            var processEnvironment = ProcessInfo.processInfo.environment
            let homePath = FileManager.default.homeDirectoryForCurrentUser.path
            let extraPaths = [
                "\(homePath)/.local/share/uv/tools/mlx-audio/bin",
                "\(homePath)/.local/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin"
            ]
            let currentPath = processEnvironment["PATH"] ?? ""
            processEnvironment["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")

            // Disable Xcode Metal Debug validation layers for the MLX Python child process.
            // When Clicky runs from Xcode in Debug mode, Xcode injects MTL_DEBUG_LAYER=1 into
            // inherited process environments. In MLX, Metal validation asserts on internal nil byte
            // buffers in MTLDebugComputeCommandEncoder and terminates the process with SIGABRT.
            processEnvironment.removeValue(forKey: "MTL_DEBUG_LAYER")
            processEnvironment.removeValue(forKey: "METAL_DEVICE_WRAPPER_TYPE")
            processEnvironment.removeValue(forKey: "METAL_DEBUG_ERROR_LEVEL")
            processEnvironment["MTL_DEBUG_LAYER"] = "0"
            processEnvironment["METAL_DEVICE_WRAPPER_TYPE"] = "0"
            processEnvironment["METAL_DEBUG_ERROR_LEVEL"] = "0"

            newProcess.environment = processEnvironment

            // Create and attach pipes with readability handlers to stream logs and prevent buffer deadlocks
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            newProcess.standardOutput = outputPipe
            newProcess.standardError = errorPipe
            self.managedStandardOutputPipe = outputPipe
            self.managedStandardErrorPipe = errorPipe

            outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                let availableData = fileHandle.availableData
                guard !availableData.isEmpty,
                      let logString = String(data: availableData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !logString.isEmpty else { return }
                for logLine in logString.components(separatedBy: .newlines) where !logLine.isEmpty {
                    print("🔊 MLX Audio [stdout]: \(logLine)")
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                let availableData = fileHandle.availableData
                guard !availableData.isEmpty,
                      let logString = String(data: availableData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !logString.isEmpty else { return }
                for logLine in logString.components(separatedBy: .newlines) where !logLine.isEmpty {
                    print("🔊 MLX Audio [stderr]: \(logLine)")
                }
            }

            do {
                try newProcess.run()
                self.managedServerProcess = newProcess
                self.didStartServerProcessByApp = true
                print("🔊 MLX Audio: spawned server process with PID \(newProcess.processIdentifier)")
            } catch {
                print("⚠️ MLX Audio: failed to launch server process: \(error)")
                self.clearPipes()
                return false
            }

            // Poll for server health check up to 15 seconds (in 250ms increments)
            let maximumPollingAttempts = 60
            for attemptIndex in 0..<maximumPollingAttempts {
                if await self.isServerReachable() {
                    print("🔊 MLX Audio: server is healthy and responsive (ready after attempt \(attemptIndex + 1))")
                    return true
                }

                // If process exited prematurely, abort polling
                if !(self.managedServerProcess?.isRunning ?? false) {
                    print("⚠️ MLX Audio: server process terminated unexpectedly with termination status \(self.managedServerProcess?.terminationStatus ?? -1)")
                    self.clearPipes()
                    self.managedServerProcess = nil
                    self.didStartServerProcessByApp = false
                    return false
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            print("⚠️ MLX Audio: server launch timed out after 15 seconds")
            self.shutdownManagedServerProcess()
            return false
        }

        self.serverStartupTask = newStartupTask
        let result = await newStartupTask.value
        self.serverStartupTask = nil
        return result
    }

    /// Cleans up active pipe readability handlers to avoid resource leaks.
    private func clearPipes() {
        managedStandardOutputPipe?.fileHandleForReading.readabilityHandler = nil
        managedStandardErrorPipe?.fileHandleForReading.readabilityHandler = nil
        managedStandardOutputPipe = nil
        managedStandardErrorPipe = nil
    }

    /// Terminates the server process if Clicky started it.
    func shutdownManagedServerProcess() {
        guard didStartServerProcessByApp, let processToTerminate = managedServerProcess else {
            return
        }

        clearPipes()

        if processToTerminate.isRunning {
            print("🔊 MLX Audio: terminating app-managed server process (PID \(processToTerminate.processIdentifier))...")
            processToTerminate.terminate()
        }

        managedServerProcess = nil
        didStartServerProcessByApp = false
    }
}
