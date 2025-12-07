//
//  Preset5View.swift
//  dialog
//
//  Created by Henry Stamerjohann, Declarative IT GmbH, 19/07/2025
//
//  Compliance Dashboard style, options for file and plist key/value inspection
//

import SwiftUI

struct Preset5View: View, InspectLayoutProtocol {
    @ObservedObject var inspectState: InspectState
    @State private var showingAboutPopover = false
    @State private var showDetailOverlay = false
    @State private var showItemDetailOverlay = false
    @State private var selectedItemForDetail: InspectConfig.ItemConfig?
    @State private var complianceData: [ComplianceCategory] = []
    @State private var lastCheck: String = ""
    @State private var overallScore: Double = 0.0
    @State private var criticalIssues: [ComplianceItem] = []
    @State private var allFailingItems: [ComplianceItem] = []
    @StateObject private var iconCache = PresetIconCache()

    init(inspectState: InspectState) {
        self.inspectState = inspectState
    }


    var body: some View {
        let scale: CGFloat = scaleFactor
        
        VStack(spacing: 0) {
            // Header Section with Logo and Title
            VStack(spacing: 20 * scale) {
                // Icon and Title - Larger and more prominent
                HStack(spacing: 20 * scale) {
                    IconView(
                        image: iconCache.getMainIconPath(for: inspectState),
                        overlay: iconCache.getOverlayIconPath(for: inspectState),
                        defaultImage: "shield.checkered",
                        defaultColour: "accent"
                    )
                    .frame(width: 64 * scale, height: 64 * scale)
                        .onAppear { iconCache.cacheMainIcon(for: inspectState) }
                    
                    VStack(alignment: .leading, spacing: 4 * scale) {
                        Text(inspectState.uiConfiguration.windowTitle)
                            .font(.system(size: 22 * scale, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        
                        if let message = inspectState.uiConfiguration.subtitleMessage, !message.isEmpty {
                            Text(message)
                                .font(.system(size: 14 * scale))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else {
                            Text("Last Check: \(lastCheck)")
                                .font(.system(size: 12 * scale))
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    // Status badge on the right
                    Text(getOverallStatusText())
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .foregroundStyle(inspectState.colorThresholds.getColor(for: getLiveOverallScore()))
                        .padding(.horizontal, 16 * scale)
                        .padding(.vertical, 8 * scale)
                        .background(
                            Capsule()
                                .fill(inspectState.colorThresholds.getColor(for: getLiveOverallScore()).opacity(0.15))
                        )
                }
                .padding(.horizontal, 32 * scale)
                .padding(.top, 24 * scale)
                
                // Progress Bar Section - Horizontal and informative
                VStack(spacing: 12 * scale) {
                    // Stats row
                    HStack(spacing: 32 * scale) {
                        // Passed
                        HStack(spacing: 8 * scale) {
                            Circle()
                                .fill(inspectState.colorThresholds.getPositiveColor())
                                .frame(width: 8 * scale, height: 8 * scale)
                            Text("Passed")
                                .font(.system(size: 11 * scale, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("\(getLivePassedCount())")
                                .font(.system(size: 16 * scale, weight: .bold, design: .monospaced))
                                .foregroundStyle(inspectState.colorThresholds.getPositiveColor())
                        }
                        
                        Spacer()
                        
                        // Overall percentage
                        Text("\(Int(getLiveOverallScore() * 100))%")
                            .font(.system(size: 20 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        // Failed
                        HStack(spacing: 8 * scale) {
                            Text("\(getLiveFailedCount())")
                                .font(.system(size: 16 * scale, weight: .bold, design: .monospaced))
                                .foregroundStyle(inspectState.colorThresholds.getNegativeColor())
                            Text("Failed")
                                .font(.system(size: 11 * scale, weight: .medium))
                                .foregroundStyle(.secondary)
                            Circle()
                                .fill(inspectState.colorThresholds.getNegativeColor())
                                .frame(width: 8 * scale, height: 8 * scale)
                        }
                    }
                    
                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background bar
                            RoundedRectangle(cornerRadius: 6 * scale)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 12 * scale)
                            
                            // Progress bar
                            RoundedRectangle(cornerRadius: 6 * scale)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            inspectState.colorThresholds.getColor(for: getLiveOverallScore()),
                                            inspectState.colorThresholds.getColor(for: getLiveOverallScore()).opacity(0.8)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geometry.size.width * getLiveOverallScore()), height: 12 * scale)
                                .animation(.spring(response: 0.8, dampingFraction: 0.6), value: getLiveOverallScore())
                        }
                    }
                    .frame(height: 12 * scale)
                    
                    // Total count
                    Text("Total: \(getLiveTotalCount()) items")
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32 * scale)
                .padding(.bottom, 20 * scale)
            }
            
            Spacer()
            
            // Category Breakdown Section - More spacious grid layout
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(minimum: 340 * scale), spacing: 32 * scale),
                    GridItem(.flexible(minimum: 340 * scale), spacing: 32 * scale)
                ], spacing: 32 * scale) {
                    ForEach(complianceData, id: \.name) { category in
                        CategoryCardView(category: category, scale: scale, colorThresholds: inspectState.colorThresholds, inspectState: inspectState)
                    }
                }
                .padding(.horizontal, 32 * scale)
                .padding(.top, 20 * scale)
            }
            
            Spacer()
            
            // Bottom Action Area
            HStack(spacing: 20 * scale) {
                Button(inspectState.uiConfiguration.popupButtonText) {
                    showingAboutPopover.toggle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .font(.body)
                .popover(isPresented: $showingAboutPopover, arrowEdge: .top) {
                    ComplianceDetailsPopoverView(
                        complianceData: complianceData,
                        criticalIssues: criticalIssues,
                        allFailingItems: allFailingItems,
                        lastCheck: lastCheck,
                        inspectState: inspectState
                    )
                }
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 16) {
                    if inspectState.buttonConfiguration.button2Visible && !inspectState.buttonConfiguration.button2Text.isEmpty {
                        Button(inspectState.buttonConfiguration.button2Text) {
                            writeLog("Preset5View: User clicked button2 (\(inspectState.buttonConfiguration.button2Text)) - exiting with code 2", logLevel: .info)
                            exit(2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        // Note: button2 is always enabled when visible
                    }
                    
                    let finalButtonText = inspectState.config?.finalButtonText ??
                                         inspectState.buttonConfiguration.button1Text

                    Button(finalButtonText) {
                        handleFinalButtonPress(buttonText: finalButtonText)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(inspectState.buttonConfiguration.button1Disabled)
                }
            }
            .padding(.horizontal, 32 * scale)
            .padding(.bottom, 32 * scale)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            loadComplianceData()
            iconCache.cacheMainIcon(for: inspectState)
        }
        .onChange(of: inspectState.items.count) { _, _ in
            loadComplianceData()
        }
        .onChange(of: inspectState.completedItems) { _, _ in
            loadComplianceData()
        }
        .onChange(of: inspectState.downloadingItems) { _, _ in
            loadComplianceData()
        }
        .overlay {
            // Help button (positioned according to config)
            // Supports action types: overlay (default), url, custom
            if let helpButtonConfig = inspectState.config?.helpButton,
               helpButtonConfig.enabled ?? true {
                PositionedHelpButton(
                    config: helpButtonConfig,
                    action: {
                        handleHelpButtonAction(
                            config: helpButtonConfig,
                            showOverlay: $showDetailOverlay
                        )
                    },
                    padding: 16
                )
            }
        }
        .detailOverlay(
            inspectState: inspectState,
            isPresented: $showDetailOverlay,
            config: inspectState.config?.detailOverlay
        )
        .itemDetailOverlay(
            inspectState: inspectState,
            isPresented: $showItemDetailOverlay,
            item: selectedItemForDetail
        )
    }

    // MARK: - Icon Resolution Methods

    // Icon caching now handled by PresetIconCache

    // MARK: - Private Methods
    
    private func loadComplianceData() {
        // Check if we have complex plist sources (for mSCP audit) OR simple item validation
        let hasComplexPlist = inspectState.plistSources != nil
        let hasSimpleValidation = inspectState.items.contains { $0.plistKey != nil }
        let hasRegularItems = !inspectState.items.isEmpty
        
        guard hasComplexPlist || hasSimpleValidation || hasRegularItems else {
            writeLog("Preset5View: No configuration found", logLevel: .info)
            return
        }
        
        // Handle complex plist sources (existing mSCP audit functionality)
        if let plistSources = inspectState.plistSources {
            loadComplexPlistData(from: plistSources)
            return
        }
        
        // Handle simple validation (plist + file existence checks)
        if hasSimpleValidation || hasRegularItems {
            loadSimpleItemValidation()
        }
    }
    
    private func loadComplexPlistData(from plistSources: [InspectConfig.PlistSourceConfig]) {
        
        // Memory-safe loading with autorelease pool
        autoreleasepool {
            var allItems: [ComplianceItem] = []
            var latestCheck = ""
            
            // Limit concurrent processing to prevent memory spikes
            let maxSources = 10
            let sourcesToProcess = Array(plistSources.prefix(maxSources))
            
            if plistSources.count > maxSources {
                writeLog("Preset5View: Limiting plist processing to \(maxSources) sources", logLevel: .info)
            }
            
            for source in sourcesToProcess {
                autoreleasepool {
                    if let result = loadPlistSource(source: source) {
                        allItems.append(contentsOf: result.items)
                        if result.lastCheck > latestCheck {
                            latestCheck = result.lastCheck
                        }
                    }
                }
            }
            
            // Process data with memory cleanup
            let processedData = autoreleasepool { () -> ([ComplianceCategory], [ComplianceItem], [ComplianceItem]) in
                let categories = categorizeItems(allItems)
                let critical = allItems.filter { !$0.finding && $0.isCritical }
                let allFailing = allItems.filter { !$0.finding }
                return (categories, critical, allFailing)
            }
            
            // Update UI state
            complianceData = processedData.0
            lastCheck = latestCheck.isEmpty ? getCurrentTimestamp() : latestCheck
            overallScore = calculateOverallScore(allItems)
            criticalIssues = processedData.1
            allFailingItems = processedData.2
            
            writeLog("Preset5View: Loaded \(allItems.count) items from \(sourcesToProcess.count) plist sources", logLevel: .info)
        }
    }
    
    private func loadPlistSource(source: InspectConfig.PlistSourceConfig) -> (items: [ComplianceItem], lastCheck: String)? {
        // Memory safety: Check file size first to avoid loading huge plists
        let _ = URL(fileURLWithPath: source.path)
        guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              let fileSize = fileAttributes[.size] as? Int64 else {
            writeLog("Preset5View: Unable to get file attributes for \(source.path)", logLevel: .error)
            return nil
        }
        
        // Prevent loading files larger than 10MB
        let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB
        if fileSize > maxFileSize {
            writeLog("Preset5View: Plist file too large (\(fileSize) bytes) at \(source.path)", logLevel: .error)
            return nil
        }
        
        // Use autorelease pool for memory management
        return autoreleasepool { () -> (items: [ComplianceItem], lastCheck: String)? in
            guard let fileData = FileManager.default.contents(atPath: source.path) else {
                writeLog("Preset5View: Unable to read plist at \(source.path)", logLevel: .error)
                return nil
            }
            
            do {
                // Use PropertyListSerialization with explicit cleanup
                let plistObject = try PropertyListSerialization.propertyList(from: fileData, format: nil)
                
                guard let plistContents = plistObject as? [String: Any] else {
                    writeLog("Preset5View: Invalid plist format at \(source.path)", logLevel: .error)
                    return nil
                }
                
                var items: [ComplianceItem] = []
                let lastCheck = plistContents["lastComplianceCheck"] as? String ?? 
                               plistContents["LastUpdateCheck"] as? String ?? 
                               getCurrentTimestamp()
                
                // Process items with memory-conscious approach
                let maxItems = 1000 // Prevent processing too many items
                var processedCount = 0
                
                for (key, value) in plistContents {
                    if processedCount >= maxItems {
                        writeLog("Preset5View: Limiting plist processing to \(maxItems) items for \(source.path)", logLevel: .info)
                        break
                    }
                    
                    if shouldProcessKey(key, source: source) {
                        if let finding = evaluateValue(value, source: source) {
                            let item = ComplianceItem(
                                id: String(key), // Ensure string copy, not reference
                                category: getCategoryForKey(key, source: source),
                                finding: finding,
                                isCritical: isCriticalKey(key, source: source),
                                isInProgress: false  // Plist validation items don't have in-progress state
                            )
                            items.append(item)
                            processedCount += 1
                        }
                    }
                }
                
                writeLog("Preset5View: Successfully processed \(items.count) items from \(source.path) (\(fileSize) bytes)", logLevel: .info)
                return (items, lastCheck)
                
            } catch {
                writeLog("Preset5View: Error parsing plist at \(source.path): \(error)", logLevel: .error)
                return nil
            }
        }
    }
    
    private func shouldProcessKey(_ key: String, source: InspectConfig.PlistSourceConfig) -> Bool {
        // Skip timestamp and metadata keys
        let skipKeys = ["lastComplianceCheck", "LastUpdateCheck", "CFBundleVersion", "_"]
        if skipKeys.contains(key) || key.hasPrefix("_") { return false }
        
        // If key mappings exist, only process mapped keys
        if let keyMappings = source.keyMappings {
            return keyMappings.contains { $0.key == key }
        }
        
        // For compliance type, process all non-metadata keys
        if source.type == "compliance" {
            return true
        }
        
        // For other types, be more selective
        return true
    }
    
    private func evaluateValue(_ value: Any, source: InspectConfig.PlistSourceConfig) -> Bool? {
        let successValues = source.successValues ?? ["true", "1", "YES"]
        
        if let boolValue = value as? Bool {
            // Check if the boolean value (as string) is in successValues
            return successValues.contains(String(boolValue))
        }
        
        if let stringValue = value as? String {
            return successValues.contains(stringValue)
        }
        
        if let numberValue = value as? NSNumber {
            return successValues.contains(numberValue.stringValue)
        }
        
        if let dictValue = value as? [String: Any] {
            // For compliance plists with nested structure
            if let finding = dictValue["finding"] as? Bool {
                // Check if the boolean finding value is in successValues
                return successValues.contains(String(finding))
            }
        }
        
        return nil
    }
    
    private func getCategoryForKey(_ key: String, source: InspectConfig.PlistSourceConfig) -> String {
        // Check key mappings first
        if let keyMappings = source.keyMappings {
            if let mapping = keyMappings.first(where: { $0.key == key }),
               let category = mapping.category {
                return category
            }
        }
        
        // Check category prefixes
        if let categoryPrefix = source.categoryPrefix {
            for (prefix, category) in categoryPrefix where key.hasPrefix(prefix) {
                return category
            }
        }
        
        // Fallback to source display name or generic categorization
        return source.displayName
    }
    
    private func isCriticalKey(_ key: String, source: InspectConfig.PlistSourceConfig) -> Bool {
        // Check key mappings first
        if let keyMappings = source.keyMappings {
            if let mapping = keyMappings.first(where: { $0.key == key }),
               let isCritical = mapping.isCritical {
                return isCritical
            }
        }
        
        // Check critical keys list
        if let criticalKeys = source.criticalKeys {
            return criticalKeys.contains(key)
        }
        
        return false
    }
    
    // NEW: Simple item validation for non-audit use cases
    private func loadSimpleItemValidation() {
        var items: [ComplianceItem] = []

        for item in inspectState.items {
            let isValid: Bool
            let isInProgress: Bool

            // Check if item is currently downloading/installing
            isInProgress = inspectState.downloadingItems.contains(item.id)

            // Check if this item needs plist validation
            if item.plistKey != nil {
                // Use plist validation
                isValid = inspectState.validatePlistItem(item)
            } else {
                // Simple file existence check
                isValid = item.paths.first(where: { FileManager.default.fileExists(atPath: $0) }) != nil ||
                         inspectState.completedItems.contains(item.id)
            }

            // Create ComplianceItem from validation result
            // Use intelligent categorization with multiple fallback options
            let category: String
            let isCritical: Bool

            // Priority 1: Direct category specification
            if let itemCategory = item.category {
                category = itemCategory
                isCritical = false // Can be enhanced later
            }
            // Priority 2: plistSources configuration
            else if let plistKey = item.plistKey,
                    let firstSource = inspectState.plistSources?.first {
                category = getCategoryForKey(plistKey, source: firstSource)
                isCritical = isCriticalKey(plistKey, source: firstSource)
            }
            // Priority 3: Fallback for non-plist items
            else {
                category = "Applications"
                isCritical = false
            }

            let complianceItem = ComplianceItem(
                id: item.id,
                category: category,
                finding: isValid,
                isCritical: isCritical,
                isInProgress: isInProgress
            )

            items.append(complianceItem)
        }
        
        // Update UI state with validation results
        complianceData = categorizeItems(items)
        lastCheck = getCurrentTimestamp()
        overallScore = calculateOverallScore(items)
        criticalIssues = items.filter { !$0.finding && $0.isCritical }
        allFailingItems = items.filter { !$0.finding }
        
        writeLog("Preset5View: Loaded \(items.count) items from validation (plist + file checks)", logLevel: .info)
    }
    
    private func getCurrentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
    
    private func categorizeItems(_ items: [ComplianceItem]) -> [ComplianceCategory] {
        let grouped = Dictionary(grouping: items) { $0.category }
        
        return grouped.map { category, items in
            let passed = items.filter { $0.finding }.count
            let total = items.count
            let score = total > 0 ? Double(passed) / Double(total) : 0.0
            
            return ComplianceCategory(
                name: category,
                passed: passed,
                total: total,
                score: score,
                icon: getCategoryIcon(category)
            )
        }.sorted { $0.name < $1.name }
    }
    
    private func categorizeItemID(_ id: String) -> String {
        if id.hasPrefix("audit_") { return "Audit Controls" }
        if id.hasPrefix("auth_") { return "Authentication" }
        if id.hasPrefix("icloud_") { return "iCloud Security" }
        if id.hasPrefix("os_") { return "OS Security" }
        if id.hasPrefix("pwpolicy_") { return "Password Policy" }
        if id.hasPrefix("system_settings_") { return "System Settings" }
        return "Other"
    }
    
    private func getCategoryIcon(_ category: String) -> String {
        // Priority 1: Check if any item has specified a custom categoryIcon for this category
        for item in inspectState.items {
            if let itemCategory = item.category,
               itemCategory == category,
               let categoryIcon = item.categoryIcon {
                return categoryIcon
            }
        }
        
        // Priority 2: Check if we have plistSources with an icon configuration
        if let plistSources = inspectState.plistSources {
            for source in plistSources {
                // Check if this category matches any categoryPrefix from this source
                if let categoryPrefix = source.categoryPrefix {
                    for (_, prefixCategory) in categoryPrefix where prefixCategory == category {
                        // Use the icon from plistSources configuration
                        return source.icon ?? "shield"
                    }
                }
                // If category matches the source displayName, use source icon
                if source.displayName == category {
                    return source.icon ?? "shield"
                }
            }
        }
        
        // Priority 3: Simple fallback for common categories - use info icon to indicate help is available
        return "info.circle"
    }
    
    private func isCriticalItem(_ id: String) -> Bool {
        let criticalItems = [
            "os_anti_virus_installed",
            "os_firmware_password_require",
            "system_settings_critical_update_install_enforce",
            "os_sip_enable",
            "system_settings_firewall_enable"
        ]
        return criticalItems.contains(id)
    }
    
    private func calculateOverallScore(_ items: [ComplianceItem]) -> Double {
        guard !items.isEmpty else { return 0.0 }
        let passed = items.filter { $0.finding }.count
        return Double(passed) / Double(items.count)
    }
    
    private func getTotalChecks() -> Int {
        return complianceData.reduce(0) { $0 + $1.total }
    }
    
    private func getPassedCount() -> Int {
        return complianceData.reduce(0) { $0 + $1.passed }
    }
    
    private func getFailedCount() -> Int {
        return getTotalChecks() - getPassedCount()
    }

    // Live calculation methods for real-time updates
    private func getLivePassedCount() -> Int {
        var passed = 0
        for item in inspectState.items {
            let isValid: Bool
            if item.plistKey != nil {
                isValid = inspectState.validatePlistItem(item)
            } else {
                isValid = item.paths.first(where: { FileManager.default.fileExists(atPath: $0) }) != nil ||
                         inspectState.completedItems.contains(item.id)
            }
            if isValid { passed += 1 }
        }
        return passed
    }

    private func getLiveTotalCount() -> Int {
        return inspectState.items.count
    }

    private func getLiveFailedCount() -> Int {
        return getLiveTotalCount() - getLivePassedCount()
    }

    private func getLiveOverallScore() -> Double {
        let total = getLiveTotalCount()
        guard total > 0 else { return 0.0 }
        return Double(getLivePassedCount()) / Double(total)
    }

    private func getOverallStatusText() -> String {
        let score = getLiveOverallScore()
        if score >= 0.95 {
            return "Excellent Compliance"
        } else if score >= 0.8 {
            return "Good Compliance"
        } else if score >= 0.6 {
            return "Needs Improvement"
        } else {
            return "Critical Issues"
        }
    }


    private func formatIssueTitle(_ id: String) -> String {
        return id.replacingOccurrences(of: "_", with: " ")
            .capitalized
            .trimmingCharacters(in: .whitespaces)
    }

    /// Handle final button press with safe callback mechanisms
    /// Writes trigger file, updates plist, logs event, then exits
    private func handleFinalButtonPress(buttonText: String) {
        writeLog("Preset5: User clicked final button (\(buttonText))", logLevel: .info)

        // 1. Write to interaction log for script monitoring
        let logPath = "/tmp/preset5_interaction.log"
        let logEntry = "final_button:clicked:\(buttonText)\n"
        if let data = logEntry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let fileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                    _ = try? fileHandle.seekToEnd()
                    _ = try? fileHandle.write(contentsOf: data)
                    try? fileHandle.close()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }

        // 2. Create trigger file (touch equivalent)
        let triggerPath = "/tmp/preset5_final_button.trigger"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let triggerContent = "button_text=\(buttonText)\ntimestamp=\(timestamp)\nstatus=completed\n"
        if let data = triggerContent.data(using: .utf8) {
            try? data.write(to: URL(fileURLWithPath: triggerPath), options: .atomic)
            writeLog("Preset5: Created trigger file at \(triggerPath)", logLevel: .debug)
        }

        // 3. Write to plist for structured data access
        let plistPath = "/tmp/preset5_interaction.plist"
        let plistData: [String: Any] = [
            "finalButtonPressed": true,
            "buttonText": buttonText,
            "timestamp": timestamp,
            "preset": "preset5"
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plistData, format: .xml, options: 0) {
            try? data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            writeLog("Preset5: Updated interaction plist at \(plistPath)", logLevel: .debug)
        }

        // 4. Small delay to ensure file operations complete
        usleep(100000) // 100ms

        // 5. Exit with success code
        writeLog("Preset5: Exiting with code 0", logLevel: .info)
        exit(0)
    }

}

// MARK: - Supporting Views

struct CategoryRowView: View {
    let category: ComplianceCategory
    let scale: CGFloat
    let colorThresholds: InspectConfig.ColorThresholds
    
    var body: some View {
        HStack(spacing: 16 * scale) {
            // Category icon
            Image(systemName: category.icon)
                .font(.system(size: 20 * scale))
                .foregroundStyle(.blue)
                .frame(width: 24 * scale)
            
            // Category name
            Text(category.name)
                .font(.system(size: 16 * scale, weight: .medium))
                .foregroundStyle(.primary)
            
            Spacer()
            
            // Progress indicator
            HStack(spacing: 8 * scale) {
                // Status icon
                Image(systemName: colorThresholds.getStatusIcon(for: category.score))
                    .font(.system(size: 14 * scale))
                    .foregroundStyle(colorThresholds.getColor(for: category.score))
                
                // Score text
                Text("\(category.passed)/\(category.total)")
                    .font(.system(size: 14 * scale, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                
                // Percentage
                Text("(\(Int(category.score * 100))%)")
                    .font(.system(size: 14 * scale))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8 * scale)
        .padding(.horizontal, 16 * scale)
        .background(
            RoundedRectangle(cornerRadius: 8 * scale)
                .fill(Color.gray.opacity(0.05))
        )
    }
}

struct CategoryCardView: View {
    let category: ComplianceCategory
    let scale: CGFloat
    let colorThresholds: InspectConfig.ColorThresholds
    @ObservedObject var inspectState: InspectState
    @State private var showingCategoryHelp = false
    @State private var animateProgress = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with category title
            HStack {
                HStack(spacing: 8 * scale) {
                    Text(category.name)
                        .font(.system(size: 16 * scale, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    
                    // Info button next to category name
                    Button(action: {
                        showingCategoryHelp = true
                    }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14 * scale, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Click for category information and recommendations")
                    .popover(isPresented: $showingCategoryHelp) {
                        CategoryHelpPopover(category: category, scale: scale, inspectState: inspectState)
                    }
                }
                
                Spacer()
                
                // Status badge
                Text(getStatusText())
                    .font(.system(size: 10 * scale, weight: .medium))
                    .foregroundStyle(colorThresholds.getColor(for: category.score))
                    .padding(.horizontal, 10 * scale)
                    .padding(.vertical, 4 * scale)
                    .background(
                        Capsule()
                            .fill(colorThresholds.getColor(for: category.score).opacity(0.1))
                    )
            }
            .padding(.horizontal, 20 * scale)
            .padding(.top, 20 * scale)
            .padding(.bottom, 16 * scale)
            
            // Divider
            Divider()
                .padding(.horizontal, 20 * scale)
            
            // Main content area: Items list on left, Progress indicator on right
            HStack(alignment: .top, spacing: 24 * scale) {
                // Items list - takes up most space
                ScrollView {
                    LazyVStack(spacing: 4 * scale) {
                        ForEach(getCategoryItems(), id: \.id) { item in
                            ItemRowView(
                                item: item, 
                                scale: scale, 
                                colorThresholds: colorThresholds, 
                                inspectState: inspectState
                            )
                            
                            if item.id != getCategoryItems().last?.id {
                                Divider()
                                    .padding(.horizontal, 16 * scale)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220 * scale)
                
                // Right side: Circular progress and metrics - positioned lower
                VStack(spacing: 12 * scale) {
                    // Add spacing to push content lower
                    Spacer()
                        .frame(height: 20 * scale)
                    
                    // Circular progress indicator with percentage inside
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.15), lineWidth: 4 * scale)
                            .frame(width: 60 * scale, height: 60 * scale)
                        
                        Circle()
                            .trim(from: 0, to: animateProgress ? category.score : 0)
                            .stroke(
                                colorThresholds.getColor(for: category.score),
                                style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round)
                            )
                            .frame(width: 60 * scale, height: 60 * scale)
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(response: 0.8, dampingFraction: 0.6), value: animateProgress)
                        
                        // Percentage display inside the ring
                        Text("\(Int(category.score * 100))%")
                            .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                    
                    // Compact status summary
                    VStack(spacing: 6 * scale) {
                        HStack(spacing: 6 * scale) {
                            Circle()
                                .fill(colorThresholds.getPositiveColor())
                                .frame(width: 4 * scale, height: 4 * scale)
                            Text("\(category.passed)")
                                .font(.system(size: 10 * scale, weight: .medium, design: .monospaced))
                                .foregroundStyle(colorThresholds.getPositiveColor())
                        }
                        
                        HStack(spacing: 6 * scale) {
                            Circle()
                                .fill(colorThresholds.getNegativeColor())
                                .frame(width: 4 * scale, height: 4 * scale)
                            Text("\(category.total - category.passed)")
                                .font(.system(size: 10 * scale, weight: .medium, design: .monospaced))
                                .foregroundStyle(colorThresholds.getNegativeColor())
                        }
                    }
                    
                    Spacer()
                }
                .frame(width: 80 * scale)
            }
            .padding(.horizontal, 20 * scale)
            .padding(.bottom, 20 * scale)
        }
        .background(
            RoundedRectangle(cornerRadius: 16 * scale)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(
                    color: Color.black.opacity(0.06), 
                    radius: 8 * scale, 
                    x: 0, 
                    y: 2 * scale
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16 * scale)
                        .stroke(
                            Color.gray.opacity(0.08), 
                            lineWidth: 1
                        )
                )
        )
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6).delay(0.1)) {
                animateProgress = true
            }
        }
    }
    
    private func getStatusText() -> String {
        if category.score >= 0.95 {
            return "Excellent"
        } else if category.score >= 0.8 {
            return "Good"
        } else if category.score >= 0.6 {
            return "Needs Work"
        } else {
            return "Critical"
        }
    }
    
    private func getCategoryItems() -> [CategoryItemData] {
        // Get items that belong to this category
        let categoryItems = inspectState.items.filter { item in
            let itemCategory: String
            if let category = item.category {
                itemCategory = category
            } else if let plistKey = item.plistKey,
                      let firstSource = inspectState.plistSources?.first {
                itemCategory = getCategoryForKey(plistKey, source: firstSource, inspectState: inspectState)
            } else {
                itemCategory = "Applications"
            }
            return itemCategory == category.name
        }
        
        // Convert to CategoryItemData
        return categoryItems.map { item in
            let isValid: Bool
            if item.plistKey != nil {
                isValid = inspectState.validatePlistItem(item)
            } else {
                isValid = item.paths.first(where: { FileManager.default.fileExists(atPath: $0) }) != nil ||
                         inspectState.completedItems.contains(item.id)
            }

            let isInProgress = inspectState.downloadingItems.contains(item.id)

            return CategoryItemData(
                id: item.id,
                displayName: item.displayName,
                isValid: isValid,
                isCritical: false, // Can be enhanced later
                isInProgress: isInProgress
            )
        }.sorted { $0.displayName < $1.displayName }
    }
}

// Helper function for category key mapping
private func getCategoryForKey(_ key: String, source: InspectConfig.PlistSourceConfig, inspectState: InspectState) -> String {
    // Check key mappings first
    if let keyMappings = source.keyMappings {
        if let mapping = keyMappings.first(where: { $0.key == key }),
           let category = mapping.category {
            return category
        }
    }
    
    // Check category prefixes
    if let categoryPrefix = source.categoryPrefix {
        for (prefix, category) in categoryPrefix where key.hasPrefix(prefix) {
            return category
        }
    }
    
    return source.displayName
}

// MARK: - Item Row View
struct ItemRowView: View {
    let item: CategoryItemData
    let scale: CGFloat
    let colorThresholds: InspectConfig.ColorThresholds
    @ObservedObject var inspectState: InspectState

