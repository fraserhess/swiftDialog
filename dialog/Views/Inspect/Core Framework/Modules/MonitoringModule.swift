//
//  MonitoringModule.swift
//  dialog
//
//  Created by Henry Stamerjohann, Declarative IT GmbH, 22/01/2026
//
//  Unified monitoring module for Inspect presets
//
//  This module provides a clean interface for monitoring:
//  - Plist file changes with validation
//  - JSON file monitoring
//  - Log file monitoring (via LogMonitorService)
//  - Installation status tracking
//
//  Builds on existing services: LogMonitorService, FileMonitor, Monitoring
//  Used by: Preset6, Preset11 (and future presets)
//

import Foundation
import SwiftUI
import Combine

// MARK: - Item Status Enum

/// Unified status for monitoring items
enum MonitoringItemStatus: Equatable {
    case pending
    case downloading(progress: Double?)
    case installing(progress: Double?, message: String?)
    case completed
    case failed(reason: String?)

    /// Simple status for basic comparisons
    var simpleStatus: String {
        switch self {
        case .pending: return "pending"
        case .downloading: return "downloading"
        case .installing: return "installing"
        case .completed: return "completed"
        case .failed: return "failed"
        }
    }

    /// Whether this status indicates an active operation
    var isActive: Bool {
        switch self {
        case .downloading, .installing: return true
        default: return false
        }
    }

    /// Whether this status indicates completion (success or failure)
    var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }
}

// MARK: - Validation Result

/// Result of validating an item against expected values
struct MonitoringValidationResult: Equatable {
    let isValid: Bool
    let actualValue: String?
    let expectedValue: String?
    let evaluationType: String?
    let message: String?

    init(
        isValid: Bool,
        actualValue: String? = nil,
        expectedValue: String? = nil,
        evaluationType: String? = nil,
        message: String? = nil
    ) {
        self.isValid = isValid
        self.actualValue = actualValue
        self.expectedValue = expectedValue
        self.evaluationType = evaluationType
        self.message = message
    }

    static let unknown = MonitoringValidationResult(isValid: false, message: "Not validated")
}

// MARK: - Monitoring Service Protocol

/// Protocol for monitoring services to implement
protocol MonitoringServiceProtocol: ObservableObject {
    var itemStatuses: [String: MonitoringItemStatus] { get }
    var validationResults: [String: MonitoringValidationResult] { get }

    func startMonitoring(items: [InspectConfig.ItemConfig])
    func stopMonitoring()
    func validateItem(_ item: InspectConfig.ItemConfig) -> MonitoringValidationResult
    func forceStatusCheck()
}

// MARK: - Unified Monitoring Service

/// Unified monitoring service that coordinates multiple monitoring sources
///
/// This service provides a single point of contact for all monitoring needs:
/// - File/App installation detection
/// - Plist monitoring and validation
/// - Log monitoring integration
/// - Status aggregation
///
/// ## Usage Example
/// ```swift
/// @StateObject private var monitoringService = UnifiedMonitoringService()
///
/// var body: some View {
///     ForEach(items) { item in
///         ItemRow(
///             item: item,
///             status: monitoringService.itemStatuses[item.id] ?? .pending
///         )
///     }
///     .onAppear {
///         monitoringService.startMonitoring(items: items)
///     }
/// }
/// ```
class UnifiedMonitoringService: ObservableObject {

    // MARK: - Published Properties

    @Published public private(set) var itemStatuses: [String: MonitoringItemStatus] = [:]
    @Published public private(set) var validationResults: [String: MonitoringValidationResult] = [:]
    @Published public private(set) var progressValues: [String: Double] = [:]
    @Published public private(set) var statusMessages: [String: String] = [:]

    // MARK: - Private Properties

    private var items: [InspectConfig.ItemConfig] = []
    private var plistMonitorTasks: [String: PlistMonitorTask] = [:]
    private var jsonMonitorTasks: [String: JsonMonitorTask] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let fileSystemCache = FileSystemCache()
    private var statusCheckTimer: Timer?
    private var cachePaths: [String] = []

