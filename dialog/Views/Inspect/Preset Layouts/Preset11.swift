//
//  Preset11.swift
//  dialog
//
//  Created by Henry Stamerjohann, Declarative IT GmbH, 17/01/2026
//
//  Self-Service Portal Preset - Branded WebView with Optional Authentication
//
//  Supports:
//  - Optional native SwiftUI intro/outro screens for branded setup flows
//  - Simple unauthenticated URLs (e.g., SOFA, docs)
//  - Authenticated portals with token injection
//  - Multi-brand theming via MDM AppConfig
//
//  Flow: Intro Screens (optional) → Portal WebView → Outro Screens (optional)
//

import SwiftUI
import WebKit

// MARK: - Linear Step Model
// Preset11 uses a fully linear step model where portal is just another step type.
// All steps are in a single array, and stepType determines rendering:
// - "intro" / nil: Native SwiftUI intro screens
// - "processing": Countdown timer with visual feedback
// - "portal": WebView portal (can appear anywhere in the sequence)
// - "outro": Native SwiftUI outro screens (visually same as intro, semantic distinction)

// MARK: - Type Aliases for Shared Enums

/// Alias for InspectCompletionResult - standardizes completion handling across presets
typealias CompletionResult = InspectCompletionResult

/// Alias for InspectOverrideLevel - progressive override UI levels
typealias OverrideLevel = InspectOverrideLevel


struct Preset11View: View {

    @ObservedObject var inspectState: InspectState
    @StateObject private var authService = PortalAuthService()

    // MARK: - Module Services (Modular Architecture)
    @StateObject private var monitoringService = UnifiedMonitoringService()
    @StateObject private var introStepMonitor = IntroStepMonitorService()
    @StateObject private var complianceService = ComplianceAggregatorService()
    @State private var preferencesService: PreferencesService?

    // Linear step navigation (replaces old phase state machine)
    @State private var currentStepIndex: Int = 0
    @State private var gridSelections: [String: Set<String>] = [:]  // Key: gridSelectionKey, Value: selected IDs

    // Installation progress state (for intro steps with installationMode)
    @State private var installationItems: [InstallationItemData] = []
    @State private var processingState: InspectProcessingState = .idle

    // Processing step countdown state
    @State private var processingCountdown: Int = 0
    @State private var processingTimer: Timer?
    @State private var processingWaitElapsed: Int = 0  // Time elapsed waiting (for override escalation)
    @State private var showOverridePicker: Bool = false  // Show override result picker
    @State private var pendingOverrideStepIndex: Int = 0
    @State private var lastOverrideResult: String? = nil  // "success", "failed", or "skipped"
    @State private var lastOverrideStepId: String? = nil  // ID of step that was overridden
    @State private var failedSteps: [String: String] = [:]  // stepId -> failure reason (for result banners)
    @State private var skippedSteps: Set<String> = []  // Track skipped processing steps
    @State private var completedProcessingSteps: Set<String> = []  // Track completed processing steps
    @State private var dynamicContentUpdateCounter: Int = 0  // Increment to force re-render on dynamic updates

    // Dynamic content overrides (controlled via trigger file set: commands)
    @State private var statusBadgeOverrides: [String: String] = [:]  // label/id -> state
    @State private var phaseTrackerOverride: Int? = nil              // Override currentPhase value
    @State private var iconOverride: String? = nil                   // Override main dialog icon
    @State private var heroImageOverrides: [String: String] = [:]    // stepId -> path/SF symbol
    @State private var iconBasePathOverride: String? = nil           // Override iconBasePath

    // External command file monitoring (parity with Preset6)
    @State private var commandFileMonitorTimer: Timer?
    @State private var lastProcessedCommandContent: String = ""  // Track processed content to avoid duplicates

    // Form state management (for interactive form elements in intro steps)
    @State private var formValues: [String: String] = [:]

    // Overlay state (for help overlays like preset6)
    @State private var showGlobalHelpOverlay: Bool = false
    @State private var showStepOverlay: Bool = false
    @State private var currentStepOverlayConfig: InspectConfig.DetailOverlayConfig?

    // Portal state
    @State private var loadState: PortalLoadState = .initializing
    @State private var showContent: Bool = false
    @State private var isRefetching: Bool = false
    @State private var mdmOverrides: MDMBrandingOverrides?

    // Computed config references
    private var config: InspectConfig? { inspectState.config }
    private var portalConfig: InspectConfig.PortalConfig? { config?.portalConfig }
    private var appConfigService: AppConfigService { AppConfigService.shared }

    // MARK: - Step Navigation (Linear Step Model)

    /// All steps in the linear step sequence
    /// Steps are displayed in order with stepType determining how each is rendered
    private var allSteps: [InspectConfig.IntroStep] {
        config?.introSteps ?? []
    }

    /// Total number of steps (for progress indicators)
    private var totalSteps: Int { allSteps.count }

    /// Whether we have any steps to show
    private var hasSteps: Bool { !allSteps.isEmpty }

    /// Current step (nil if index out of bounds)
    private var currentStep: InspectConfig.IntroStep? {
        guard currentStepIndex >= 0 && currentStepIndex < allSteps.count else { return nil }
        return allSteps[currentStepIndex]
    }

    /// Whether the current step is a portal step
    private var isPortalStep: Bool {
        currentStep?.stepType == "portal"
    }

    /// Get the effective portal config for the current step
    /// Per-step portal config overrides global portal config
    private var effectivePortalConfig: InspectConfig.PortalConfig? {
        currentStep?.portalConfig ?? config?.portalConfig
    }

    // MARK: - Legacy Computed Properties (for backward compatibility)

    /// Intro steps - now just filters allSteps for intro/processing types
    private var introSteps: [InspectConfig.IntroStep] {
        allSteps.filter { step in
            let stepType = step.stepType ?? "intro"
            return stepType == "intro" || stepType == "processing"
        }
    }

    /// Outro steps - filters allSteps for outro type
    private var outroSteps: [InspectConfig.IntroStep] {
        allSteps.filter { $0.stepType == "outro" }
    }

    /// Whether we have any outro screens (for legacy compatibility)
    private var hasOutroScreens: Bool { !outroSteps.isEmpty }

    // MARK: - State Persistence (UserDefaults)

    /// Preference domain for state persistence (default: com.swiftdialog.preset11)
    private var stateDomain: String {
        portalConfig?.stateDomain ?? "com.swiftdialog.preset11"
    }

    /// UserDefaults suite for state persistence
    private var stateDefaults: UserDefaults {
        UserDefaults(suiteName: stateDomain) ?? .standard
    }

    /// Check if all steps were already completed (skip on subsequent launches)
    private var stepsAlreadyCompleted: Bool {
        stateDefaults.bool(forKey: "stepsCompleted")
    }

    /// Get the last completed step index for resume
    private var lastCompletedStepIndex: Int {
        stateDefaults.integer(forKey: "lastStepIndex")
    }

    /// Get previously saved selections
    private var savedSelections: [String: [String]] {
        stateDefaults.dictionary(forKey: "selections") as? [String: [String]] ?? [:]
    }

    // MARK: - Trigger File Configuration

    /// Computed trigger file path based on mode (dev/prod) and config
    /// - Priority: 1) Custom path from config, 2) Dev mode path, 3) Prod mode path (PID-based)
    private var triggerFilePath: String {
        // 1. Custom path from config takes priority
        if let customPath = config?.triggerFile {
            return customPath
        }

        // 2. Dev mode (--inspect-mode): predictable path for inspector tools
        if appArguments.inspectMode.present {
            return "/tmp/swiftdialog_dev_preset11.trigger"
        }

        // 3. Prod mode: unique per instance using PID
        return "/tmp/swiftdialog_\(ProcessInfo.processInfo.processIdentifier)_preset11.trigger"
    }

    /// Final button trigger file path (for completion state output)
    private var finalTriggerFilePath: String {
        // 1. Custom path from config - append _final suffix
        if let customPath = config?.triggerFile {
            let url = URL(fileURLWithPath: customPath)
            let ext = url.pathExtension
            let base = url.deletingPathExtension().path
            return ext.isEmpty ? "\(customPath)_final" : "\(base)_final.\(ext)"
        }

        // 2. Dev mode
        if appArguments.inspectMode.present {
            return "/tmp/swiftdialog_dev_preset11_final.trigger"
        }

        // 3. Prod mode
        return "/tmp/swiftdialog_\(ProcessInfo.processInfo.processIdentifier)_preset11_final.trigger"
    }

    /// Trigger mode string for logging
    private var triggerMode: String {
        if config?.triggerFile != nil {
            return "custom"
        }
        return appArguments.inspectMode.present ? "dev" : "prod"
    }

    /// Save current step index for resume (linear step model)
    private func saveCurrentStepIndex() {
        stateDefaults.set(currentStepIndex, forKey: "lastStepIndex")

        // Save selections
        let selectionsDict = gridSelections.mapValues { Array($0) }
        stateDefaults.set(selectionsDict, forKey: "selections")

        stateDefaults.synchronize()
        writeLog("Preset11: Saved step index \(currentStepIndex) to UserDefaults domain: \(stateDomain)", logLevel: .info)
    }

    /// Reset all state (for testing or re-run scenarios)
    private func resetState() {
        stateDefaults.removeObject(forKey: "stepsCompleted")
        stateDefaults.removeObject(forKey: "stepsCompletedAt")
        stateDefaults.removeObject(forKey: "lastStepIndex")
        stateDefaults.removeObject(forKey: "selections")
        // Also clear legacy keys
        stateDefaults.removeObject(forKey: "introCompleted")
        stateDefaults.removeObject(forKey: "outroCompleted")
        stateDefaults.removeObject(forKey: "introCompletedAt")
        stateDefaults.removeObject(forKey: "outroCompletedAt")
        stateDefaults.synchronize()
        writeLog("Preset11: Reset state in UserDefaults domain: \(stateDomain)", logLevel: .info)
    }

    // MDM-aware branding getters
    private var effectiveHighlightColor: String? {
        appConfigService.effectiveHighlightColor(
            jsonValue: config?.highlightColor, mdm: mdmOverrides)
    }

    private var effectiveAccentBorderColor: String? {
        appConfigService.effectiveAccentBorderColor(
            jsonValue: config?.accentBorderColor, mdm: mdmOverrides)
    }

    private var effectiveFooterBackgroundColor: String? {
        appConfigService.effectiveFooterBackgroundColor(
            jsonValue: config?.footerBackgroundColor, mdm: mdmOverrides)
    }

    private var effectiveFooterTextColor: String? {
        appConfigService.effectiveFooterTextColor(
            jsonValue: config?.footerTextColor, mdm: mdmOverrides)
    }

    private var effectiveFooterText: String? {
        appConfigService.effectiveFooterText(jsonValue: config?.footerText, mdm: mdmOverrides)
    }

    private var effectiveLogoPath: String? {
        appConfigService.effectiveLogoPath(
            jsonValue: config?.logoConfig?.imagePath, mdm: mdmOverrides)
    }