    var body: some View {
        HStack(spacing: 12 * scale) {
            // Status indicator
            Circle()
                .fill(getItemColor())
                .frame(width: 6 * scale, height: 6 * scale)

            // Item name
            Text(item.displayName)
                .font(.system(size: 13 * scale, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)

            Spacer()

            // Status icon
            Image(systemName: getItemIcon())
                .font(.system(size: 12 * scale))
                .foregroundStyle(getItemColor())
        }
        .padding(.horizontal, 20 * scale)
        .padding(.vertical, 12 * scale)
    }

    // MARK: - Helper Methods

    /// Determine color based on item status (in-progress, valid, invalid)
    private func getItemColor() -> Color {
        if item.isInProgress {
            // Use warning/middle color (orange) for in-progress items
            // Pass 0.5 to get the warning threshold color
            return colorThresholds.getColor(for: colorThresholds.warning)
        }
        // Use standard validation colors (green/red)
        return colorThresholds.getValidationColor(isValid: item.isValid)
    }

    /// Determine icon based on item status (in-progress, valid, invalid)
    private func getItemIcon() -> String {
        if item.isInProgress {
            // Use spinner/progress icon for in-progress items
            return "arrow.triangle.2.circlepath"
        }
        // Use standard checkmark/xmark icons
        return item.isValid ? "checkmark.circle.fill" : "xmark.circle.fill"
    }
}

// MARK: - Category Item Data Model
struct CategoryItemData {
    let id: String
    let displayName: String
    let isValid: Bool
    let isCritical: Bool
    let isInProgress: Bool  // NEW: true when item is currently downloading/installing
}

struct ComplianceDetailsPopoverView: View {
    let complianceData: [ComplianceCategory]
    let criticalIssues: [ComplianceItem]
    let allFailingItems: [ComplianceItem]
    let lastCheck: String
    let inspectState: InspectState
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Security Details")
                    .font(.headline)
                