    // MARK: - Plist Monitor Task

    private struct PlistMonitorTask {
        let timer: Timer
        let itemId: String
        let plistPath: String
        let plistKey: String
        let expectedValue: String?
        let evaluation: String?
        var lastValue: String?
    }

    // MARK: - JSON Monitor Task

    private struct JsonMonitorTask {
        let timer: Timer
        let itemId: String
        let jsonPath: String
        let jsonKey: String
        let expectedValue: String?
        var lastValue: String?
    }

    // MARK: - Initialization

    init() {
        // Subscribe to LogMonitorService status updates
        LogMonitorService.shared.$latestStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                self?.handleLogMonitorStatuses(statuses)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Start monitoring the given items
    /// - Parameters:
    ///   - items: Items to monitor
    ///   - cachePaths: Optional cache paths for download detection
    func startMonitoring(items: [InspectConfig.ItemConfig], cachePaths: [String] = []) {
        self.items = items
        self.cachePaths = cachePaths

        writeLog("UnifiedMonitoringService: Starting monitoring for \(items.count) items", logLevel: .info)

        // Initialize all items as pending
        for item in items {
            if itemStatuses[item.id] == nil {
                itemStatuses[item.id] = .pending
            }
        }

        // Set items for LogMonitorService
        LogMonitorService.shared.setItems(items)

        // Start plist monitoring for items with plist config
        for item in items {
            startPlistMonitoringIfNeeded(for: item)
            startJsonMonitoringIfNeeded(for: item)
        }

        // Start periodic status check timer
        startStatusCheckTimer()

        // Initial status check
        performStatusCheck()
    }

    /// Stop all monitoring
    func stopMonitoring() {
        writeLog("UnifiedMonitoringService: Stopping all monitoring", logLevel: .info)

        // Stop status check timer
        statusCheckTimer?.invalidate()
        statusCheckTimer = nil

        // Stop all plist monitors
        for (_, task) in plistMonitorTasks {
            task.timer.invalidate()
        }
        plistMonitorTasks.removeAll()

        // Stop all JSON monitors
        for (_, task) in jsonMonitorTasks {
            task.timer.invalidate()
        }
        jsonMonitorTasks.removeAll()

        // Cancel subscriptions
        cancellables.removeAll()
    }

    /// Force an immediate status check
    func forceStatusCheck() {
        performStatusCheck()
    }

    /// Validate a specific item
    func validateItem(_ item: InspectConfig.ItemConfig) -> MonitoringValidationResult {
        guard let plistKey = item.plistKey else {
            return .unknown
        }

        // Find plist path from item paths
        let plistPath = item.paths.first { $0.hasSuffix(".plist") } ?? item.paths.first ?? ""
        guard !plistPath.isEmpty else {
            return MonitoringValidationResult(isValid: false, message: "No plist path configured")
        }

        return validatePlistValue(
            at: plistPath,
            key: plistKey,
            expectedValue: item.expectedValue,
            evaluation: item.evaluation
        )
    }

    /// Mark an item as completed (external trigger)
    func markCompleted(_ itemId: String) {
        DispatchQueue.main.async { [weak self] in
            self?.itemStatuses[itemId] = .completed
            writeLog("UnifiedMonitoringService: Item '\(itemId)' marked completed (external)", logLevel: .info)
        }
    }

    /// Mark an item as failed (external trigger)
    func markFailed(_ itemId: String, reason: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.itemStatuses[itemId] = .failed(reason: reason)
            writeLog("UnifiedMonitoringService: Item '\(itemId)' marked failed (external): \(reason ?? "unknown")", logLevel: .info)
        }
    }