    // Portal URL - from file, config, or MDM override
    // Uses effectivePortalConfig which allows per-step portal config overrides
    private var portalURL: URL? {
        let portalCfg = effectivePortalConfig
        var baseURL: String?

        // Priority 1: Read URL from file (for dynamic device-specific URLs)
        if let urlFilePath = portalCfg?.portalURLFile {
            if let fileURL = readURLFromFile(path: urlFilePath) {
                baseURL = fileURL
                writeLog("Preset11: Loaded portal URL from file: \(urlFilePath)", logLevel: .debug)
            }
        }

        // Priority 2: MDM override
        if baseURL == nil, let mdmURL = mdmOverrides?.portalURL {
            baseURL = mdmURL
            writeLog("Preset11: Using MDM override portal URL", logLevel: .debug)
        }

        // Priority 3: Config value
        if baseURL == nil {
            baseURL = portalCfg?.portalURL
        }

        guard let urlString = baseURL else { return nil }

        // Append selfServicePath if provided
        var fullURL = urlString
        if let path = portalCfg?.selfServicePath {
            fullURL =
                urlString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
                + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return URL(string: fullURL)
    }

    // Read URL from a file (strips whitespace/newlines)
    private func readURLFromFile(path: String) -> String? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            writeLog("Preset11: URL file not found: \(path)", logLevel: .debug)
            return nil
        }
        do {
            let content = try String(contentsOfFile: expandedPath, encoding: .utf8)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        } catch {
            writeLog("Preset11: Failed to read URL file: \(error)", logLevel: .error)
            return nil
        }
    }

    // Check if auth is required (uses effectivePortalConfig for per-step overrides)
    private var requiresAuth: Bool {
        return effectivePortalConfig?.authSources != nil
    }

    // Build custom headers for branding and user-defined headers
    // Uses effectivePortalConfig for per-step overrides
    private var customPortalHeaders: [String: String]? {
        let portalCfg = effectivePortalConfig
        var headers: [String: String] = [:]

        // Add branding key with configurable header name
        // Supports: X-Brand-ID, X-Tenant-ID, X-Org-ID, X-Theme-ID, X-UI-Theme, or any custom header
        if let brandingKey = portalCfg?.brandingKey {
            let headerName = portalCfg?.brandingHeaderName ?? "X-Brand-ID"
            headers[headerName] = brandingKey
            writeLog("Preset11: Adding branding header \(headerName): \(brandingKey)", logLevel: .debug)
        }

        // Add any custom headers from config
        if let customHeaders = portalCfg?.customHeaders {
            for (key, value) in customHeaders {
                headers[key] = value
            }
        }

        return headers.isEmpty ? nil : headers
    }

    var body: some View {
        ZStack {
            mainContent

            // Floating help button (if configured)
            if let helpButton = config?.helpButton, helpButton.enabled == true {
                floatingHelpButton(config: helpButton)
            }

            // Instruction banner overlay (top of window)
            if let bannerConfig = config?.instructionBanner,
               let bannerText = bannerConfig.text {
                VStack {
                    InstructionBanner(
                        text: bannerText,
                        autoDismiss: bannerConfig.autoDismiss ?? true,
                        dismissDelay: bannerConfig.dismissDelay ?? 5.0,
                        icon: bannerConfig.icon
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    Spacer()
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            loadMDMOverrides()
            initializePhase()
        }
        // Global help overlay sheet
        .sheet(isPresented: $showGlobalHelpOverlay) {
            if let overlayConfig = config?.detailOverlay {
                DetailOverlayView(
                    inspectState: inspectState,
                    config: overlayConfig,
                    onClose: { showGlobalHelpOverlay = false }
                )
            }
        }
        // Per-step overlay sheet
        .sheet(isPresented: $showStepOverlay) {
            if let overlayConfig = currentStepOverlayConfig {
                DetailOverlayView(
                    inspectState: inspectState,
                    config: overlayConfig,
                    onClose: { showStepOverlay = false }
                )
            }
        }
    }

    // MARK: - External Command Processing (Parity with Preset6)

    /// Process external commands from the command file
    /// Supports: success:stepId[:message], failure:stepId[:reason], warning:stepId[:message]
    private func processExternalCommands(_ content: String) {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }
            processPresetCommand(trimmedLine)
        }
    }

    /// Process a single preset command
    /// Command format examples:
    /// - "success:processing-demo"
    /// - "success:processing-demo:Custom success message"
    /// - "failure:processing-demo"
    /// - "failure:processing-demo:Error reason"
    /// - "warning:processing-demo:Warning message"
    /// - "navigate:stepId" - Jump to a specific step by ID
    private func processPresetCommand(_ trimmedLine: String) {
        if trimmedLine.hasPrefix("success:") {
            // Extract message (format: "success:stepId:optional_message")
            let parts = trimmedLine.dropFirst(8).split(separator: ":", maxSplits: 1)
            let stepId = String(parts[0])
            let message = parts.count > 1 ? String(parts[1]) : nil
            writeLog("Preset11: Received external success command for step '\(stepId)'", logLevel: .info)
            handleCompletionTrigger(stepId: stepId, result: .success(message: message))
        } else if trimmedLine.hasPrefix("failure:") {
            // Extract reason (format: "failure:stepId:optional_reason")
            let parts = trimmedLine.dropFirst(8).split(separator: ":", maxSplits: 1)
            let stepId = String(parts[0])
            let reason = parts.count > 1 ? String(parts[1]) : "Step failed"
            writeLog("Preset11: Received external failure command for step '\(stepId)'", logLevel: .info)
            handleCompletionTrigger(stepId: stepId, result: .failure(message: reason))
        } else if trimmedLine.hasPrefix("warning:") {
            // Extract message (format: "warning:stepId:optional_message")
            let parts = trimmedLine.dropFirst(8).split(separator: ":", maxSplits: 1)
            let stepId = String(parts[0])
            let message = parts.count > 1 ? String(parts[1]) : "Step warning"
            writeLog("Preset11: Received external warning command for step '\(stepId)'", logLevel: .info)
            handleCompletionTrigger(stepId: stepId, result: .warning(message: message))
        } else if trimmedLine.hasPrefix("navigate:") {
            // Navigate to a specific step (format: "navigate:stepId")
            let stepId = String(trimmedLine.dropFirst(9))
            writeLog("Preset11: Received navigate command for step '\(stepId)'", logLevel: .info)
            navigateToStep(stepId: stepId)
        } else if trimmedLine == "next" {
            // Go to next step
            writeLog("Preset11: Received next command", logLevel: .info)
            goToNextStep()
        } else if trimmedLine == "prev" || trimmedLine == "back" {
            // Go to previous step
            writeLog("Preset11: Received prev command", logLevel: .info)
            goToPrevStep()
        } else if trimmedLine.hasPrefix("set:") {
            // Dynamic content override command (format: "set:type:target:value")
            let parts = trimmedLine.dropFirst(4).split(separator: ":", maxSplits: 2)
            if parts.count >= 2 {
                let targetType = String(parts[0])
                let value = String(parts[1])
                let extra = parts.count > 2 ? String(parts[2]) : nil
                handleSetCommand(targetType: targetType, value: value, extra: extra)
            } else {
                writeLog("Preset11: Invalid set command format: \(trimmedLine)", logLevel: .error)
            }
        } else if trimmedLine.hasPrefix("goto:") {
            // Alias for navigate (Preset6 compatibility)
            let stepId = String(trimmedLine.dropFirst(5))
            writeLog("Preset11: Received goto command for step '\(stepId)'", logLevel: .info)
            navigateToStep(stepId: stepId)
        } else if trimmedLine.hasPrefix("update_guidance:") {
            // Dynamic guidance content update (format: "update_guidance:stepId:blockIndex:property=value" or "update_guidance:stepId:blockIndex:newContent")
            handleUpdateGuidanceCommand(trimmedLine)
        } else if trimmedLine == "reset" {
            // Reset to first step
            writeLog("Preset11: Received reset command", logLevel: .info)
            currentStepIndex = 0
        } else {
            writeLog("Preset11: Unknown command received: \(trimmedLine)", logLevel: .debug)
        }
    }

    /// Navigate to a specific step by ID (linear step model)
    private func navigateToStep(stepId: String) {
        // Find step in the unified allSteps array
        if let index = allSteps.firstIndex(where: { $0.id == stepId }) {
            writeLog("Preset11: Navigating to step '\(stepId)' at index \(index)", logLevel: .info)
            currentStepIndex = index
            return
        }

        // Legacy support: "portal" ID navigates to first portal step
        if stepId == "portal" {
            if let index = allSteps.firstIndex(where: { $0.stepType == "portal" }) {
                writeLog("Preset11: Navigating to portal step at index \(index)", logLevel: .info)
                currentStepIndex = index
                return
            }
        }

        writeLog("Preset11: Step '\(stepId)' not found for navigation", logLevel: .error)
    }

    /// Go to the next step in the linear sequence
    private func goToNextStep() {
        // Write step completion output
        if let step = currentStep {
            writeStepOutput(stepId: step.id, action: "completed")
            writeStepData(for: step)
        }

        if currentStepIndex + 1 < allSteps.count {
            currentStepIndex += 1
            writeLog("Preset11: Advanced to step \(currentStepIndex)", logLevel: .info)
        } else {
            // Past the last step - complete
            writeLog("Preset11: All steps completed, finishing", logLevel: .info)
            handleCompletion()
        }
    }

    /// Go to the previous step in the linear sequence
    private func goToPreviousStep() {
        if currentStepIndex > 0 {
            currentStepIndex -= 1
            writeLog("Preset11: Moved back to step \(currentStepIndex)", logLevel: .info)
        }
    }

    /// Legacy alias for goToPreviousStep (used in some code paths)
    private func goToPrevStep() {
        goToPreviousStep()
    }

    /// Write step-specific data (selections, form values, etc.)
    private func writeStepData(for step: InspectConfig.IntroStep) {
        // Write any grid selections for this step
        if let selectionKey = step.gridSelectionKey,
           let selections = gridSelections[selectionKey] {
            writeSelectionOutput(key: selectionKey, selections: Array(selections))

            // Write to preferences service if configured with preferenceKey
            if let preferenceKey = step.gridPreferenceKey ?? step.gridSelectionKey {
                let selectionArray = Array(selections).sorted()
                let isMultiSelect = (step.gridSelectionMode ?? "single") == "multiple"
                let selectedValue = isMultiSelect ? selectionArray.joined(separator: ",") : (selectionArray.first ?? "")
                preferencesService?.setValue(selectedValue, forKey: preferenceKey)
                writeLog("Preset11: Wrote preference '\(preferenceKey)' = '\(selectedValue)'", logLevel: .info)
            }
        }

        // Write any wallpaper selections for this step
        if let wallpaperKey = step.wallpaperSelectionKey {
            let preferenceKey = step.wallpaperPreferenceKey ?? wallpaperKey
            if let wallpaperPath = inspectState.wallpaperSelection[wallpaperKey] {
                preferencesService?.setValue(wallpaperPath, forKey: preferenceKey)
                writeLog("Preset11: Wrote wallpaper preference '\(preferenceKey)' = '\(wallpaperPath)'", logLevel: .info)
            }
        }

        // Write form values from this step's content blocks
        if let content = step.content {
            let formTypes = ["checkbox", "dropdown", "radio", "toggle", "textfield", "slider"]
            for block in content where formTypes.contains(block.type) {
                if let fieldId = block.id, let value = formValues[fieldId] {
                    preferencesService?.setValue(value, forKey: fieldId)
                    writeLog("Preset11: Persisted form value '\(fieldId)' = '\(value)'", logLevel: .debug)
                }
            }
            if content.contains(where: { formTypes.contains($0.type) }) {
                preferencesService?.writeToPlist()
            }
        }
    }

    /// Handle completion of all steps
    private func handleCompletion() {
        saveCompletionState()
        writeFinalOutput()
        handleButton1()
    }

    /// Save completion state to UserDefaults
    private func saveCompletionState() {
        stateDefaults.set(true, forKey: "stepsCompleted")
        stateDefaults.set(Date(), forKey: "stepsCompletedAt")
        stateDefaults.set(currentStepIndex, forKey: "lastStepIndex")
        stateDefaults.synchronize()
        writeLog("Preset11: Saved completion state to UserDefaults domain: \(stateDomain)", logLevel: .info)
    }

    // MARK: - Dynamic Content Override Handlers

    /// Handle set: commands for dynamic content overrides
    /// Command format: set:type:target:value
    /// - status-badge: Update status badge state by label or ID
    /// - phase-tracker: Update phase tracker current phase
    /// - icon: Override main dialog icon
    /// - heroImage: Override step hero image
    /// - iconBasePath: Override icon base path
    private func handleSetCommand(targetType: String, value: String, extra: String?) {
        switch targetType {
        case "status-badge":
            // Format: set:status-badge:labelOrId:state
            let label = value
            let state = extra ?? "enabled"
            statusBadgeOverrides[label] = state
            writeLog("Preset11: Set status badge '\(label)' to state '\(state)'", logLevel: .info)

        case "phase-tracker":
            // Format: set:phase-tracker:phaseIndex
            if let phaseIndex = Int(value) {
                phaseTrackerOverride = phaseIndex
                writeLog("Preset11: Set phase tracker to phase \(phaseIndex)", logLevel: .info)
            } else {
                writeLog("Preset11: Invalid phase-tracker index: \(value)", logLevel: .error)
            }

        case "icon":
            // Format: set:icon:pathOrSFSymbol
            iconOverride = value
            writeLog("Preset11: Set icon override to '\(value)'", logLevel: .info)

        case "heroImage":
            // Format: set:heroImage:stepId:pathOrSFSymbol
            let stepId = value
            let path = extra ?? ""
            if !path.isEmpty {
                heroImageOverrides[stepId] = path
                writeLog("Preset11: Set hero image for step '\(stepId)' to '\(path)'", logLevel: .info)
            } else {
                heroImageOverrides.removeValue(forKey: stepId)
                writeLog("Preset11: Cleared hero image override for step '\(stepId)'", logLevel: .info)
            }

        case "iconBasePath":
            // Format: set:iconBasePath:path
            iconBasePathOverride = value.isEmpty ? nil : value
            writeLog("Preset11: Set icon base path override to '\(value)'", logLevel: .info)

        case "clear":
            // Format: set:clear:type (clear specific override type)
            clearOverrides(type: value)

        default:
            writeLog("Preset11: Unknown set command type: \(targetType)", logLevel: .debug)
        }
    }

    /// Clear dynamic overrides by type or all
    private func clearOverrides(type: String) {
        switch type {
        case "status-badge", "status-badges":
            statusBadgeOverrides.removeAll()
            writeLog("Preset11: Cleared all status badge overrides", logLevel: .info)
        case "phase-tracker":
            phaseTrackerOverride = nil
            writeLog("Preset11: Cleared phase tracker override", logLevel: .info)
        case "icon":
            iconOverride = nil
            writeLog("Preset11: Cleared icon override", logLevel: .info)
        case "heroImage", "heroImages":
            heroImageOverrides.removeAll()
            writeLog("Preset11: Cleared all hero image overrides", logLevel: .info)
        case "iconBasePath":
            iconBasePathOverride = nil
            writeLog("Preset11: Cleared icon base path override", logLevel: .info)
        case "all":
            statusBadgeOverrides.removeAll()
            phaseTrackerOverride = nil
            iconOverride = nil
            heroImageOverrides.removeAll()
            iconBasePathOverride = nil
            writeLog("Preset11: Cleared all dynamic overrides", logLevel: .info)
        default:
            writeLog("Preset11: Unknown clear type: \(type)", logLevel: .debug)
        }
    }

    /// Handle update_guidance: command for dynamic content updates
    /// Format: update_guidance:stepId:blockIndex:property=value OR update_guidance:stepId:blockIndex:newContent
    private func handleUpdateGuidanceCommand(_ command: String) {
        // Format: update_guidance:stepId:blockIndex:property=value OR update_guidance:stepId:blockIndex:contentWithoutEquals
        let payload = String(command.dropFirst(16)) // Remove "update_guidance:"
        let parts = payload.split(separator: ":", maxSplits: 2).map(String.init)

        guard parts.count >= 3 else {
            writeLog("Preset11: Invalid update_guidance format: \(command)", logLevel: .error)
            return
        }

        let stepId = parts[0]
        guard let blockIndex = Int(parts[1]) else {
            writeLog("Preset11: Invalid block index in update_guidance: \(parts[1])", logLevel: .error)
            return
        }

        let valueOrContent = parts[2]

        // Get or create state for this block index
        if introStepMonitor.contentStates[blockIndex] == nil {
            introStepMonitor.contentStates[blockIndex] = DynamicContentState()
        }

        guard let state = introStepMonitor.contentStates[blockIndex] else {
            writeLog("Preset11: Failed to get content state for block \(blockIndex)", logLevel: .error)
            return
        }

        // Check if this is a property=value format or plain content
        if let equalsIndex = valueOrContent.firstIndex(of: "=") {
            let property = String(valueOrContent[..<equalsIndex])
            let value = String(valueOrContent[valueOrContent.index(after: equalsIndex)...])

            switch property {
            case "label":
                state.label = value
                writeLog("Preset11: Updated guidance block \(blockIndex) label to '\(value)'", logLevel: .info)
            case "state":
                state.state = value
                writeLog("Preset11: Updated guidance block \(blockIndex) state to '\(value)'", logLevel: .info)
            case "actual":
                state.actual = value
                writeLog("Preset11: Updated guidance block \(blockIndex) actual to '\(value)'", logLevel: .info)
            case "progress":
                if let progressValue = Double(value) {
                    state.progress = progressValue
                    writeLog("Preset11: Updated guidance block \(blockIndex) progress to \(progressValue)", logLevel: .info)
                }
            case "currentPhase":
                if let phaseValue = Int(value) {
                    state.currentPhase = phaseValue
                    writeLog("Preset11: Updated guidance block \(blockIndex) currentPhase to \(phaseValue)", logLevel: .info)
                }
            case "content":
                state.content = value
                writeLog("Preset11: Updated guidance block \(blockIndex) content to '\(value)'", logLevel: .info)
            case "visible":
                state.visible = value.lowercased() == "true" || value == "1"
                writeLog("Preset11: Updated guidance block \(blockIndex) visible to \(state.visible)", logLevel: .info)
            case "passed":
                if let passedValue = Int(value) {
                    state.passed = passedValue
                    writeLog("Preset11: Updated guidance block \(blockIndex) passed to \(passedValue)", logLevel: .info)
                }
            case "total":
                if let totalValue = Int(value) {
                    state.total = totalValue
                    writeLog("Preset11: Updated guidance block \(blockIndex) total to \(totalValue)", logLevel: .info)
                }
            default:
                writeLog("Preset11: Unknown property in update_guidance: \(property)", logLevel: .debug)
            }
        } else {
            // Plain content update (no equals sign) - treat as label/content update
            state.content = valueOrContent
            writeLog("Preset11: Updated guidance block \(blockIndex) content to '\(valueOrContent)'", logLevel: .info)
        }

        // Trigger UI update
        DispatchQueue.main.async {
            self.introStepMonitor.objectWillChange.send()
            self.dynamicContentUpdateCounter += 1
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        // Wait for config to load before rendering
        if config == nil {
            ProgressView("Loading...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let step = currentStep {
            // Linear step model: render based on stepType
            currentStepView(step: step)
                .id("step-\(currentStepIndex)-\(step.id)")  // Force view recreation on step change
        } else if currentStepIndex >= allSteps.count {
            // Past the last step - complete and close
            Color.clear.onAppear { handleCompletion() }
        } else {
            // No steps configured
            noStepsConfigured
        }
    }

    /// Renders the current step based on its stepType
    @ViewBuilder
    private func currentStepView(step: InspectConfig.IntroStep) -> some View {
        let stepType = step.stepType ?? "intro"

        switch stepType {
        case "portal":
            // Portal step - render WebView portal
            portalViewContent
        case "processing":
            // Processing step with countdown
            if step.processingDuration != nil {
                processingStepView(step: step, stepIndex: currentStepIndex)
            } else {
                standardIntroStepView(step: step, stepIndex: currentStepIndex)
            }
        case "outro":
            // Outro step - same view as intro, just semantic distinction
            introStepView(step: step, stepIndex: currentStepIndex)
        default:
            // "intro" or unknown - standard intro step view
            introStepView(step: step, stepIndex: currentStepIndex)
        }
    }

    /// View shown when no steps are configured
    @ViewBuilder
    private var noStepsConfigured: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)

            Text("No Steps Configured")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add steps to the introSteps array in your configuration")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Initialize to the correct starting step (linear step model)
    private func initializePhase() {
        writeLog("Preset11.initializePhase: config=\(config != nil), allSteps count=\(allSteps.count)", logLevel: .debug)

        // Initialize preferences service if configured
        initializePreferencesService()

        // Check if steps were already completed on a previous launch
        // Use modular shouldSkipCompletedSteps from InspectState (respects debugMode and DIALOG_DEBUG_MODE env)
        if inspectState.shouldSkipCompletedSteps && stateDefaults.bool(forKey: "stepsCompleted") {
            writeLog("Preset11: Steps already completed, closing", logLevel: .info)
            handleButton1()
            return
        }

        // Check for saved step index to resume from (unless debug mode is active)
        let savedStepIndex = stateDefaults.integer(forKey: "lastStepIndex")
        if inspectState.shouldSkipCompletedSteps && savedStepIndex > 0 && savedStepIndex < allSteps.count {
            writeLog("Preset11: Resuming from saved step index \(savedStepIndex)", logLevel: .info)
            currentStepIndex = savedStepIndex
        } else if hasSteps {
            // Debug mode OR no saved state: start from step 0
            if !inspectState.shouldSkipCompletedSteps {
                writeLog("Preset11: Debug mode active, starting from step 0", logLevel: .info)
            } else {
                writeLog("Preset11: Starting with first step", logLevel: .info)
            }
            currentStepIndex = 0
        } else {
            writeLog("Preset11: No steps configured, closing", logLevel: .info)
            handleButton1()
            return
        }

        // If the current step is a portal step, set up the portal
        if isPortalStep {
            setupPortal()
        }

        // Start compliance aggregation if plistSources are configured
        if let plistSources = config?.plistSources, !plistSources.isEmpty {
            writeLog("Preset11: Starting ComplianceAggregatorService with \(plistSources.count) sources", logLevel: .info)
            complianceService.startMonitoring(sources: plistSources, refreshInterval: 5.0)
        } else {
            writeLog("Preset11: No plistSources configured, compliance service not started", logLevel: .info)
        }

        // Start external command file monitoring (parity with Preset6)
        setupCommandFileMonitoring()
    }

    // MARK: - Command File Monitoring (Parity with Preset6)

    /// Set up file monitoring for external command triggers
    /// Uses Timer-based polling for reliable cross-view state management
    private func setupCommandFileMonitoring() {
        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: triggerFilePath) {
            FileManager.default.createFile(atPath: triggerFilePath, contents: nil, attributes: nil)
        }

        // Use Timer for polling (more reliable than DispatchSource with SwiftUI @State)
        // Note: Capture list removed - struct views are value types, no retain cycle risk
        commandFileMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
            self.checkForExternalTrigger()
        }

        // Output trigger file info for scripts/inspector to discover
        print("[SWIFTDIALOG] trigger_file: \(triggerFilePath)")
        print("[SWIFTDIALOG] trigger_mode: \(triggerMode)")
        print("[PRESET11_PROCESSING] command_file_monitoring_started: \(triggerFilePath)")
        writeLog("Preset11: Command file monitoring started at \(triggerFilePath) (mode: \(triggerMode), polling every 0.5s)", logLevel: .info)
    }

    /// Check for external trigger commands in the file
    private func checkForExternalTrigger() {
        guard let content = try? String(contentsOfFile: triggerFilePath, encoding: .utf8) else {
            return
        }

        // Skip if content hasn't changed (avoid duplicate processing)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty, trimmedContent != lastProcessedCommandContent else {
            return
        }

        // Log that we received content
        print("[PRESET11_PROCESSING] trigger_received: \(trimmedContent)")
        writeLog("Preset11: Received trigger content: \(trimmedContent)", logLevel: .info)

        // Process new commands
        lastProcessedCommandContent = trimmedContent
        processExternalCommands(content)

        // Clear the file after processing
        try? "".write(toFile: triggerFilePath, atomically: true, encoding: .utf8)
    }

    /// Stop command file monitoring
    private func stopCommandFileMonitoring() {
        commandFileMonitorTimer?.invalidate()
        commandFileMonitorTimer = nil
    }

    /// Initialize preferences service from config
    private func initializePreferencesService() {
        guard let config = config,
              let prefsOutput = config.preferencesOutput else {
            writeLog("Preset11: No preferencesOutput config, preferences service disabled", logLevel: .debug)
            return
        }

        let outputConfig = PreferencesOutputConfig(
            plistPath: prefsOutput.plistPath,
            writeOnStepComplete: prefsOutput.writeOnStepComplete,
            writeOnDialogExit: prefsOutput.writeOnDialogExit,
            mergeWithExisting: prefsOutput.mergeWithExisting
        )

        preferencesService = PreferencesService(config: outputConfig, userDefaultsSuite: stateDomain)
        writeLog("Preset11: Initialized PreferencesService with plist path: \(prefsOutput.plistPath)", logLevel: .info)
    }

    // MARK: - Portal View

    private var portalViewContent: some View {
        VStack(spacing: 0) {
            // Accent border at top
            accentBorder

            // Main content area
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Branded footer
            brandedFooter
        }
        .onAppear {
            // Set up portal when entering a portal step
            if isPortalStep {
                setupPortal()
            }
        }
    }

    // MARK: - Accent Border

    private var accentBorder: some View {
        Rectangle()
            .fill(accentColor)
            .frame(height: 4)
    }

    private var accentColor: Color {
        // Use PrimaryColor (highlightColor) for consistent branding across all elements
        if let colorHex = effectiveHighlightColor ?? effectiveAccentBorderColor {
            return Color(hex: colorHex)
        }
        return Color.accentColor
    }

    /// Effective icon base path (override takes precedence over config)
    private var effectiveIconBasePath: String? {
        iconBasePathOverride ?? inspectState.uiConfiguration.iconBasePath
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if let url = portalURL {
            ZStack {
                // WebView
                PortalWebView(
                    url: url,
                    authHeaders: requiresAuth ? authService.getAuthHeaders() : nil,
                    customHeaders: customPortalHeaders,
                    userAgent: portalConfig?.userAgent,
                    onLoadStateChange: { state in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            loadState = state
                            if state == .loaded {
                                showContent = true
                            }
                        }
                    },
                    onNavigationError: { error in
                        writeLog("Preset11: Navigation error - \(error)", logLevel: .error)
                    }
                )
                .opacity(showContent ? 1 : 0.3)

                // Loading overlay
                if loadState == .loading || loadState == .initializing {
                    loadingOverlay
                }

                // Error overlay
                if case .error(let message) = loadState {
                    errorOverlay(message: message)
                }
            }
        } else {
            // No URL configured
            noURLConfigured
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text(loadState == .initializing ? "Connecting..." : "Loading...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
    }

    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text("Unable to Connect")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            if let fallback = portalConfig?.fallbackMessage {
                Text(fallback)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            HStack(spacing: 16) {
                Button(action: retryConnection) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Try Again")
                    }
                }
                .buttonStyle(.bordered)

                if let supportURLString = portalConfig?.supportURL,
                    let supportURL = URL(string: supportURLString)
                {
                    Link(destination: supportURL) {
                        HStack {
                            Image(systemName: "questionmark.circle")
                            Text("Contact IT")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let contact = portalConfig?.supportContact {
                Text(contact)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var noURLConfigured: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)

            Text("No Portal URL Configured")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add a portalConfig with portalURL to display content")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Branded Footer

    private var brandedFooter: some View {
        HStack(spacing: 12) {
            // Logo (from logoConfig or MDM override) - fixed size for consistency
            if let logoPath = effectiveLogoPath,
               let nsImage = NSImage(contentsOfFile: logoPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: config?.logoConfig?.maxWidth ?? 36,
                        height: config?.logoConfig?.maxHeight ?? 36)
            }

            // Footer text
            if let footerText = effectiveFooterText {
                Text(footerText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(footerTextColor)
            }

            Spacer()

            // Refresh button
            Button(action: refetch) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isRefetching ? 360 : 0))
            }
            .buttonStyle(.borderless)
            .disabled(loadState == .loading)

            // Back button (button2) - MDM > portal-specific > global
            if config?.button2Visible ?? false {
                Button(mdmOverrides?.button2Text ?? portalConfig?.button2Text ?? config?.button2Text ?? "Back") {
                    handleButton2()
                }
                .buttonStyle(.bordered)
                .tint(primaryColor)
                .controlSize(.large)
            }

            // Done button (button1) - MDM > portal-specific > global
            Button(mdmOverrides?.button1Text ?? portalConfig?.button1Text ?? config?.button1Text ?? "Done") {
                handleButton1()
            }
            .buttonStyle(.borderedProminent)
            .tint(primaryColor)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(footerBackgroundColor)
        .tint(primaryColor)  // Ensure all child views inherit the brand color
    }

    private var footerBackgroundColor: Color {
        if let colorHex = effectiveFooterBackgroundColor {
            return Color(hex: colorHex)
        }
        return Color(NSColor.windowBackgroundColor)
    }

    private var footerTextColor: Color {
        if let colorHex = effectiveFooterTextColor {
            return Color(hex: colorHex)
        }
        return .primary
    }

    private var primaryColor: Color {
        if let colorHex = effectiveHighlightColor {
            return Color(hex: colorHex)
        }
        return .accentColor
    }

    // MARK: - Intro/Outro Step View

    /// Renders a single step using shared components (linear step model)
    /// stepType is used to determine visual style (intro vs outro) but all steps are in one sequence
    @ViewBuilder
    private func introStepView(step: InspectConfig.IntroStep, stepIndex: Int) -> some View {
        // Check if this is an installation mode step (highest priority)
        if let installationMode = step.installationMode, !installationMode.isEmpty {
            installationStepView(step: step, stepIndex: stepIndex)
        }
        // Check if this is a dedicated wallpaper picker step
        else if let categories = step.wallpaperCategories, !categories.isEmpty {
            wallpaperStepView(step: step, stepIndex: stepIndex)
        }
        // Check if this is a processing step with countdown timer
        else if step.stepType == "processing" && step.processingDuration != nil {
            processingStepView(step: step, stepIndex: stepIndex)
        } else {
            standardIntroStepView(step: step, stepIndex: stepIndex)
        }
    }

    /// Helper to determine if a step is an outro step (for visual styling)
    private func isOutroStep(_ step: InspectConfig.IntroStep) -> Bool {
        step.stepType == "outro"
    }

    /// Helper to check if we can go back from a given step
    private func canGoBack(fromStepIndex stepIndex: Int) -> Bool {
        stepIndex > 0
    }

    // MARK: - Installation Step View (Modular Architecture)

    /// Renders an installation progress step using InstallationProgressModule
    @ViewBuilder
    private func installationStepView(step: InspectConfig.IntroStep, stepIndex: Int) -> some View {
        let canGoBackFromStep = canGoBack(fromStepIndex: stepIndex)
        let continueText = step.continueButtonText ?? "Continue"
        let backText = mdmOverrides?.button2Text ?? step.backButtonText ?? "Back"

        // Convert step items to InstallationItemData with monitoring status
        let installationData: [InstallationItemData] = (step.items ?? []).map { item in
            let status = monitoringService.itemStatuses[item.id] ?? .pending
            let progress = monitoringService.progressValues[item.id]
            var message = monitoringService.statusMessages[item.id]

            // Add bundle info for completed items if configured
            if status == .completed, let bundleInfo = inspectState.getBundleInfoForItem(item) {
                message = bundleInfo
            }

            return InstallationItemData(from: item, status: status, progress: progress, statusMessage: message)
        }

        // Determine layout from config
        let layout: InstallationLayout = {
            switch step.installationLayout?.lowercased() {
            case "list": return .list
            case "grid": return .grid
            case "cards": return .cards
            default: return .cards
            }
        }()

        // Check if all items are completed for auto-advance
        let allCompleted = !installationData.isEmpty && installationData.allSatisfy { $0.status == .completed }
        let anyFailed = installationData.contains { if case .failed = $0.status { return true } else { return false } }

        IntroStepContainer(
            accentColor: primaryColor,
            accentBorderHeight: 4,
            showProgressDots: step.showProgressDots ?? false,
            currentStep: stepIndex,
            totalSteps: totalSteps,
            footerConfig: IntroStepContainer.IntroFooterConfig(
                logoPath: effectiveLogoPath,
                logoMaxWidth: config?.logoConfig?.maxWidth ?? 36,
                logoMaxHeight: config?.logoConfig?.maxHeight ?? 36,
                footerText: effectiveFooterText,
                backButtonText: backText,
                continueButtonText: allCompleted ? (anyFailed ? "Continue Anyway" : continueText) : continueText,
                showBackButton: (step.showBackButton ?? true) && canGoBackFromStep,
                onBack: canGoBackFromStep ? { goToPreviousStep() } : nil,
                onContinue: { goToNextStep() },
                continueDisabled: false  // Always allow skipping installation steps
            )
        ) {
            VStack(spacing: 16) {
                // Title
                if let title = step.title {
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 24)
                }

                // Subtitle or processing message
                if let subtitle = step.subtitle ?? step.processingMessage {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                // Installation progress display in ScrollView
                // Note: We access monitoringService.itemStatuses directly here to ensure
                // SwiftUI observes changes and re-renders when statuses update
                ScrollView {
                    InstallationProgressView(
                        items: (step.items ?? []).map { item in
                            let status = monitoringService.itemStatuses[item.id] ?? .pending
                            let progress = monitoringService.progressValues[item.id]
                            var message = monitoringService.statusMessages[item.id]

                            // Add bundle info for completed items if configured
                            if status == .completed, let bundleInfo = inspectState.getBundleInfoForItem(item) {
                                message = bundleInfo
                            }

                            return InstallationItemData(from: item, status: status, progress: progress, statusMessage: message)
                        },
                        configuration: InstallationProgressConfiguration(
                            layout: layout,
                            highlightColor: primaryColor,
                            scaleFactor: step.installationScale ?? 0.75,
                            showSummary: true,
                            showIcons: true,
                            showProgressBars: true,
                            columns: 2
                        )
                    )
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    // Force view identity based on status count to ensure updates
                    .id(monitoringService.itemStatuses.values.filter { $0 == .completed }.count)
                }
            }
        }
        .onAppear {
            startInstallationMonitoring(for: step)
        }
        .onDisappear {
            stopInstallationMonitoring()
        }
        .onChange(of: allCompleted) { completed in
            // Auto-advance when all items complete (if configured)
            if completed && (step.autoAdvanceOnComplete ?? false) {
                writeLog("Preset11: All installation items completed, auto-advancing", logLevel: .info)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    goToNextStep()
                }
            }
        }
    }

    /// Start monitoring for installation step items
    private func startInstallationMonitoring(for step: InspectConfig.IntroStep) {
        guard let items = step.items, !items.isEmpty else {
            writeLog("Preset11: No items to monitor for installation step", logLevel: .debug)
            return
        }

        writeLog("Preset11: Starting installation monitoring for \(items.count) items", logLevel: .info)
        monitoringService.startMonitoring(items: items)

        // Also start log monitoring if configured at the top level
        if let config = config {
            LogMonitorService.shared.setItems(items)
            LogMonitorService.shared.configure(with: config)
            writeLog("Preset11: Configured log monitoring", logLevel: .info)
        }
    }

    /// Stop all installation monitoring
    private func stopInstallationMonitoring() {
        monitoringService.stopMonitoring()
        LogMonitorService.shared.stop()
        writeLog("Preset11: Stopped installation monitoring", logLevel: .debug)
    }

    /// Dedicated full-screen wallpaper picker view using existing WallpaperPickerView
    @ViewBuilder
    private func wallpaperStepView(step: InspectConfig.IntroStep, stepIndex: Int) -> some View {
        let canGoBackFromStep = canGoBack(fromStepIndex: stepIndex)
        let continueText = step.continueButtonText ?? "Continue"
        let backText = mdmOverrides?.button2Text ?? step.backButtonText ?? "Back"

        VStack(spacing: 0) {
            // Accent border
            Rectangle()
                .fill(primaryColor)
                .frame(height: 4)

            // Content area with wallpaper picker
            VStack(spacing: 0) {
                Spacer(minLength: 24)

                // Title area - centered
                VStack(spacing: 12) {
                    if let title = step.title {
                        Text(title)
                            .font(.system(size: 28, weight: .bold))
                            .multilineTextAlignment(.center)
                    }
                    if let subtitle = step.subtitle {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)

                Spacer(minLength: 24)

                // Wallpaper picker - centered with proper padding
                // Map config string to layout enum (default to grid for reduced scrolling)
                let layoutMode: WallpaperPickerView.WallpaperLayout = {
                    switch step.wallpaperLayout?.lowercased() {
                    case "row": return .row
                    case "categories": return .categories
                    default: return .grid  // Default to grid for minimal scrolling
                    }
                }()

                ScrollView(.vertical, showsIndicators: false) {
                    WallpaperPickerView(
                        categories: step.wallpaperCategories ?? [],
                        columns: 4,
                        imageFit: "fill",
                        thumbnailHeight: step.wallpaperThumbnailHeight ?? 120,
                        selectionKey: step.wallpaperSelectionKey ?? step.id,
                        showPath: step.wallpaperShowPath ?? false,
                        confirmButtonText: step.wallpaperConfirmButton,
                        multiSelectCount: step.wallpaperMultiSelect ?? 1,
                        scaleFactor: 1.0,
                        centered: true,
                        layout: layoutMode,
                        inspectState: inspectState,
                        itemId: step.id
                    )
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 40)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Footer with navigation
            IntroFooterView(
                logoPath: effectiveLogoPath,
                logoMaxWidth: config?.logoConfig?.maxWidth ?? 36,
                logoMaxHeight: config?.logoConfig?.maxHeight ?? 36,
                footerText: effectiveFooterText,
                backButtonText: backText,
                continueButtonText: continueText,
                accentColor: primaryColor,
                showBackButton: (step.showBackButton ?? true) && canGoBackFromStep,
                onBack: canGoBackFromStep ? { goToPreviousStep() } : nil,
                onContinue: { goToNextStep() }
            )
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Processing Step View (Countdown Timer)

    /// Processing step with countdown timer and visual feedback
    /// Shows countdown during processing, then result banner with continue button after completion
    @ViewBuilder
    private func processingStepView(step: InspectConfig.IntroStep, stepIndex: Int) -> some View {
        let canGoBackFromStep = canGoBack(fromStepIndex: stepIndex)
        let backText = mdmOverrides?.button2Text ?? step.backButtonText ?? "Back"
        let isCompleted = completedProcessingSteps.contains(step.id)
        let hasFailed = failedSteps[step.id] != nil

        VStack(spacing: 0) {
            // Accent border
            Rectangle()
                .fill(primaryColor)
                .frame(height: 4)

            // Content area
            VStack(spacing: 24) {
                Spacer()

                // Hero Image (optional) - check for override first
                if let heroImage = heroImageOverrides[step.id] ?? step.heroImage {
                    IntroHeroImage(
                        path: heroImage,
                        shape: step.heroImageShape ?? "circle",
                        size: step.heroImageSize ?? 150,
                        accentColor: heroImageColor(step: step),
                        sfSymbolColor: step.heroImageSFSymbolColor.map { Color(hex: $0) },
                        sfSymbolWeight: sfSymbolWeight(from: step.heroImageSFSymbolWeight),
                        basePath: effectiveIconBasePath
                    )
                }

                // Title
                if let title = step.title {
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                }

                // Subtitle
                if let subtitle = step.subtitle {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if isCompleted {
                    // COMPLETED STATE: Show result banner
                    processingResultBanner(for: step, hasFailed: hasFailed)
                } else {
                    // PROCESSING STATE: Show countdown ring and message
                    countdownRing(for: step)

                    // Processing message with {countdown} substitution
                    if let message = step.processingMessage {
                        let displayMessage = message.replacingOccurrences(
                            of: "{countdown}",
                            with: "\(processingCountdown)"
                        )
                        Text(displayMessage)
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    // Override buttons (progressive escalation)
                    overrideButtons(for: step, stepIndex: stepIndex)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)

            // Footer - show continue button when completed, hide during processing
            IntroFooterView(
                logoPath: effectiveLogoPath,
                logoMaxWidth: config?.logoConfig?.maxWidth ?? 36,
                logoMaxHeight: config?.logoConfig?.maxHeight ?? 36,
                footerText: effectiveFooterText,
                backButtonText: backText,
                continueButtonText: isCompleted ? (hasFailed ? "Continue Anyway" : (step.continueButtonText ?? "Continue")) : "",
                accentColor: primaryColor,
                showBackButton: (step.showBackButton ?? false) && canGoBackFromStep,
                onBack: canGoBackFromStep ? { stopProcessingCountdown(); goToPreviousStep() } : nil,
                onContinue: { goToNextStep() },
                continueDisabled: !isCompleted  // Enable continue button only when completed
            )
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            // Only start processing if not already completed
            if !completedProcessingSteps.contains(step.id) {
                // Output step_started event for caller scripts to detect
                print("[PRESET11_PROCESSING] step_started: \(step.id)")
                writeLog("Preset11: Processing step started: '\(step.id)'", logLevel: .info)

                startProcessingCountdown(for: step, stepIndex: stepIndex)

                // Start plist monitoring for completion triggers (parity with Preset6)
                // This allows external processes to signal completion via plist updates
                introStepMonitor.startMonitoring(step: step) { [self] triggerStepId, triggerResult in
                    writeLog("Preset11: Plist monitor triggered for processing step '\(triggerStepId)' with result: \(triggerResult)", logLevel: .info)
                    // Convert CompletionTriggerResult to CompletionResult (InspectCompletionResult)
                    let completionResult: CompletionResult
                    switch triggerResult {
                    case .success(let message):
                        completionResult = .success(message: message)
                    case .failure(let message):
                        completionResult = .failure(message: message)
                    }
                    handleCompletionTrigger(stepId: triggerStepId, result: completionResult)
                }
            }
        }
        .onDisappear {
            stopProcessingCountdown()
            introStepMonitor.stopMonitoring()
        }
        .overlay {
            // Override picker overlay
            if showOverridePicker {
                ZStack {
                    // Dimmed background
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            showOverridePicker = false
                        }

                    // Picker sheet
                    overridePickerSheet()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showOverridePicker)
        .animation(.easeInOut(duration: 0.3), value: isCompleted)
    }

    /// Result banner shown after processing completes (success, failure, or skipped)
    @ViewBuilder
    private func processingResultBanner(for step: InspectConfig.IntroStep, hasFailed: Bool) -> some View {
        let wasSkipped = skippedSteps.contains(step.id)

        if hasFailed {
            // Failure banner
            HStack(spacing: 12) {
                StatusIconView(.failure, size: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(step.failureMessage ?? "Step Failed")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)

                    if let reason = failedSteps[step.id], !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(16)
            .background(Color.failureBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.semanticFailure.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        } else if wasSkipped {
            // Skipped banner
            HStack(spacing: 12) {
                StatusIconView(.warning, size: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Step Skipped")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Spacer()
            }
            .padding(16)
            .background(Color.warningBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.semanticWarning.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        } else {
            // Success banner
            HStack(spacing: 12) {
                StatusIconView(.success, size: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(step.successMessage ?? "Step Completed")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Spacer()
            }
            .padding(16)
            .background(Color.successBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.semanticSuccess.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
    }

    /// Countdown ring visualization for processing steps
    @ViewBuilder
    private func countdownRing(for step: InspectConfig.IntroStep) -> some View {
        let duration = step.processingDuration ?? 5

        if case .countdown(_, let remaining, _) = processingState {
            ZStack {
                // Background circle
                Circle()
                    .stroke(primaryColor.opacity(0.3), lineWidth: 4)
                    .frame(width: 100, height: 100)

                // Progress ring
                Circle()
                    .trim(from: 0, to: CGFloat(remaining) / CGFloat(duration))
                    .stroke(primaryColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1.0), value: remaining)

                // Center number
                Text("\(max(0, remaining))")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryColor)
            }
            .padding(.vertical, 16)
        } else if case .waiting = processingState {
            // Waiting state - show spinner
            ProgressView()
                .scaleEffect(2)
                .padding(.vertical, 32)
        } else {
            // Initial state before countdown starts - show full ring
            ZStack {
                Circle()
                    .stroke(primaryColor.opacity(0.3), lineWidth: 4)
                    .frame(width: 100, height: 100)

                Circle()
                    .trim(from: 0, to: 1.0)
                    .stroke(primaryColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))

                Text("\(duration)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryColor)
            }
            .padding(.vertical, 16)
        }
    }

    /// Warning level banner shown during long waits (parity with Preset6)
    @ViewBuilder
    private func warningLevelBanner() -> some View {
        if case .warning = currentOverrideLevel {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)

                Text("This step is taking longer than expected...")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }
            .padding(12)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )
            .padding(.top, 8)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    /// Override buttons for processing steps (progressive escalation using shared OverrideLevel)
    @ViewBuilder
    private func overrideButtons(for step: InspectConfig.IntroStep, stepIndex: Int) -> some View {
        let allowOverride = step.allowOverride ?? false
        let overrideText = step.overrideButtonText ?? "Skip"

        if allowOverride {
            // Use Group to ensure SwiftUI observes changes
            VStack(spacing: 8) {
                // Warning banner at .warning level (10-15s)
                warningLevelBanner()

                // Override buttons based on shared OverrideLevel
                Group {
                    switch currentOverrideLevel {
                    case .large:
                        // Large override button (60+ seconds)
                        Button(action: {
                            pendingOverrideStepIndex = stepIndex
                            showOverridePicker = true
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.forward.circle.fill")
                                    .font(.system(size: 14))
                                Text(overrideText)
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.orange)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                    case .small:
                        // Small override link (15-60 seconds)
                        Button(action: {
                            pendingOverrideStepIndex = stepIndex
                            showOverridePicker = true
                        }) {
                            Text(overrideText)
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                                .underline()
                        }
                        .buttonStyle(.plain)

                    case .warning:
                        // Warning level (10-15s) - no button yet, just the warning banner above
                        EmptyView()

                    case .none:
                        // No override available yet (0-10s)
                        EmptyView()
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: currentOverrideLevel)
            .padding(.top, 8)
        }
    }

    /// Override result picker sheet
    @ViewBuilder
    private func overridePickerSheet() -> some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)

                Text("Skip This Step?")
                    .font(.system(size: 18, weight: .semibold))

                Text("Choose how to record this step's result")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)

            Divider()

            // Options
            VStack(spacing: 12) {
                // Mark as Success
                Button(action: {
                    // Get the step before closing (linear step model)
                    let step = allSteps[safe: pendingOverrideStepIndex]
                    let stepId = step?.id ?? "unknown"
                    lastOverrideResult = "success"
                    lastOverrideStepId = stepId
                    // Store in userValues for access in templates
                    inspectState.userValues["overrideResult"] = "success"
                    inspectState.userValues["overrideStepId"] = stepId
                    showOverridePicker = false
                    stopProcessingCountdown()
                    // Mark as completed with success result - user clicks continue to advance
                    if let step = step {
                        markProcessingCompleted(step: step, result: .success)
                    }
                }) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color.semanticSuccess)
                        Text("Mark as Completed")
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.successBackground)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // Mark as Failed
                Button(action: {
                    let step = allSteps[safe: pendingOverrideStepIndex]
                    let stepId = step?.id ?? "unknown"
                    lastOverrideResult = "failed"
                    lastOverrideStepId = stepId
                    inspectState.userValues["overrideResult"] = "failed"
                    inspectState.userValues["overrideStepId"] = stepId
                    showOverridePicker = false
                    stopProcessingCountdown()
                    // Mark as completed with failure result - user clicks continue anyway to advance
                    if let step = step {
                        markProcessingCompleted(step: step, result: .failure(reason: step.failureMessage ?? "Marked as failed by user"))
                    }
                }) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color.semanticFailure)
                        Text("Mark as Failed")
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.failureBackground)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // Skip without status
                Button(action: {
                    let step = allSteps[safe: pendingOverrideStepIndex]
                    showOverridePicker = false
                    stopProcessingCountdown()
                    // Mark as skipped - user clicks continue to advance
                    if let step = step {
                        markProcessingCompleted(step: step, result: .skipped)
                    }
                }) {
                    HStack {
                        Image(systemName: "forward.fill")
                            .foregroundColor(.orange)
                        Text("Skip (No Status)")
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            Divider()

            // Cancel button
            Button(action: {
                showOverridePicker = false
            }) {
                Text("Cancel")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
        }
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 20)
    }

    /// Starts the countdown timer for a processing step
    private func startProcessingCountdown(for step: InspectConfig.IntroStep, stepIndex: Int) {
        guard let duration = step.processingDuration, duration > 0 else {
            // No duration - mark as completed immediately (user clicks continue to advance)
            markProcessingCompleted(step: step, result: .success)
            return
        }

        // Check if step has waitForExternalTrigger - log warning like Preset6
        let hasWaitForTrigger = step.waitForExternalTrigger == true
        let mode = step.processingMode ?? "simple"

        if mode == "progressive" && !hasWaitForTrigger && step.autoResult == nil {
            writeLog("⚠️  WARNING: Step '\(step.id)' has processingMode='progressive' but waitForExternalTrigger is not set.", logLevel: .error)
            writeLog("    Step may complete unexpectedly. Recommended: Add \"waitForExternalTrigger\": true to config.", logLevel: .error)
        }

        processingCountdown = duration
        processingWaitElapsed = 0  // Reset wait elapsed for override tracking
        processingState = .countdown(stepId: step.id, remaining: duration, waitElapsed: 0)

        processingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] timer in
            DispatchQueue.main.async {
                // Always increment wait elapsed for override escalation
                self.processingWaitElapsed += 1

                if case .countdown(let stepId, let remaining, let elapsed) = self.processingState, remaining > 0 {
                    // Check if countdown is about to complete (remaining == 1)
                    if remaining == 1 {
                        // Output countdown_complete event for external scripts
                        print("[PRESET11_PROCESSING] countdown_complete: \(stepId)")
                        writeLog("Preset11: Countdown complete for step '\(stepId)'", logLevel: .info)

                        // Determine next state based on waitForExternalTrigger
                        let waitForTrigger = step.waitForExternalTrigger == true
                        let isProgressiveMode = step.processingMode == "progressive"

                        if waitForTrigger || isProgressiveMode {
                            // Transition to waiting state - wait for external trigger
                            timer.invalidate()
                            self.processingTimer = nil
                            self.processingCountdown = 0
                            self.processingState = .waiting(stepId: stepId, waitElapsed: 0)
                            writeLog("Preset11: Step '\(stepId)' transitioned to waiting state (waitForExternalTrigger=\(waitForTrigger), progressive=\(isProgressiveMode))", logLevel: .info)
                            // Restart timer for waiting state
                            self.startWaitingTimer(for: step, stepIndex: stepIndex)
                        } else {
                            // Simple mode without waitForExternalTrigger - complete immediately
                            timer.invalidate()
                            self.processingTimer = nil
                            self.processingCountdown = 0
                            self.processingState = .idle

                            // Check autoResult setting (for forced failure demos)
                            let autoResult = step.autoResult ?? "success"
                            if autoResult == "failure" {
                                self.markProcessingCompleted(step: step, result: .failure(reason: step.failureMessage ?? "Operation failed"))
                            } else {
                                self.markProcessingCompleted(step: step, result: .success)
                            }

                            // Auto-advance only if explicitly requested
                            if step.autoAdvance == true {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    self.goToNextStep()
                                }
                            }
                        }
                    } else {
                        // Continue countdown
                        self.processingCountdown = remaining - 1
                        self.processingState = .countdown(stepId: stepId, remaining: remaining - 1, waitElapsed: elapsed + 1)
                    }
                } else if case .waiting(let stepId, let waitElapsed) = self.processingState {
                    // In waiting state - keep incrementing wait elapsed
                    self.processingState = .waiting(stepId: stepId, waitElapsed: waitElapsed + 1)
                } else {
                    // Fallback: countdown finished unexpectedly
                    timer.invalidate()
                    self.processingTimer = nil
                    self.processingCountdown = 0
                    self.processingState = .idle
                    self.markProcessingCompleted(step: step, result: .success)
                }
            }
        }
    }

    // MARK: - Completion Handling (Shared Pattern with Preset6)

    /// Computed property for current override level based on wait elapsed
    private var currentOverrideLevel: OverrideLevel {
        OverrideLevel.level(for: processingWaitElapsed)
    }

    /// Unified handler for step completion triggers (success/failure/warning)
    /// This is the central completion handler like Preset6's handleCompletionTrigger
    private func handleCompletionTrigger(stepId: String, result: CompletionResult) {
        // Find the step to get configuration
        let step = introSteps.first(where: { $0.id == stepId }) ?? outroSteps.first(where: { $0.id == stepId })
        guard step != nil else {
            writeLog("Preset11: Cannot handle completion for unknown step: \(stepId)", logLevel: .error)
            return
        }

        // Stop processing timer
        stopProcessingCountdown()

        // Mark as completed
        completedProcessingSteps.insert(stepId)

        // Handle result-specific logic
        switch result {
        case .success(let message):
            failedSteps.removeValue(forKey: stepId)
            skippedSteps.remove(stepId)
            inspectState.userValues["processingResult_\(stepId)"] = "success"
            writeLog("Preset11: Processing completed with success for '\(stepId)': \(message ?? "No message")", logLevel: .info)
            print("[PRESET11_PROCESSING] processing_result: \(stepId) = success")

        case .warning(let message):
            failedSteps.removeValue(forKey: stepId)
            skippedSteps.remove(stepId)
            inspectState.userValues["processingResult_\(stepId)"] = "warning"
            writeLog("Preset11: Processing completed with warning for '\(stepId)': \(message ?? "No message")", logLevel: .info)
            print("[PRESET11_PROCESSING] processing_result: \(stepId) = warning")

        case .failure(let message):
            failedSteps[stepId] = message ?? "Step failed"
            skippedSteps.remove(stepId)
            inspectState.userValues["processingResult_\(stepId)"] = "failed"
            writeLog("Preset11: Processing completed with failure for '\(stepId)': \(message ?? "No reason")", logLevel: .info)
            print("[PRESET11_PROCESSING] processing_result: \(stepId) = failed")

        case .cancelled:
            failedSteps.removeValue(forKey: stepId)
            skippedSteps.insert(stepId)
            inspectState.userValues["processingResult_\(stepId)"] = "skipped"
            writeLog("Preset11: Processing cancelled/skipped for '\(stepId)'", logLevel: .info)
            print("[PRESET11_PROCESSING] processing_result: \(stepId) = skipped")
        }
    }

    /// Legacy wrapper for backward compatibility with existing code
    /// Maps old ProcessingResult-style calls to the new CompletionResult-based handler
    private func markProcessingCompleted(step: InspectConfig.IntroStep, result: LegacyProcessingResult) {
        switch result {
        case .success:
            handleCompletionTrigger(stepId: step.id, result: .success(message: step.successMessage))
        case .failure(let reason):
            handleCompletionTrigger(stepId: step.id, result: .failure(message: reason))
        case .skipped:
            handleCompletionTrigger(stepId: step.id, result: .cancelled)
        }
    }

    /// Legacy processing result enum for backward compatibility
    private enum LegacyProcessingResult {
        case success
        case failure(reason: String)
        case skipped
    }

    /// Starts a timer for waiting state (after countdown completes in progressive mode)
    private func startWaitingTimer(for step: InspectConfig.IntroStep, stepIndex: Int) {
        processingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] timer in
            DispatchQueue.main.async {
                self.processingWaitElapsed += 1
                if case .waiting(let stepId, let waitElapsed) = self.processingState {
                    self.processingState = .waiting(stepId: stepId, waitElapsed: waitElapsed + 1)
                }
            }
        }
    }

    /// Stops and cleans up the processing countdown timer
    private func stopProcessingCountdown() {
        processingTimer?.invalidate()
        processingTimer = nil
        processingCountdown = 0
        processingWaitElapsed = 0
        processingState = .idle
    }

    /// Standard intro step with hero image, title, content
    @ViewBuilder
    private func standardIntroStepView(step: InspectConfig.IntroStep, stepIndex: Int) -> some View {
        let isOutro = isOutroStep(step)
        let canGoBackFromStep = canGoBack(fromStepIndex: stepIndex)
        let isLastStep = stepIndex == totalSteps - 1

        // Determine button text: MDM > step config > default
        let continueText: String = {
            if isOutro {
                return mdmOverrides?.outroButtonText ?? step.continueButtonText ?? (isLastStep ? "Finish" : "Continue")
            } else {
                return mdmOverrides?.introButtonText ?? step.continueButtonText ?? "Continue"
            }
        }()

        // Back button uses MDM button2 for consistency
        let backText = mdmOverrides?.button2Text ?? step.backButtonText ?? "Back"

        IntroStepContainer(
            accentColor: primaryColor,
            accentBorderHeight: 4,
            showProgressDots: step.showProgressDots ?? false,
            currentStep: stepIndex,
            totalSteps: totalSteps,
            footerConfig: IntroStepContainer.IntroFooterConfig(
                logoPath: effectiveLogoPath,
                logoMaxWidth: config?.logoConfig?.maxWidth ?? 36,
                logoMaxHeight: config?.logoConfig?.maxHeight ?? 36,
                footerText: effectiveFooterText,
                backButtonText: backText,
                continueButtonText: continueText,
                showBackButton: (step.showBackButton ?? true) && canGoBackFromStep,
                onBack: canGoBackFromStep ? { goToPreviousStep() } : nil,
                onContinue: { goToNextStep() },
                continueDisabled: !allRequiredFieldsFilled(step: step)
            )
        ) {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 20)

                    // Hero Image - check for override first
                    if let heroImage = heroImageOverrides[step.id] ?? step.heroImage {
                        IntroHeroImage(
                            path: heroImage,
                            shape: step.heroImageShape ?? "circle",
                            size: step.heroImageSize ?? 200,
                            accentColor: heroImageColor(step: step),
                            sfSymbolColor: step.heroImageSFSymbolColor.map { Color(hex: $0) },
                            sfSymbolWeight: sfSymbolWeight(from: step.heroImageSFSymbolWeight),
                            basePath: effectiveIconBasePath
                        )
                    }

                    // Title - MDM override for intro/outro screens
                    let displayTitle: String? = {
                        if isOutro, let mdmTitle = mdmOverrides?.outroTitle {
                            return mdmTitle
                        } else if !isOutro, let mdmTitle = mdmOverrides?.introTitle {
                            return mdmTitle
                        }
                        return step.title
                    }()

                    if let title = displayTitle {
                        HStack(spacing: 8) {
                            Text(title)
                                .font(.system(size: 28, weight: .bold))
                                .multilineTextAlignment(.center)

                            // Step overlay info button (if configured)
                            stepInfoButton(for: step)
                        }
                        .padding(.horizontal, 40)
                    }

                    // Subtitle
                    if let subtitle = step.subtitle {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }

                    // Rich content
                    if let content = step.content {
                        VStack(spacing: 12) {
                            ForEach(content.indices, id: \.self) { index in
                                introContentBlock(content[index], blockIndex: index)
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.top, 16)
                        // Force re-render when dynamic state changes
                        .id("content-\(step.id)-\(dynamicContentUpdateCounter)")
                    }

                    // Media carousel (for instruction videos, GIFs, images)
                    if let mediaItems = step.mediaItems, !mediaItems.isEmpty {
                        IntroMediaCarousel(
                            items: mediaItems,
                            height: step.mediaHeight ?? 400,
                            autoplay: step.mediaAutoplay ?? true,
                            showArrows: step.mediaShowArrows ?? true,
                            showDots: step.mediaShowDots ?? true,
                            accentColor: accentColor
                        )
                        .padding(.horizontal, 40)
                        .padding(.top, 16)
                    }

                    // Grid picker (for wallpaper-style selection)
                    if let gridItems = step.gridItems, !gridItems.isEmpty {
                        let key = step.gridSelectionKey ?? step.id
                        let binding = Binding<Set<String>>(
                            get: { gridSelections[key] ?? [] },
                            set: { gridSelections[key] = $0 }
                        )

                        IntroGridPicker(
                            items: gridItems.map { IntroGridItem(
                                id: $0.id,
                                imagePath: $0.imagePath,
                                sfSymbol: $0.sfSymbol,
                                title: $0.title,
                                subtitle: $0.description ?? $0.subtitle,  // description takes precedence
                                value: $0.value ?? $0.id  // value defaults to id for preference writing
                            ) },
                            columns: step.gridColumns ?? 3,
                            selectionMode: step.gridSelectionMode ?? "single",
                            selectedIds: binding,
                            accentColor: accentColor
                        )
                        .padding(.horizontal, 24)
                    }

                    // Note: Wallpaper picker is handled by dedicated wallpaperStepView

                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
        .onAppear {
            initializeFormDefaults(for: step)
            // Start plist monitoring if this step has monitors configured
            // Pass completion trigger callback for auto-advance support
            introStepMonitor.startMonitoring(step: step) { [self] triggerStepId, result in
                // Only auto-advance if configured and trigger result is success
                guard step.autoAdvanceOnComplete == true else {
                    writeLog("Preset11: Completion trigger fired for step '\(triggerStepId)' but autoAdvanceOnComplete is not enabled", logLevel: .debug)
                    return
                }

                if case .success = result {
                    writeLog("Preset11: Auto-advancing from step '\(triggerStepId)' due to completion trigger", logLevel: .info)
                    goToNextStep()
                }
            }
        }
    }

    /// Renders a guidance content block for intro screens
    /// - Parameters:
    ///   - block: The content block configuration
    ///   - blockIndex: Index of the block in the content array (for dynamic updates)
    @ViewBuilder
    private func introContentBlock(_ block: InspectConfig.GuidanceContent, blockIndex: Int = 0) -> some View {
        // Get dynamic state for this block index (if monitoring is active)
        let dynamicState = introStepMonitor.stateForBlock(blockIndex)

        switch block.type {
        // MARK: - Delegated Content Types (rendered by GuidanceContentView with accent color)
        case "text", "bullets", "info", "warning", "success", "arrow",
             "highlight", "label-value", "explainer", "image", "video", "button":
            centeredContentContainer {
                GuidanceContentView(
                    contentBlocks: [block],
                    scaleFactor: 1.0,
                    iconBasePath: iconBasePathOverride ?? inspectState.uiConfiguration.iconBasePath,
                    inspectState: inspectState,
                    itemId: "intro-block-\(blockIndex)",
                    accentColor: primaryColor,
                    contentAlignment: .center
                )
            }

        case "phase-tracker":
            introPhaseTrackerView(block: block, blockIndex: blockIndex, dynamicState: dynamicState)

        case "status-badge":
            introStatusBadgeView(block: block, blockIndex: blockIndex, dynamicState: dynamicState)

        // MARK: Form Elements

        case "checkbox":
            introCheckboxView(block: block)

        case "toggle":
            introToggleView(block: block)

        case "dropdown":
            introDropdownView(block: block)

        case "radio":
            introRadioView(block: block)

        case "textfield":
            introTextfieldView(block: block)

        case "slider":
            introSliderView(block: block)

        // MARK: - Shared Content Renderer Types (Tables, Status, Media)

        case "feature-table":
            FeatureTableBlock(block: block, accentColor: primaryColor, maxWidth: 420)

        case "comparison-table":
            ComparisonTableBlock(block: block, accentColor: primaryColor, maxWidth: 420, dynamicState: dynamicState)
                .id("comparison-\(blockIndex)-\(dynamicState?.actual ?? "")")

        case "compliance-card":
            // Check if block.content specifies a category name for auto-population from plistSources
            if let categoryName = block.content, !categoryName.isEmpty,
               let category = complianceService.category(named: categoryName) {
                // Auto-populate from aggregated plist data using dynamicState
                ComplianceCardBlock(
                    block: block,
                    accentColor: primaryColor,
                    maxWidth: 420,
                    dynamicState: makeComplianceState(passed: category.passed, total: category.total, content: complianceService.checkDetails(for: categoryName, maxItems: 500))
                )
                .id("compliance-\(blockIndex)-\(category.passed)-\(category.total)")
            } else {
                // Use block as-is with optional dynamic state from plistMonitors
                ComplianceCardBlock(block: block, accentColor: primaryColor, maxWidth: 420, dynamicState: dynamicState)
                    .id("compliance-\(blockIndex)-\(dynamicState?.passed ?? 0)-\(dynamicState?.total ?? 0)")
            }

        case "compliance-header":
            // Check if we should use aggregated compliance data
            if !complianceService.categories.isEmpty {
                // Auto-populate from aggregated plist data
                ComplianceDashboardHeaderBlock(
                    block: block,
                    accentColor: primaryColor,
                    maxWidth: 420,
                    dynamicState: makeComplianceState(passed: complianceService.totalPassed, total: complianceService.totalChecks)
                )
                .id("compliance-header-\(blockIndex)-\(complianceService.totalPassed)-\(complianceService.totalChecks)")
            } else {
                // Use block as-is with optional dynamic state from plistMonitors
                ComplianceDashboardHeaderBlock(block: block, accentColor: primaryColor, maxWidth: 420, dynamicState: dynamicState)
                    .id("compliance-header-\(blockIndex)-\(dynamicState?.passed ?? 0)-\(dynamicState?.total ?? 0)")
            }

        case "progress-bar":
            ProgressBarBlock(block: block, accentColor: primaryColor, maxWidth: 420, dynamicState: dynamicState)
                .id("progress-\(blockIndex)-\(dynamicState?.progress ?? 0)")

        case "image-carousel":
            ImageCarouselBlock(block: block, accentColor: primaryColor, maxWidth: 420)

        case "compliance-details-button":
            // Button that opens comprehensive compliance details sheet
            ComplianceDetailsButtonBlock(
                block: block,
                accentColor: primaryColor,
                maxWidth: 420,
                complianceService: complianceService
            )

        default:
            // Delegate unhandled types to GuidanceContentView (handles webcontent, etc.)
            GuidanceContentView(
                contentBlocks: [block],
                scaleFactor: 1.0,
                iconBasePath: iconBasePathOverride ?? inspectState.uiConfiguration.iconBasePath,
                inspectState: inspectState,
                itemId: "intro-block-\(blockIndex)",
                accentColor: primaryColor,
                contentAlignment: .center
            )
        }
    }

    /// Phase tracker view (stepper-style progress indicator)
    @ViewBuilder
    private func introPhaseTrackerView(block: InspectConfig.GuidanceContent, blockIndex: Int = 0, dynamicState: DynamicContentState? = nil) -> some View {
        let phases = block.phases ?? []
        // Priority: dynamicState > phaseTrackerOverride > block config
        let effectivePhase = dynamicState?.currentPhase ?? phaseTrackerOverride ?? (block.currentPhase ?? 1)

        centeredContentContainer {
            if !phases.isEmpty {
                VStack(spacing: 8) {
                    if let label = block.label {
                        Text(label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 0) {
                        ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                            let phaseNumber = index + 1
                            let isCompleted = phaseNumber < effectivePhase
                            let isCurrent = phaseNumber == effectivePhase

                            // Phase circle
                            ZStack {
                                Circle()
                                    .fill(isCompleted ? Color.green : (isCurrent ? primaryColor : Color.secondary.opacity(0.3)))
                                    .frame(width: 28, height: 28)

                                if isCompleted {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                } else {
                                    Text("\(phaseNumber)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(isCurrent ? .white : .secondary)
                                }
                            }

                            // Connector line (except after last)
                            if index < phases.count - 1 {
                                Rectangle()
                                    .fill(phaseNumber < effectivePhase ? Color.green : Color.secondary.opacity(0.3))
                                    .frame(height: 2)
                                    .frame(maxWidth: 40)
                            }
                        }
                    }

                    // Phase labels
                    HStack(spacing: 0) {
                        ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                            Text(phase)
                                .font(.system(size: 11))
                                .foregroundStyle(index + 1 == effectivePhase ? .primary : .secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .id("phase-tracker-\(blockIndex)-\(effectivePhase)")
    }

    /// Status badge view
    @ViewBuilder
    private func introStatusBadgeView(block: InspectConfig.GuidanceContent, blockIndex: Int = 0, dynamicState: DynamicContentState? = nil) -> some View {
        // Priority: dynamicState > statusBadgeOverrides > block config
        let baseLabel = block.content ?? block.label ?? ""
        let label = dynamicState?.label ?? baseLabel
        let blockId = block.id ?? baseLabel  // Use id if available, otherwise label
        // Check for override by id first, then by label, then dynamic state, then config state
        let effectiveState = dynamicState?.state ?? statusBadgeOverrides[blockId] ?? statusBadgeOverrides[baseLabel] ?? block.state ?? "pending"
        let autoColor = block.autoColor ?? false

        let (autoIcon, color) = statusBadgeStyle(for: effectiveState, autoColor: autoColor)
        // Use custom icon if provided, otherwise fall back to auto-determined icon
        let icon = block.icon ?? autoIcon

        centeredContentContainer {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.system(size: 14))

                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)

                Spacer()

                Text(statusBadgeText(for: effectiveState))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.1))
                    .clipShape(Capsule())
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .id("status-badge-\(blockIndex)-\(effectiveState)-\(label)")
    }

    /// Get icon and color for status badge state
    private func statusBadgeStyle(for state: String, autoColor: Bool) -> (String, Color) {
        switch state {
        case "success", "completed", "enabled", "active":
            return ("checkmark.circle.fill", .semanticSuccess)
        case "fail", "failed", "error", "disabled":
            return ("xmark.circle.fill", .semanticFailure)
        case "downloading", "processing", "running":
            return ("arrow.down.circle.fill", .semanticInfo)
        case "warning", "pending":
            return ("exclamationmark.triangle.fill", .semanticWarning)
        default:
            return ("circle", .secondary)
        }
    }

    /// Get display text for status badge state
    private func statusBadgeText(for state: String) -> String {
        switch state {
        case "success", "completed":
            return "Completed"
        case "enabled":
            return "Enabled"
        case "active":
            return "Active"
        case "disabled":
            return "Disabled"
        case "fail", "failed", "error":
            return "Error"
        case "downloading", "processing", "running":
            return "Running..."
        case "warning":
            return "Warning"
        case "pending":
            return "Pending"
        default:
            return state.capitalized
        }
    }

    // MARK: - Form Element Views

    /// Shared container for consistent centered layout (content blocks and form fields)
    @ViewBuilder
    private func centeredContentContainer<Content: View>(
        maxWidth: CGFloat = 420,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }

    /// Shared form field container for consistent centered layout
    @ViewBuilder
    private func formFieldContainer<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        centeredContentContainer(content: content)
    }

    /// Checkbox form element view - clean native style
    @ViewBuilder
    private func introCheckboxView(block: InspectConfig.GuidanceContent) -> some View {
        let isChecked = formBoolBinding(for: block.id)
        let isRequired = block.required ?? false

        formFieldContainer {
            HStack(spacing: 8) {
                Toggle(isOn: isChecked) {
                    Text(block.content ?? "")
                        .font(.system(size: 14))
                }
                .toggleStyle(.checkbox)

                if isRequired {
                    Text("*")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12, weight: .medium))
                }

                if let helpText = block.helpText {
                    formHelpButton(helpText: helpText)
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    /// Toggle form element view - clean row style
    @ViewBuilder
    private func introToggleView(block: InspectConfig.GuidanceContent) -> some View {
        let isOn = formBoolBinding(for: block.id)
        let isRequired = block.required ?? false

        formFieldContainer {
            HStack(spacing: 8) {
                Text(block.label ?? block.content ?? "")
                    .font(.system(size: 14))

                if isRequired {
                    Text("*")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12, weight: .medium))
                }

                if let helpText = block.helpText {
                    formHelpButton(helpText: helpText)
                }

                Spacer()

                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Dropdown form element view - clean inline style
    @ViewBuilder
    private func introDropdownView(block: InspectConfig.GuidanceContent) -> some View {
        let selection = formBinding(for: block.id)
        let options = block.options ?? []
        let isRequired = block.required ?? false

        formFieldContainer {
            HStack(spacing: 8) {
                if let label = block.label {
                    Text(label)
                        .font(.system(size: 14))

                    if isRequired {
                        Text("*")
                            .foregroundStyle(.orange)
                            .font(.system(size: 12, weight: .medium))
                    }

                    if let helpText = block.helpText {
                        formHelpButton(helpText: helpText)
                    }
                }

                Spacer()

                Picker("", selection: selection) {
                    if selection.wrappedValue.isEmpty {
                        Text("Select...").tag("")
                    }
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 140)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onAppear {
            if let defaultValue = block.value, formValues[block.id ?? ""] == nil {
                formValues[block.id ?? ""] = defaultValue
            }
        }
    }

    /// Radio button form element view - vertical list with selection highlight
    @ViewBuilder
    private func introRadioView(block: InspectConfig.GuidanceContent) -> some View {
        let selection = formBinding(for: block.id)
        let options = block.options ?? []
        let isRequired = block.required ?? false

        formFieldContainer {
            VStack(alignment: .leading, spacing: 10) {
                // Label row
                if let label = block.label {
                    HStack(spacing: 4) {
                        Text(label)
                            .font(.system(size: 14, weight: .medium))
                        if isRequired {
                            Text("*")
                                .foregroundStyle(.orange)
                                .font(.system(size: 12, weight: .medium))
                        }
                        if let helpText = block.helpText {
                            formHelpButton(helpText: helpText)
                        }
                    }
                }

                // Radio options - vertical list
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(options, id: \.self) { option in
                        HStack(spacing: 10) {
                            Image(systemName: selection.wrappedValue == option ? "circle.inset.filled" : "circle")
                                .foregroundStyle(selection.wrappedValue == option ? primaryColor : .secondary)
                                .font(.system(size: 14))

                            Text(option)
                                .font(.system(size: 14))
                                .foregroundStyle(.primary)

                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selection.wrappedValue == option ? primaryColor.opacity(0.08) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                selection.wrappedValue = option
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if let defaultValue = block.value, formValues[block.id ?? ""] == nil {
                formValues[block.id ?? ""] = defaultValue
            }
        }
    }

    /// Textfield form element view - clean labeled input
    @ViewBuilder
    private func introTextfieldView(block: InspectConfig.GuidanceContent) -> some View {
        let text = formBinding(for: block.id)
        let isRequired = block.required ?? false
        let isSecure = block.secure ?? false

        formFieldContainer {
            VStack(alignment: .leading, spacing: 6) {
                // Label row
                if let label = block.label ?? block.content {
                    HStack(spacing: 4) {
                        Text(label)
                            .font(.system(size: 14, weight: .medium))
                        if isRequired {
                            Text("*")
                                .foregroundStyle(.orange)
                                .font(.system(size: 12, weight: .medium))
                        }
                        if let helpText = block.helpText {
                            formHelpButton(helpText: helpText)
                        }
                    }
                }

                // Text input
                if isSecure {
                    SecureField(block.placeholder ?? "", text: text)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField(block.placeholder ?? "", text: text)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            if let defaultValue = block.value, formValues[block.id ?? ""] == nil {
                formValues[block.id ?? ""] = defaultValue
            }
        }
    }

    /// Slider form element view - clean with value display
    @ViewBuilder
    private func introSliderView(block: InspectConfig.GuidanceContent) -> some View {
        let minVal = block.min ?? 0
        let maxVal = block.max ?? 100
        let step = block.step ?? 1
        let unit = block.unit ?? ""
        let isRequired = block.required ?? false

        let sliderValue = Binding<Double>(
            get: { Double(formValues[block.id ?? ""] ?? "\(minVal)") ?? minVal },
            set: { newValue in
                formValues[block.id ?? ""] = "\(Int(newValue))"
                if let fieldId = block.id {
                    preferencesService?.setValue(Int(newValue), forKey: fieldId)
                }
            }
        )

        formFieldContainer {
            VStack(alignment: .leading, spacing: 8) {
                // Label row with value
                HStack {
                    if let label = block.label {
                        HStack(spacing: 4) {
                            Text(label)
                                .font(.system(size: 14, weight: .medium))
                            if isRequired {
                                Text("*")
                                    .foregroundStyle(.orange)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            if let helpText = block.helpText {
                                formHelpButton(helpText: helpText)
                            }
                        }
                    }

                    Spacer()

                    Text("\(Int(sliderValue.wrappedValue))\(unit)")
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                // Slider
                Slider(value: sliderValue, in: minVal...maxVal, step: step)
                    .tint(primaryColor)
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            if let defaultValue = block.value, formValues[block.id ?? ""] == nil {
                formValues[block.id ?? ""] = defaultValue
            }
        }
    }

    /// Help button that opens a sliding sheet overlay (matching preset6 style)
    private struct FormHelpOverlayButton: View {
        let helpText: String
        let accentColor: Color
        @State private var showingOverlay = false

        var body: some View {
            Button(action: { showingOverlay = true }) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(helpText)
            .sheet(isPresented: $showingOverlay) {
                FormHelpOverlayContent(
                    helpText: helpText,
                    accentColor: accentColor,
                    onClose: { showingOverlay = false }
                )
            }
        }
    }

    /// The sliding help overlay content (matches DetailOverlayView style from preset6)
    private struct FormHelpOverlayContent: View {
        let helpText: String
        let accentColor: Color
        let onClose: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                // Header bar
                HStack(spacing: 12) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(accentColor.opacity(0.1))
                            .frame(width: 44, height: 44)
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(accentColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hilfe")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Informationen zu diesem Feld")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                // Content area
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(helpText)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(4)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(NSColor.textBackgroundColor))

                Divider()

                // Footer
                HStack {
                    Spacer()
                    Button("Verstanden") {
                        onClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(width: 420, height: 320)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    @ViewBuilder
    private func formHelpButton(helpText: String) -> some View {
        FormHelpOverlayButton(helpText: helpText, accentColor: primaryColor)
    }

    // MARK: - Floating Help Button (like preset6)

    /// Floating help button that opens the global detailOverlay
    @ViewBuilder
    private func floatingHelpButton(config: InspectConfig.HelpButtonConfig) -> some View {
        let position = config.position ?? "bottomRight"

        VStack {
            if position.contains("bottom") {
                Spacer()
            }

            HStack {
                if position.contains("Right") || position.contains("right") {
                    Spacer()
                }

                Button(action: { showGlobalHelpOverlay = true }) {
                    ZStack {
                        Circle()
                            .fill(primaryColor)
                            .frame(width: 48, height: 48)
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)

                        Image(systemName: config.icon ?? "questionmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .help(config.tooltip ?? "Help")

                if position.contains("Left") || position.contains("left") {
                    Spacer()
                }
            }

            if position.contains("top") || position.contains("Top") {
                Spacer()
            }
        }
        .padding(24)
    }

    // MARK: - Step Info Button (per-step overlay trigger)

    /// Info button for intro steps that have a stepOverlay configured
    @ViewBuilder
    private func stepInfoButton(for step: InspectConfig.IntroStep) -> some View {
        if let overlayConfig = step.stepOverlay, overlayConfig.enabled == true {
            Button(action: {
                currentStepOverlayConfig = overlayConfig
                showStepOverlay = true
            }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("More information")
        }
    }

    /// Get hero image accent color, with step override support
    private func heroImageColor(step: InspectConfig.IntroStep) -> Color {
        if let colorHex = step.heroImageSFSymbolColor {
            return Color(hex: colorHex)
        }
        return accentColor
    }

    /// Convert string weight to Font.Weight
    private func sfSymbolWeight(from string: String?) -> Font.Weight {
        switch string {
        case "bold": return .bold
        case "regular": return .regular
        default: return .medium
        }
    }

    // MARK: - Form State Management

    /// Create a binding for a form field value
    private func formBinding(for id: String?) -> Binding<String> {
        let key = id ?? ""
        return Binding(
            get: { formValues[key] ?? "" },
            set: { newValue in
                formValues[key] = newValue
                // Write to preferences immediately
                if let fieldId = id {
                    preferencesService?.setValue(newValue, forKey: fieldId)
                }
            }
        )
    }

    /// Create a binding for a boolean form field (checkbox/toggle)
    private func formBoolBinding(for id: String?) -> Binding<Bool> {
        let key = id ?? ""
        return Binding(
            get: { formValues[key] == "true" },
            set: { newValue in
                formValues[key] = newValue ? "true" : "false"
                // Write to preferences immediately
                if let fieldId = id {
                    preferencesService?.setValue(newValue, forKey: fieldId)
                }
            }
        )
    }

    /// Check if all required fields in a step are filled
    private func allRequiredFieldsFilled(step: InspectConfig.IntroStep) -> Bool {
        guard let content = step.content else { return true }

        let formTypes = ["checkbox", "dropdown", "radio", "toggle", "textfield"]
        let requiredFields = content.filter { block in
            block.required == true && formTypes.contains(block.type)
        }

        // If no required fields, validation passes
        guard !requiredFields.isEmpty else { return true }

        return requiredFields.allSatisfy { block in
            guard let fieldId = block.id else { return true }
            let value = formValues[fieldId] ?? ""

            switch block.type {
            case "checkbox", "toggle":
                // Required checkbox must be checked
                return value == "true"
            case "textfield":
                // Required textfield must have non-empty value
                return !value.trimmingCharacters(in: .whitespaces).isEmpty
            default:
                // Required dropdown/radio must have a selection
                return !value.isEmpty
            }
        }
    }

    /// Initialize form values from defaults in step content
    /// Supports inherit sources: plist:path:key, defaults:domain:key, env:NAME
    private func initializeFormDefaults(for step: InspectConfig.IntroStep) {
        guard let content = step.content else { return }

        for block in content {
            guard let fieldId = block.id else { continue }
            // Don't overwrite existing values (preserve state when going back/forward)
            guard formValues[fieldId] == nil else { continue }

            // 1. Try to resolve inherited value first
            if let inheritSpec = block.inherit {
                if let inherited = inspectState.resolveInheritValue(inheritSpec, basePath: config?.iconBasePath) {
                    formValues[fieldId] = inherited
                    writeLog("Preset11: Inherited value for '\(fieldId)' from '\(inheritSpec)' = '\(inherited)'", logLevel: .debug)
                    continue
                }
            }

            // 2. Fall back to default value
            if let defaultValue = block.value {
                formValues[fieldId] = defaultValue
            }
        }
    }

    // MARK: - Legacy Navigation (Removed)
    // The old phase-based navigation functions have been removed.
    // Use goToNextStep() and goToPreviousStep() for linear step navigation.

    // MARK: - Compliance State Helpers

    /// Create a DynamicContentState for compliance data
    private func makeComplianceState(passed: Int, total: Int, content: String? = nil) -> DynamicContentState {
        let state = DynamicContentState()
        state.passed = passed
        state.total = total
        if let content = content {
            state.content = content
        }
        return state
    }

    // MARK: - Output Functions

    /// Write step completion output
    private func writeStepOutput(stepId: String, action: String) {
        let output = "intro_step: \(stepId) - \(action)"
        writeLog("Preset11 Output: \(output)", logLevel: .info)
        // Also write to stdout for script consumption
        print(output)
    }

    /// Write user selection output
    private func writeSelectionOutput(key: String, selections: [String]) {
        let selectionsString = selections.joined(separator: ",")
        let output = "selection: \(key) = \(selectionsString)"
        writeLog("Preset11 Output: \(output)", logLevel: .info)
        print(output)
    }

    /// Write final summary output when dialog closes
    private func writeFinalOutput() {
        // Output all collected grid selections
        for (key, values) in gridSelections {
            let selectionsString = Array(values).joined(separator: ",")
            print("final_selection: \(key) = \(selectionsString)")
        }

        // Output all form values
        for (key, value) in formValues {
            print("form_value: \(key) = \(value)")
        }

        // Wallpaper selections are already written to interaction log by WallpaperPickerView
        // No need to duplicate output here

        print("preset11_complete: true")
    }

    // MARK: - Actions

    private func loadMDMOverrides() {
        // Load MDM branding overrides if appConfigSource is defined
        mdmOverrides = appConfigService.loadMDMOverrides(source: config?.appConfigSource)
    }

    private func setupPortal() {
        // Use effectivePortalConfig for per-step portal configuration
        if requiresAuth, let portalCfg = effectivePortalConfig {
            authService.configure(with: portalCfg)

            Task {
                do {
                    try await authService.authenticate()
                } catch {
                    writeLog("Preset11: Auth failed - \(error)", logLevel: .error)
                    await MainActor.run {
                        loadState = .error("Authentication failed")
                    }
                }
            }
        }
    }

    private func retryConnection() {
        loadState = .initializing
        showContent = false

        // Signal refresh request to calling script via interaction log
        // The script can respond by writing a new URL to portalURLFile
        inspectState.writeToInteractionLog("portal:refresh")
        writeLog("Preset11: Portal refresh requested", logLevel: .info)

        if requiresAuth {
            Task {
                do {
                    try await authService.refresh()
                } catch {
                    await MainActor.run {
                        loadState = .error("Refresh failed")
                    }
                }
            }
        }
    }

    private func refetch() {
        withAnimation(.linear(duration: 0.5)) {
            isRefetching = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isRefetching = false
        }

        // Trigger reload
        loadState = .loading
        showContent = false
    }

    private func handleButton1() {
        // Linear step model: if on a portal step and there are more steps, advance
        let portalCfg = effectivePortalConfig
        let selfServiceOnly = portalCfg?.selfServiceOnly ?? false

        // If in portal step and there are more steps (and not self-service only), advance
        if isPortalStep && currentStepIndex + 1 < allSteps.count && !selfServiceOnly {
            goToNextStep()
        } else {
            // Write final preferences on exit
            preferencesService?.writeOnExitIfNeeded()

            // Done - close dialog
            quitDialog(exitCode: 0)
        }
    }

    private func handleButton2() {
        // Back - cancel
        quitDialog(exitCode: 2)
    }
}

// MARK: - Preview

#if DEBUG
    struct Preset11View_Previews: PreviewProvider {
        static var previews: some View {
            // Create mock state for preview
            let state = InspectState()
            Preset11View(inspectState: state)
                .frame(width: 1000, height: 750)
        }
    }
#endif