                Text("Last Check: \(lastCheck)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                // Show all items evaluation details (both plist and file checks)
                if !inspectState.items.isEmpty {
                    Divider()
                    
                    Text("Item Evaluation Details")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    // Group items by category for better organization
                    let groupedItems = Dictionary(grouping: inspectState.items) { item in
                        item.category ?? "Other"
                    }
                    
                    ForEach(groupedItems.keys.sorted(), id: \.self) { category in
                        if let categoryItems = groupedItems[category] {
                            VStack(alignment: .leading, spacing: 12) {
                                // Category header
                                HStack {
                                    Image(systemName: categoryItems.first?.categoryIcon ?? "folder")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.blue)
                                    Text(category)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    
                                    // Category summary
                                    let validCount = categoryItems.filter { item in
                                        isItemValid(item)
                                    }.count
                                    
                                    Text("\(validCount)/\(categoryItems.count)")
                                        .font(.caption)
                                        .foregroundStyle(validCount == categoryItems.count ? inspectState.colorThresholds.getPositiveColor() : .orange)
                                }
                                .padding(.top, 8)
                    
                    ForEach(categoryItems.sorted(by: { $0.guiIndex < $1.guiIndex }), id: \.id) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            // Item header
                            HStack {
                                let isValid = isItemValid(item)
                                
                                Circle()
                                    .fill(inspectState.colorThresholds.getValidationColor(isValid: isValid))
                                    .frame(width: 8, height: 8)
                                
                                Text(item.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                
                                Spacer()
                            }
                            
                            // Plist details
                            if let plistKey = item.plistKey {
                                VStack(alignment: .leading, spacing: 4) {
                                    // Key
                                    HStack {
                                        Text("Key:")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 60, alignment: .leading)
                                        Text(plistKey)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                    
                                    // Expected value
                                    if let expectedValue = item.expectedValue {
                                        HStack {
                                            Text("Expected:")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 60, alignment: .leading)
                                            Text(expectedValue)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.orange)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    
                                    // Actual value
                                    HStack {
                                        Text("Actual:")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 60, alignment: .leading)
                                        
                                        if let actualValue = inspectState.getPlistValueForDisplay(item: item) {
                                            Text(actualValue)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(inspectState.colorThresholds.getValidationColor(isValid: inspectState.validatePlistItem(item)))
                                                .textSelection(.enabled)
                                        } else {
                                            Text("Key not found")
                                                .font(.caption)
                                                .foregroundStyle(inspectState.colorThresholds.getNegativeColor())
                                                .italic()
                                        }
                                    }
                                    
                                    // Path
                                    if let path = item.paths.first {
                                        HStack {
                                            Text("Path:")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 60, alignment: .leading)
                                            Text(path)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                                .padding(.leading, 12)
                            } else {
                                // File existence check details
                                VStack(alignment: .leading, spacing: 4) {
                                    // Evaluation type
                                    HStack {
                                        Text("Type:")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 60, alignment: .leading)
                                        Text("File Existence Check")
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                    }
                                    
                                    // Check all paths
                                    ForEach(item.paths, id: \.self) { path in
                                        let fileExists = FileManager.default.fileExists(atPath: path)
                                        HStack {
                                            Text("Path:")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 60, alignment: .leading)
                                            
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(path)
                                                    .font(.system(.caption, design: .monospaced))
                                                    .foregroundStyle(inspectState.colorThresholds.getValidationColor(isValid: fileExists))
                                                    .lineLimit(2)
                                                    .textSelection(.enabled)
                                                
                                                Text(fileExists ? "✓ File exists" : "✗ File not found")
                                                    .font(.caption)
                                                    .foregroundStyle(inspectState.colorThresholds.getValidationColor(isValid: fileExists))
                                            }
                                        }
                                    }
                                    
                                    // File info if exists
                                    if let existingPath = item.paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                                        if let attributes = try? FileManager.default.attributesOfItem(atPath: existingPath) {
                                            // File size
                                            if let fileSize = attributes[.size] as? Int64 {
                                                HStack {
                                                    Text("Size:")
                                                        .font(.caption.weight(.medium))
                                                        .foregroundStyle(.secondary)
                                                        .frame(width: 60, alignment: .leading)
                                                    Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            
                                            // Modification date
                                            if let modDate = attributes[.modificationDate] as? Date {
                                                HStack {
                                                    Text("Modified:")
                                                        .font(.caption.weight(.medium))
                                                        .foregroundStyle(.secondary)
                                                        .frame(width: 60, alignment: .leading)
                                                    Text(modDate, style: .date)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.leading, 12)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        )
                    }
                            } // End VStack for category
                        } // End if let categoryItems
                    } // End ForEach categories
                } // End if !inspectState.items.isEmpty
                
                if inspectState.items.isEmpty && !allFailingItems.isEmpty {
                    // Show enhanced audit issues for complex validation
                    Divider()
                    
                    // Enhanced header with context
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundStyle(inspectState.colorThresholds.getNegativeColor())
                                .font(.subheadline)
                            Text("Security Compliance Issues")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        
                        // Show audit source context
                        if let plistSources = inspectState.plistSources,
                           let firstSource = plistSources.first {
                            Text("Source: \(firstSource.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Text("The following controls require attention:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 8)
                    
                    // Show all failing compliance items, with critical ones first
                    let sortedFailingItems = getAllFailingComplianceItems()
                    ForEach(sortedFailingItems, id: \.id) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(inspectState.colorThresholds.getNegativeColor())
                                    .font(.caption)
                                
                                Text(formatAuditControlTitle(issue.id))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                
                                Spacer()
                                
                                // Show category badge
                                Text(issue.category)
                                    .font(.system(.caption2))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundStyle(.orange)
                                    .clipShape(.rect(cornerRadius: 4))
                            }
                            
                            // Show control description/context from config
                            if let context = getContextFromPlistSources(for: issue.id) {
                                Text(context)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 16)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    
                    // Summary footer with correct counts
                    let totalFailingCount = sortedFailingItems.count
                    let criticalFailingCount = sortedFailingItems.filter { $0.isCritical }.count
                    
                    if totalFailingCount > 0 {
                        Divider()
                            .padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.blue)
                                    .font(.caption)
                                
                                Text("\(totalFailingCount) control(s) need remediation")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            if criticalFailingCount > 0 {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(inspectState.colorThresholds.getNegativeColor())
                                        .font(.caption)
                                    
                                    Text("\(criticalFailingCount) are critical priority")
                                        .font(.caption)
                                        .foregroundStyle(inspectState.colorThresholds.getNegativeColor())
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: 500, maxHeight: 400)
    }
    
    // Helper function to validate items
    private func isItemValid(_ item: InspectConfig.ItemConfig) -> Bool {
        if item.plistKey != nil {
            return inspectState.validatePlistItem(item)
        } else {
            return item.paths.first(where: { FileManager.default.fileExists(atPath: $0) }) != nil
        }
    }
    
    // Enhanced formatting for audit control titles using config data
    private func formatAuditControlTitle(_ id: String) -> String {
        // Use keyMappings from plistSources if available for custom titles
        if let plistSources = inspectState.plistSources {
            for source in plistSources {
                if let keyMappings = source.keyMappings {
                    if let mapping = keyMappings.first(where: { $0.key == id }),
                       let displayName = mapping.displayName {
                        return displayName
                    }
                }
            }
        }
        
        // Fallback: smart prefix removal and formatting
        var cleanedId = id
        if let plistSources = inspectState.plistSources,
           let firstSource = plistSources.first,
           let categoryPrefix = firstSource.categoryPrefix {
            // Remove category prefixes dynamically
            for (prefix, _) in categoryPrefix where id.hasPrefix(prefix) {
                cleanedId = String(id.dropFirst(prefix.count))
                break
            }
        }
        
        // Convert underscores to spaces and capitalize
        return cleanedId
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
            .trimmingCharacters(in: .whitespaces)
    }
    
    // Get context/description from plistSources configuration
    private func getContextFromPlistSources(for id: String) -> String? {
        guard let plistSources = inspectState.plistSources else { return nil }
        
        for source in plistSources {
            // Check if source has a general description for critical keys
            if let criticalKeys = source.criticalKeys,
               criticalKeys.contains(id) {
                return "Critical security control - requires immediate attention"
            }
        }
        
        return nil
    }
    
    // Check if there are any failing compliance items (beyond just critical ones)
    private func hasFailingComplianceItems() -> Bool {
        return !allFailingItems.isEmpty
    }
    
    // Get all failing compliance items, with critical ones first
    private func getAllFailingComplianceItems() -> [ComplianceItem] {
        // Sort so critical items appear first
        return allFailingItems.sorted { item1, item2 in
            if item1.isCritical && !item2.isCritical {
                return true // Critical items first
            } else if !item1.isCritical && item2.isCritical {
                return false
            } else {
                return item1.category < item2.category // Then by category
            }
        }
    }
    
    // Helper to determine if an item is critical based on plistSources
    private func isCriticalItem(_ id: String) -> Bool {
        guard let plistSources = inspectState.plistSources,
              let firstSource = plistSources.first,
              let criticalKeys = firstSource.criticalKeys else {
            return false
        }
        return criticalKeys.contains(id)
    }
}

// MARK: - Data Models

struct ComplianceItem {
    let id: String
    let category: String
    let finding: Bool
    let isCritical: Bool
    let isInProgress: Bool  // NEW: true when item is currently downloading/installing
}

struct ComplianceCategory {
    let name: String
    let passed: Int
    let total: Int
    let score: Double
    let icon: String
}

// MARK: - Category Help Popover
struct CategoryHelpPopover: View {
    let category: ComplianceCategory
    let scale: CGFloat
    let inspectState: InspectState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: category.icon)
                    .font(.title2)
                    .foregroundStyle(.blue)
                
                Text(category.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                Spacer()
            }
            
            Divider()
            
            // Description based on category
            Text(getCategoryDescription())
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            // Compliance status
            VStack(alignment: .leading, spacing: 8) {
                Text(getStatusLabel())
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                HStack {
                    ProgressView(value: category.score)
                        .progressViewStyle(LinearProgressViewStyle(tint: getScoreColor()))
                    
                    Text("\(Int(category.score * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(getScoreColor())
                }
                
                Text(getChecksPassedText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Recommendations
            if category.score < 1.0 {
                Divider()
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(getRecommendationsLabel())
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Text(getRecommendations())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
        .frame(width: 320 * scale)
    }
    
    private func getCategoryDescription() -> String {
        // First check if there's custom help content in the configuration
        if let categoryHelp = inspectState.config?.categoryHelp {
            if let help = categoryHelp.first(where: { $0.category == category.name }) {
                return help.description
            }
        }
        
        // Fallback to generic description
        return "Security controls and configurations for \(category.name.lowercased()) to ensure compliance with organizational policies and industry standards."
    }
    
    private func getRecommendations() -> String {
        let failedCount = category.total - category.passed
        
        // First check if there's custom help content in the configuration
        if let categoryHelp = inspectState.config?.categoryHelp {
            if let help = categoryHelp.first(where: { $0.category == category.name }) {
                if let recommendations = help.recommendations {
                    return recommendations
                }
            }
        }
        
        // Fallback to generic recommendations
        return "Review and remediate the \(failedCount) failing check\(failedCount == 1 ? "" : "s") in this category to improve security posture."
    }
    
    private func getScoreColor() -> Color {
        if category.score >= 0.9 {
            return .green
        } else if category.score >= 0.75 {
            return .blue
        } else if category.score >= 0.5 {
            return .orange
        } else {
            return .red
        }
    }
    
    private func getStatusLabel() -> String {
        // First check category-specific label
        if let categoryHelp = inspectState.config?.categoryHelp {
            if let help = categoryHelp.first(where: { $0.category == category.name }) {
                if let statusLabel = help.statusLabel {
                    return statusLabel
                }
            }
        }
        
        // Then check compliance labels
        if let complianceLabels = inspectState.config?.complianceLabels {
            if let complianceStatus = complianceLabels.complianceStatus {
                return complianceStatus
            }
        }

        // Default fallback
        return "Compliance Status"
    }
    
    private func getRecommendationsLabel() -> String {
        // First check category-specific label
        if let categoryHelp = inspectState.config?.categoryHelp {
            if let help = categoryHelp.first(where: { $0.category == category.name }) {
                if let recommendationsLabel = help.recommendationsLabel {
                    return recommendationsLabel
                }
            }
        }
        
        // Then check compliance labels
        if let complianceLabels = inspectState.config?.complianceLabels {
            if let recommendedActions = complianceLabels.recommendedActions {
                return recommendedActions
            }
        }

        // Default fallback
        return "Recommended Actions"
    }
    
    private func getChecksPassedText() -> String {
        // Check for custom format in compliance labels
        if let complianceLabels = inspectState.config?.complianceLabels {
            if let checksPassed = complianceLabels.checksPassed {
                // Replace placeholders with actual values
                return checksPassed
                    .replacingOccurrences(of: "{passed}", with: "\(category.passed)")
                    .replacingOccurrences(of: "{total}", with: "\(category.total)")
            }
        }

        // Default format
        return "\(category.passed) of \(category.total) checks passed"
    }
}
