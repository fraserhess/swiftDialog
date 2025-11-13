//
//  InspectPersistence.swift
//  dialog
//
//  Created by Henry Stamerjohann, Declarative IT GmbH, 09/10/2025
//
//  Generic reusable persistence service for all Inspect presets
//  Non-blocking, type-safe, and flexible for different state structures
//

import Foundation

// MARK: - Protocol

/// Protocol that all persistable preset states must conform to
protocol InspectPersistableState: Codable {
    var timestamp: Date { get }
}

// MARK: - Generic Persistence Service

/// Generic persistence service for Inspect mode presets
/// - Non-blocking: Uses background queue for all I/O operations
/// - Type-safe: Enforces Codable conformance at compile time
/// - Flexible: Each preset defines its own state structure
///
/// Usage:
/// ```swift
/// struct MyPresetState: InspectPersistableState {
///     let completedItems: Set<String>
///     let currentIndex: Int
///     let timestamp: Date
/// }
///
/// let persistence = InspectPersistence<MyPresetState>(presetName: "preset3")
/// persistence.saveState(myState)
/// if let state = persistence.loadState() { ... }
/// ```
class InspectPersistence<T: InspectPersistableState> {

    // MARK: - Properties

    private let presetName: String
    private let stateFileName: String
    private let queue: DispatchQueue

    // MARK: - Initialization

    /// Initialize persistence for a specific preset
    /// - Parameter presetName: Unique preset identifier (e.g., "preset7", "preset3")
    init(presetName: String) {
        self.presetName = presetName
        self.stateFileName = "\(presetName)_state.plist"
        self.queue = DispatchQueue(label: "dialog.inspect.\(presetName).persistence", qos: .background)

        writeLog("InspectPersistence<\(T.self)>: Initialized for '\(presetName)'", logLevel: .debug)
    }

    // MARK: - File Location Strategy

    /// Smart file location strategy with fallback chain:
    /// 1. DIALOG_PERSIST_PATH environment variable (enterprise deployments)
    /// 2. Working directory .dialog subdirectory (portable/project-specific)
    /// 3. User's Application Support directory (standard macOS location)
    /// 4. Temp directory (last resort fallback)
    private var stateFileURL: URL? {
        // Option 1: Environment variable override
        if let customPath = ProcessInfo.processInfo.environment["DIALOG_PERSIST_PATH"] {
            let url = URL(fileURLWithPath: customPath).appendingPathComponent(stateFileName)
            writeLog("InspectPersistence: Using custom path from DIALOG_PERSIST_PATH: \(url.path)", logLevel: .debug)
            return url
        }

        // Option 2: Working directory .dialog subdirectory
        if let workingDir = ProcessInfo.processInfo.environment["PWD"] {
            let workingURL = URL(fileURLWithPath: workingDir)
            let dialogDir = workingURL.appendingPathComponent(".dialog", isDirectory: true)

            if ensureDirectoryExists(at: dialogDir) {
                let url = dialogDir.appendingPathComponent(stateFileName)
                writeLog("InspectPersistence: Using working directory: \(url.path)", logLevel: .debug)
                return url
            }
        }

        // Option 3: User's Application Support directory
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dialogDir = appSupport.appendingPathComponent("Dialog", isDirectory: true)

            if ensureDirectoryExists(at: dialogDir) {
                let url = dialogDir.appendingPathComponent(stateFileName)
                writeLog("InspectPersistence: Using Application Support: \(url.path)", logLevel: .debug)
                return url
            }
        }

        // Option 4: Temp directory as last resort
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dialog", isDirectory: true)
            .appendingPathComponent(stateFileName)
        writeLog("InspectPersistence: Using temp directory: \(tempURL.path)", logLevel: .info)
        return tempURL
    }

    /// Ensures directory exists and is writable
    private func ensureDirectoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false

        // Check if directory already exists
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }

        // Try to create directory
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)

            // Verify we can write to it with a test file
            let testFile = url.appendingPathComponent(".write_test")
            if FileManager.default.createFile(atPath: testFile.path, contents: nil, attributes: nil) {
                try? FileManager.default.removeItem(at: testFile)
                return true
            }
        } catch {
            writeLog("InspectPersistence: Cannot create/write to directory at \(url.path): \(error)", logLevel: .info)
        }

        return false
    }

    // MARK: - Save State (Non-blocking)

    /// Save state asynchronously on background queue
    /// - Parameter state: The state to persist
    func saveState(_ state: T) {
        queue.async { [weak self] in
            guard let self = self,
                  let url = self.stateFileURL else {
                writeLog("InspectPersistence: Cannot determine save location for \(self?.presetName ?? "unknown")", logLevel: .error)
                return
            }

            do {
                let encoder = PropertyListEncoder()
                let data = try encoder.encode(state)
                try data.write(to: url, options: .atomic)
                writeLog("InspectPersistence: State saved successfully to \(url.path)", logLevel: .debug)
            } catch {
                writeLog("InspectPersistence: Failed to save state - \(error.localizedDescription)", logLevel: .error)
            }
        }
    }

    // MARK: - Load State (Synchronous)

    /// Load persisted state synchronously
    /// - Returns: The loaded state, or nil if no state exists or loading fails
    func loadState() -> T? {
        guard let url = stateFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            writeLog("InspectPersistence: No persisted state found for \(presetName)", logLevel: .debug)
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = PropertyListDecoder()
            let state = try decoder.decode(T.self, from: data)

            writeLog("InspectPersistence: State loaded from \(state.timestamp)", logLevel: .info)
            return state
        } catch {
            writeLog("InspectPersistence: Failed to load state - \(error.localizedDescription)", logLevel: .error)

            // Remove corrupt file to prevent repeated errors
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    // MARK: - Clear State (Non-blocking)

    /// Clear persisted state asynchronously
    func clearState() {
        queue.async { [weak self] in
            guard let self = self,
                  let url = self.stateFileURL else { return }

            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    writeLog("InspectPersistence: State cleared for \(self.presetName)", logLevel: .info)
                }
            } catch {
                writeLog("InspectPersistence: Failed to clear state - \(error.localizedDescription)", logLevel: .error)
            }
        }
    }

    // MARK: - Utilities

    /// Check if state is stale (older than specified hours)
    /// - Parameters:
    ///   - state: The state to check
    ///   - hours: Number of hours to consider stale (default: 24)
    /// - Returns: True if state is older than specified hours
    func isStateStale(_ state: T, hours: Double = 24) -> Bool {
        let hoursSinceLastSave = Date().timeIntervalSince(state.timestamp) / 3600
        let isStale = hoursSinceLastSave > hours

        if isStale {
            writeLog("InspectPersistence: State is \(Int(hoursSinceLastSave)) hours old (stale)", logLevel: .info)
        }

        return isStale
    }

    /// Get the current persistence file path (for debugging)
    var persistenceFilePath: String? {
        return stateFileURL?.path
    }
}

// MARK: - Example State Structures

/// Example state structure for reference
/// Presets should define their own states conforming to InspectPersistableState
///
/// Example for Preset7:
/// ```swift
/// struct Preset7State: InspectPersistableState {
///     let completedSteps: Set<String>
///     let currentPage: Int
///     let currentStep: Int
///     let timestamp: Date
/// }
/// ```
///
/// Example for Preset3:
/// ```swift
/// struct Preset3State: InspectPersistableState {
///     let selectedItems: [String]
///     let downloadProgress: Double
///     let timestamp: Date
/// }
/// ```