    /// Update progress for an item
    func updateProgress(_ itemId: String, progress: Double, message: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.progressValues[itemId] = progress
            if let message = message {
                self?.statusMessages[itemId] = message
            }
            self?.itemStatuses[itemId] = .installing(progress: progress, message: message)
        }
    }

    // MARK: - Private Methods

    private func startStatusCheckTimer() {
        statusCheckTimer?.invalidate()
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.performStatusCheck()
        }
    }

    private func performStatusCheck() {
        for item in items {
            // Skip items with empty paths (managed externally)
            guard !item.paths.isEmpty else { continue }

            let wasCompleted = itemStatuses[item.id] == .completed

            // Check if installed
            let isInstalled = item.paths.first { path in
                FileManager.default.fileExists(atPath: path)
            } != nil

            if isInstalled && !wasCompleted {
                DispatchQueue.main.async { [weak self] in
                    self?.itemStatuses[item.id] = .completed
                    writeLog("UnifiedMonitoringService: Item '\(item.displayName)' detected as installed", logLevel: .info)

                    // Validate if plist config exists
                    if item.plistKey != nil {
                        let result = self?.validateItem(item) ?? .unknown
                        self?.validationResults[item.id] = result
                    }
                }
            } else if !isInstalled && wasCompleted {
                // Item was removed
                DispatchQueue.main.async { [weak self] in
                    self?.itemStatuses[item.id] = .pending
                    writeLog("UnifiedMonitoringService: Item '\(item.displayName)' no longer installed", logLevel: .info)
                }
            } else if !isInstalled {
                // Check if downloading (in cache)
                let isDownloading = checkIfDownloading(item)
                if isDownloading {
                    DispatchQueue.main.async { [weak self] in
                        self?.itemStatuses[item.id] = .downloading(progress: nil)
                    }
                }
            }
        }
    }

    private func checkIfDownloading(_ item: InspectConfig.ItemConfig) -> Bool {
        for cachePath in cachePaths {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: cachePath) else {
                continue
            }

            for file in contents where !file.hasPrefix(".") {
                if isDownloadFile(file) && fileMatchesItem(file, item: item) {
                    return true
                }
            }
        }
        return false
    }

    private func isDownloadFile(_ filename: String) -> Bool {
        let lowercased = filename.lowercased()
        return lowercased.hasSuffix(".download") ||
               lowercased.hasSuffix(".pkg") ||
               lowercased.hasSuffix(".dmg") ||
               lowercased.hasSuffix(".zip") ||
               lowercased.contains(".partial") ||
               lowercased.contains(".tmp")
    }

    private func fileMatchesItem(_ filename: String, item: InspectConfig.ItemConfig) -> Bool {
        let cleanFilename = filename.lowercased()
        let cleanItemId = item.id.lowercased()
        let cleanDisplayName = item.displayName.lowercased().replacingOccurrences(of: " ", with: "")

        return cleanFilename.contains(cleanItemId) ||
               cleanFilename.contains(cleanDisplayName)
    }

    // MARK: - Plist Monitoring

    private func startPlistMonitoringIfNeeded(for item: InspectConfig.ItemConfig) {
        guard let recheckInterval = item.plistRecheckInterval, recheckInterval > 0,
              let plistKey = item.plistKey else {
            return
        }

        let plistPath = item.paths.first { $0.hasSuffix(".plist") } ?? item.paths.first ?? ""
        guard !plistPath.isEmpty else { return }

        // Stop existing monitor if any
        plistMonitorTasks[item.id]?.timer.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: Double(recheckInterval), repeats: true) { [weak self] _ in
            self?.checkPlistValue(for: item, at: plistPath, key: plistKey)
        }

        plistMonitorTasks[item.id] = PlistMonitorTask(
            timer: timer,
            itemId: item.id,
            plistPath: plistPath,
            plistKey: plistKey,
            expectedValue: item.expectedValue,
            evaluation: item.evaluation,
            lastValue: nil
        )

        writeLog("UnifiedMonitoringService: Started plist monitoring for \(item.id)", logLevel: .info)
    }

    private func checkPlistValue(for item: InspectConfig.ItemConfig, at plistPath: String, key plistKey: String) {
        let result = validatePlistValue(
            at: plistPath,
            key: plistKey,
            expectedValue: item.expectedValue,
            evaluation: item.evaluation
        )

        DispatchQueue.main.async { [weak self] in
            let oldResult = self?.validationResults[item.id]
            self?.validationResults[item.id] = result

            if oldResult?.isValid != result.isValid {
                writeLog("UnifiedMonitoringService: Validation changed for \(item.id): \(result.isValid)", logLevel: .info)
            }
        }
    }

    private func validatePlistValue(at path: String, key: String, expectedValue: String?, evaluation: String?) -> MonitoringValidationResult {
        guard PlistHelper.plistExists(at: path) else {
            return MonitoringValidationResult(isValid: false, message: "File not found")
        }

        guard let plist = PlistHelper.readPlist(at: path) else {
            return MonitoringValidationResult(isValid: false, message: "Unable to read plist")
        }

        let actualValue: String?
        if let value = plist.value(forKeyPath: key) {
            actualValue = String(describing: value)
        } else {
            actualValue = nil
        }

        let evaluationType = evaluation ?? "equals"
        let isValid: Bool

        switch evaluationType {
        case "exists":
            isValid = actualValue != nil
        case "boolean":
            isValid = actualValue == "1" || actualValue?.lowercased() == "true"
        case "contains":
            isValid = actualValue?.contains(expectedValue ?? "") ?? false
        case "equals":
            isValid = actualValue == expectedValue
        case "range":
            // Parse range like "1-10"
            if let actual = Int(actualValue ?? ""),
               let range = expectedValue?.split(separator: "-"),
               range.count == 2,
               let lower = Int(range[0]),
               let upper = Int(range[1]) {
                isValid = actual >= lower && actual <= upper
            } else {
                isValid = false
            }
        default:
            isValid = actualValue == expectedValue
        }

        return MonitoringValidationResult(
            isValid: isValid,
            actualValue: actualValue,
            expectedValue: expectedValue,
            evaluationType: evaluationType
        )
    }

    // MARK: - JSON Monitoring

    private func startJsonMonitoringIfNeeded(for item: InspectConfig.ItemConfig) {
        guard let monitors = item.jsonMonitors else { return }

        for monitor in monitors {
            let expandedPath = (monitor.path as NSString).expandingTildeInPath
            let interval = Double(monitor.recheckInterval)

            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.checkJsonValue(for: item.id, at: expandedPath, config: monitor)
            }

            let taskId = "\(item.id)_\(monitor.path.hashValue)"
            jsonMonitorTasks[taskId] = JsonMonitorTask(
                timer: timer,
                itemId: item.id,
                jsonPath: expandedPath,
                jsonKey: monitor.key,
                expectedValue: nil,  // JsonMonitor doesn't have expectedValue, use evaluation instead
                lastValue: nil
            )
        }
    }

    private func checkJsonValue(for itemId: String, at path: String, config: InspectConfig.JsonMonitor) {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let key = config.key
        guard let value = json[key] else { return }

        let stringValue = String(describing: value)

        DispatchQueue.main.async { [weak self] in
            self?.statusMessages[itemId] = stringValue

            // Use evaluation type if specified
            if let evaluation = config.evaluation {
                switch evaluation {
                case "boolean":
                    let isTrue = stringValue == "true" || stringValue == "1"
                    if isTrue {
                        self?.itemStatuses[itemId] = .completed
                    }
                case "exists":
                    self?.itemStatuses[itemId] = .completed
                default:
                    break
                }
            }
        }
    }

    // MARK: - Log Monitor Integration

    private func handleLogMonitorStatuses(_ statuses: [String: String]) {
        for (itemId, status) in statuses {
            let lowerStatus = status.lowercased()

            if lowerStatus.contains("fail") || lowerStatus.contains("error") {
                itemStatuses[itemId] = .failed(reason: status)
            } else if lowerStatus.contains("complet") || lowerStatus.contains("success") || lowerStatus == "completed" {
                itemStatuses[itemId] = .completed
            } else if lowerStatus.contains("install") {
                itemStatuses[itemId] = .installing(progress: nil, message: status)
            } else if lowerStatus.contains("download") {
                itemStatuses[itemId] = .downloading(progress: nil)
            }

            statusMessages[itemId] = status
        }
    }

    // MARK: - Cleanup

    deinit {
        stopMonitoring()
    }
}

// MARK: - Validation Service

/// Standalone validation service for checking plist/JSON values
///
/// Use this service for one-off validations without continuous monitoring.
struct ValidationService {

    /// Validate a plist value against expected criteria
    static func validatePlist(
        at path: String,
        key: String,
        expectedValue: String? = nil,
        evaluation: String? = nil
    ) -> MonitoringValidationResult {
        let expandedPath = (path as NSString).expandingTildeInPath

        guard PlistHelper.plistExists(at: path) else {
            return MonitoringValidationResult(isValid: false, message: "File not found: \(expandedPath)")
        }

        guard let plist = PlistHelper.readPlist(at: path) else {
            return MonitoringValidationResult(isValid: false, message: "Unable to read plist")
        }

        let actualValue: String?
        if let value = plist.value(forKeyPath: key) {
            actualValue = String(describing: value)
        } else {
            actualValue = nil
        }

        let evaluationType = evaluation ?? "equals"
        var isValid = false
        var message: String? = nil

        switch evaluationType {
        case "exists":
            isValid = actualValue != nil
            message = isValid ? "Key exists" : "Key not found"

        case "boolean":
            isValid = actualValue == "1" || actualValue?.lowercased() == "true"
            message = isValid ? "Value is true" : "Value is false or missing"

        case "contains":
            if let actual = actualValue, let expected = expectedValue {
                isValid = actual.contains(expected)
                message = isValid ? "Contains '\(expected)'" : "Does not contain '\(expected)'"
            } else {
                isValid = false
                message = "Missing value or expected"
            }

        case "equals":
            isValid = actualValue == expectedValue
            message = isValid ? "Values match" : "Values differ: '\(actualValue ?? "nil")' vs '\(expectedValue ?? "nil")'"

        case "range":
            if let actual = Int(actualValue ?? ""),
               let range = expectedValue?.split(separator: "-"),
               range.count == 2,
               let lower = Int(range[0]),
               let upper = Int(range[1]) {
                isValid = actual >= lower && actual <= upper
                message = isValid ? "Value \(actual) in range \(lower)-\(upper)" : "Value \(actual) outside range \(lower)-\(upper)"
            } else {
                isValid = false
                message = "Invalid range format"
            }

        case "version":
            // Version comparison (semantic versioning)
            if let actual = actualValue, let expected = expectedValue {
                isValid = compareVersions(actual, expected) >= 0
                message = isValid ? "Version \(actual) >= \(expected)" : "Version \(actual) < \(expected)"
            } else {
                isValid = false
                message = "Missing version values"
            }

        default:
            isValid = actualValue == expectedValue
            message = isValid ? "Values match" : "Unknown evaluation type"
        }

        return MonitoringValidationResult(
            isValid: isValid,
            actualValue: actualValue,
            expectedValue: expectedValue,
            evaluationType: evaluationType,
            message: message
        )
    }

    /// Compare semantic version strings
    private static func compareVersions(_ v1: String, _ v2: String) -> Int {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }

        let maxLength = max(parts1.count, parts2.count)
        for i in 0..<maxLength {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 < p2 { return -1 }
            if p1 > p2 { return 1 }
        }
        return 0
    }

    /// Validate a JSON value
    static func validateJSON(
        at path: String,
        key: String,
        expectedValue: String? = nil
    ) -> MonitoringValidationResult {
        let expandedPath = (path as NSString).expandingTildeInPath

        guard PlistHelper.plistExists(at: path) else {
            return MonitoringValidationResult(isValid: false, message: "File not found: \(expandedPath)")
        }

        guard let data = FileManager.default.contents(atPath: expandedPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MonitoringValidationResult(isValid: false, message: "Unable to read JSON")
        }

        let actualValue: String?
        if let value = json[key] {
            actualValue = String(describing: value)
        } else {
            actualValue = nil
        }

        let isValid = actualValue == expectedValue

        return MonitoringValidationResult(
            isValid: isValid,
            actualValue: actualValue,
            expectedValue: expectedValue,
            message: isValid ? "Values match" : "Values differ"
        )
    }
}
