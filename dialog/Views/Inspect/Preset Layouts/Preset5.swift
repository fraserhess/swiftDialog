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
    @StateObject private var iconCache = PresetIconCache()

    // MARK: - Local State for Compliance Data (prevents re-render loops)
    @State private var categories: [ComplianceCategory] = []
    @State private var overallScore: Double = 0.0
    @State private var criticalIssues: [ComplianceItem] = []
    @State private var allFailingItems: [ComplianceItem] = []
    @State private var lastCheck: String = ""
    @State private var hasCategories = false  // True once categories are built (doesn't wait for validation)
    @State private var lastValidationCount = 0  // Track validation progress for incremental updates
    @State private var categoryIconCache: [String: String] = [:]  // PERF: Cache category icons to avoid O(n) lookup per category

    // MARK: - Collapse/Expand All State
    @State private var expandedCategories: Set<String> = []  // Track which categories are expanded

    // MARK: - Search State
    @State private var searchText: String = ""

    // MARK: - Computed Properties
    private var isValidationComplete: Bool {
        !inspectState.items.isEmpty &&
        inspectState.plistValidationResults.count == inspectState.items.count
    }

    // MARK: - Trigger File Configuration

    /// Final button trigger file path (Preset5 only outputs final triggers)
    private var finalTriggerFilePath: String {
        if let customPath = inspectState.config?.triggerFile {
            let url = URL(fileURLWithPath: customPath)
            let ext = url.pathExtension
            let base = url.deletingPathExtension().path
            return ext.isEmpty ? "\(customPath)_final" : "\(base)_final.\(ext)"
        }
        if appArguments.inspectMode.present {
            return "/tmp/swiftdialog_dev_preset5_final.trigger"
        }
        return "/tmp/swiftdialog_\(ProcessInfo.processInfo.processIdentifier)_preset5_final.trigger"
    }

    init(inspectState: InspectState) {
        self.inspectState = inspectState
    }

    // MARK: - Data Computation (Optimized Progressive Loading)

    /// Computes categories from items - optimized to minimize redundant work
    /// Uses cached validation results when available, defaults to "pending" for unvalidated items
    private func computeComplianceData() {
        guard !inspectState.items.isEmpty else { return }

        let validationCount = inspectState.plistValidationResults.count
        let totalItems = inspectState.items.count

        // OPTIMIZATION: Skip if nothing changed
        if hasCategories && validationCount == lastValidationCount {
            return
        }

        // PERF FIX: Throttle category recomputation during validation
        // Without throttling, we do O(n²) work (113 items × 113 calls = 12,000+ iterations)
        // Per-card progress bars update separately via categoryValidationProgress computed property
        let isComplete = validationCount == totalItems
        let itemsSinceLastUpdate = validationCount - lastValidationCount
        let shouldUpdate = !hasCategories ||       // First time - always compute
                          isComplete ||            // Final - always compute
                          validationCount <= 3 ||  // Early feedback
                          itemsSinceLastUpdate >= 10  // Throttle to every 10 items

        if !shouldUpdate {
            return
        }

        // Transform items to ComplianceItem array (only when needed)
        let complianceItems: [ComplianceItem] = inspectState.items.map { item in
            let hasValidationResult = inspectState.plistValidationResults[item.id] != nil
            let isValid = hasValidationResult ? getValidationResult(for: item) : false
            return ComplianceItem(
                id: item.id,
                category: getItemCategory(item),
                finding: isValid,
                isCritical: getItemCriticality(item),
                isInProgress: !hasValidationResult
            )
        }

        // PERF: Build icon cache once (avoids O(n) lookup per category - 7 categories × 113 items = 791 iterations)
        if categoryIconCache.isEmpty {
            let uniqueCategories = Set(complianceItems.map { $0.category })
            for category in uniqueCategories {
                categoryIconCache[category] = computeCategoryIconUncached(category)
            }
        }

        // Update state
        categories = categorizeItems(complianceItems)
        overallScore = calculateOverallScore(complianceItems)
        criticalIssues = complianceItems.filter { !$0.finding && $0.isCritical && !$0.isInProgress }
        allFailingItems = complianceItems.filter { !$0.finding && !$0.isInProgress }
        lastCheck = getCurrentTimestamp()
        hasCategories = true
        lastValidationCount = validationCount

        writeLog("Preset5: Computed \(categories.count) categories, \(validationCount)/\(totalItems) validated, score: \(String(format: "%.0f", overallScore * 100))%", logLevel: .debug)
    }

    /// Gets validation result from cache only - NEVER does synchronous validation
    /// Returns nil if not yet validated (async validation will populate cache)
    private func getValidationResult(for item: InspectConfig.ItemConfig) -> Bool {
        // ONLY check cached validation results - never block main thread
        // Async validation in InspectState.validateAllItems() will populate this cache
        if let cachedResult = inspectState.plistValidationResults[item.id] {
            return cachedResult
        }

        // No cached result yet - return false (item shows as "in progress")
        // The async validation will update this and trigger recomputation
        return false
    }

    var body: some View {
        let scale: CGFloat = scaleFactor

        // Chrome-first rendering: header and footer always visible
        VStack(spacing: 0) {
            // HEADER SECTION - Always renders immediately
            headerSection(scale: scale)

            // CONTENT AREA - Shows loading OR category grid
            ZStack {
                if inspectState.items.isEmpty {
                    // Only show loading when items haven't loaded yet
                    loadingContentView(scale: scale)
                } else {
                    // Show categories immediately once items exist
                    // (validation results update progressively)
                    categoryContentView(scale: scale)
                }
            }

            // FOOTER SECTION - Always renders immediately
            footerSection(scale: scale)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            iconCache.cacheMainIcon(for: inspectState)
            // Compute categories immediately if items are already loaded
            if !inspectState.items.isEmpty {
                computeComplianceData()
            }
        }
        .onChange(of: inspectState.items.count) { _, newCount in
            // Compute categories immediately when items load
            if newCount > 0 {
                computeComplianceData()
            }
        }
        .onChange(of: inspectState.plistValidationResults.count) { _, _ in
            // RING BUFFER: Update on EVERY validation result for smooth per-card progress
            // Each card's progress bar updates as its items complete
            if !inspectState.items.isEmpty {
                computeComplianceData()
            }
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

    // MARK: - Header Section (Always renders immediately)
    @ViewBuilder
    private func headerSection(scale: CGFloat) -> some View {
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
                    } else if hasCategories {
                        Text("Last Check: \(lastCheck)")
                            .font(.system(size: 12 * scale))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Status badge on the right (shows validation progress or final status)
                if isValidationComplete {
                    Text(getOverallStatusText())
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .foregroundStyle(inspectState.colorThresholds.getColor(for: getLiveOverallScore()))
                        .padding(.horizontal, 16 * scale)
                        .padding(.vertical, 8 * scale)
                        .background(
                            Capsule()
                                .fill(inspectState.colorThresholds.getColor(for: getLiveOverallScore()).opacity(0.15))
                        )
                } else if hasCategories {
                    // Show validation progress
                    Text("Validating...")
                        .font(.system(size: 12 * scale, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16 * scale)
                        .padding(.vertical, 8 * scale)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.15))
                        )
                } else {
                    Text("Loading...")
                        .font(.system(size: 12 * scale, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16 * scale)
                        .padding(.vertical, 8 * scale)
                        .background(
                            Capsule()
                                .fill(Color.gray.opacity(0.15))
                        )
                }
            }
            .padding(.horizontal, 32 * scale)
            .padding(.top, 24 * scale)

            // Progress Bar Section - Horizontal with badge-style stats
            VStack(spacing: 12 * scale) {
                // Stats badges row (Audit Hub style)
                HStack(spacing: 12 * scale) {
                    // All items badge
                    StatBadge(
                        value: getLiveTotalCount(),
                        label: "All",
                        color: .secondary,
                        scale: scale
                    )

                    // Passed badge
                    StatBadge(
                        value: getLivePassedCount(),
                        label: "Passed",
                        color: inspectState.colorThresholds.getPositiveColor(),
                        scale: scale
                    )

                    // Failed badge
                    StatBadge(
                        value: getLiveFailedCount(),
                        label: "Failed",
                        color: inspectState.colorThresholds.getNegativeColor(),
                        scale: scale
                    )

                    Spacer()

                    // Pass Rate percentage (large, on the right)
                    HStack(spacing: 6 * scale) {
                        Text("\(String(format: "%.1f", getLiveOverallScore() * 100))%")
                            .font(.system(size: 24 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(inspectState.colorThresholds.getColor(for: getLiveOverallScore()))

                        Text("Pass Rate")
                            .font(.system(size: 11 * scale, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background bar
                        RoundedRectangle(cornerRadius: 6 * scale)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 12 * scale)

                        // Progress bar (shows pre-cache → validation → score)
                        let progressValue: CGFloat = {
                            if isValidationComplete {
                                return getLiveOverallScore()
                            } else if let preCacheProgress = inspectState.preCacheProgress, preCacheProgress.total > 0 {
                                // Pre-cache phase: show file loading progress (0-50% of bar)
                                return CGFloat(preCacheProgress.loaded) / CGFloat(preCacheProgress.total) * 0.3
                            } else if !inspectState.items.isEmpty {
                                // Validation phase: show validation progress (30-100% of bar)
                                let validationProgress = CGFloat(inspectState.plistValidationResults.count) / CGFloat(inspectState.items.count)
                                return 0.3 + (validationProgress * 0.7)
                            }
                            return 0
                        }()

                        RoundedRectangle(cornerRadius: 6 * scale)
                            .fill(
                                LinearGradient(
                                    colors: isValidationComplete ? [
                                        inspectState.colorThresholds.getColor(for: getLiveOverallScore()),
                                        inspectState.colorThresholds.getColor(for: getLiveOverallScore()).opacity(0.8)
                                    ] : [Color.accentColor, Color.accentColor.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geometry.size.width * progressValue), height: 12 * scale)
                            .animation(.spring(response: 0.8, dampingFraction: 0.6), value: progressValue)
                    }
                }
                .frame(height: 12 * scale)

                // Total count or validation progress status
                if isValidationComplete {
                    Text("Total: \(getLiveTotalCount()) items")
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if let preCacheProgress = inspectState.preCacheProgress {
                    // Pre-cache phase: Loading plist files
                    Text("Loading configuration files... \(preCacheProgress.loaded)/\(preCacheProgress.total)")
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if !inspectState.items.isEmpty {
                    Text("Validating \(inspectState.plistValidationResults.count) of \(inspectState.items.count) items...")
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Loading configuration...")
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32 * scale)
            .padding(.bottom, 20 * scale)
        }
    }

    // MARK: - Loading Content View (shown in content area during loading)
    @ViewBuilder
    private func loadingContentView(scale: CGFloat) -> some View {
        VStack(spacing: 16 * scale) {
            Spacer()

            if inspectState.items.isEmpty {
                // Indeterminate spinner while loading config
                ProgressView()
                    .scaleEffect(1.5)
                Text("Loading configuration...")
                    .font(.system(size: 14 * scale))
                    .foregroundStyle(.secondary)
            } else {
                // Show category placeholders during validation
                Text("Preparing compliance data...")
                    .font(.system(size: 14 * scale))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Filtered Categories (for search)
    private var filteredCategories: [ComplianceCategory] {
        guard !searchText.isEmpty else { return categories }
        return categories.filter { category in
            // Match category name
            if category.name.localizedCaseInsensitiveContains(searchText) {
                return true
            }
            // Match any item in category
            return category.items.contains { item in
                item.id.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    // MARK: - Category Content View (category grid with expand/collapse)
    @ViewBuilder
    private func categoryContentView(scale: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Search bar and controls row
            HStack(spacing: 16 * scale) {
                // Search bar
                HStack(spacing: 8 * scale) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13 * scale))
                        .foregroundStyle(.secondary)

                    TextField("Search rules...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13 * scale))

                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13 * scale))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12 * scale)
                .padding(.vertical, 8 * scale)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(.rect(cornerRadius: 8 * scale))

                Spacer()

                // Search results count (when filtering)
                if !searchText.isEmpty {
                    Text("\(filteredCategories.count) of \(categories.count) categories")
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(.secondary)
                }

                // Expand/Collapse All Toggle
                Button(action: {
                    let targetCategories = filteredCategories
                    let isAllExpanded = targetCategories.allSatisfy { expandedCategories.contains($0.name) }
                    let categoryNames = targetCategories.map { $0.name }

                    // Staggered animation for visual polish
                    for (index, name) in categoryNames.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.03) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                if isAllExpanded {
                                    expandedCategories.remove(name)
                                } else {
                                    expandedCategories.insert(name)
                                }
                            }
                        }
                    }
                }) {
                    HStack(spacing: 4 * scale) {
                        let targetCategories = filteredCategories
                        let isAllExpanded = targetCategories.allSatisfy { expandedCategories.contains($0.name) }
                        Image(systemName: isAllExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                            .font(.system(size: 12 * scale))
                        Text(isAllExpanded ? "Collapse All" : "Expand All")
                            .font(.system(size: 12 * scale, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 32 * scale)
            .padding(.vertical, 12 * scale)

            // Category Breakdown Section - More spacious grid layout with staggered appearance
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(minimum: 340 * scale), spacing: 32 * scale),
                    GridItem(.flexible(minimum: 340 * scale), spacing: 32 * scale)
                ], spacing: 32 * scale) {
                    ForEach(Array(filteredCategories.enumerated()), id: \.element.name) { index, category in
                        CategoryCardView(
                            category: category,
                            scale: scale,
                            colorThresholds: inspectState.colorThresholds,
                            inspectState: inspectState,
                            isExpanded: Binding(
                                get: { expandedCategories.contains(category.name) },
                                set: { newValue in
                                    if newValue {
                                        expandedCategories.insert(category.name)
                                    } else {
                                        expandedCategories.remove(category.name)
                                    }
                                }
                            )
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)),
                            removal: .opacity
                        ))
                        .animation(
                            .spring(response: 0.4, dampingFraction: 0.8)
                            .delay(Double(index) * 0.04),  // 40ms stagger per card
                            value: hasCategories
                        )
                    }
                }
                .padding(.horizontal, 32 * scale)
                .padding(.top, 20 * scale)
                .animation(.easeInOut(duration: 0.3), value: filteredCategories.count)
            }
        }
    }

    // MARK: - Footer Section (Always renders immediately)
    @ViewBuilder
    private func footerSection(scale: CGFloat) -> some View {
        // Get popup button text with fallback (config may not be loaded yet)
        let popupButtonText = {
            let configText = inspectState.config?.popupButton
            let uiText = inspectState.uiConfiguration.popupButtonText
            // Use config value first, then UI config, then fallback
            if let text = configText, !text.isEmpty {
                return text
            } else if !uiText.isEmpty && uiText != "Install details..." {
                return uiText
            }
            return "View Details"  // Sensible fallback for compliance dashboard
        }()

        HStack(spacing: 20 * scale) {
            // Popup button for details
            Button(popupButtonText) {
                showingAboutPopover.toggle()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .font(.body)
            .disabled(!hasCategories)  // Enable once categories are built (allows viewing details during validation)
            .popover(isPresented: $showingAboutPopover, arrowEdge: .top) {
                ComplianceDetailsPopoverView(
                    complianceData: categories,
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
                }

                // Final button with guaranteed fallback
                let finalButtonText: String = {
                    if let configText = inspectState.config?.finalButtonText, !configText.isEmpty {
                        return configText
                    }
                    if !inspectState.buttonConfiguration.button1Text.isEmpty {
                        return inspectState.buttonConfiguration.button1Text
                    }
                    return "OK"  // Fallback for compliance dashboard
                }()

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
        .padding(.vertical, 20 * scale)
    }

    // MARK: - Icon Resolution Methods

    // Icon caching now handled by PresetIconCache

    // MARK: - Private Methods

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

    // Helper to get category for an item
    private func getItemCategory(_ item: InspectConfig.ItemConfig) -> String {
        if let itemCategory = item.category {
            return itemCategory
        } else if let plistKey = item.plistKey,
                  let firstSource = inspectState.plistSources?.first {
            return getCategoryForKey(plistKey, source: firstSource)
        } else {
            return "Applications"
        }
    }

    // Helper to get criticality for an item
    private func getItemCriticality(_ item: InspectConfig.ItemConfig) -> Bool {
        if let plistKey = item.plistKey,
           let firstSource = inspectState.plistSources?.first {
            return isCriticalKey(plistKey, source: firstSource)
        }
        return false
    }
    
    private func getCurrentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
    
    private func categorizeItems(_ items: [ComplianceItem]) -> [ComplianceCategory] {
        let grouped = Dictionary(grouping: items) { $0.category }

        return grouped.map { category, categoryItems in
            let passed = categoryItems.filter { $0.finding }.count
            let total = categoryItems.count
            let score = total > 0 ? Double(passed) / Double(total) : 0.0

            return ComplianceCategory(
                name: category,
                passed: passed,
                total: total,
                score: score,
                icon: getCategoryIcon(category),
                items: categoryItems  // Include items to avoid re-validation in child views
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
    
    // PERF: Use cached icon - cache built once in computeComplianceData()
    private func getCategoryIcon(_ category: String) -> String {
        return categoryIconCache[category] ?? computeCategoryIconUncached(category)
    }

    // Actual icon computation (called once per category to build cache)
    private func computeCategoryIconUncached(_ category: String) -> String {
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
        return categories.reduce(0) { $0 + $1.total }
    }

    private func getPassedCount() -> Int {
        return categories.reduce(0) { $0 + $1.passed }
    }
    
    private func getFailedCount() -> Int {
        return getTotalChecks() - getPassedCount()
    }

    // Live calculation methods using cached state (no state mutation to avoid re-render loops)
    private func getLivePassedCount() -> Int {
        // Use categories state which is computed once and cached
        return categories.reduce(0) { $0 + $1.passed }
    }

    private func getLiveTotalCount() -> Int {
        return categories.reduce(0) { $0 + $1.total }
    }

    private func getLiveFailedCount() -> Int {
        return getLiveTotalCount() - getLivePassedCount()
    }

    private func getLiveOverallScore() -> Double {
        // Use cached overallScore from state
        return overallScore
    }

    private func getOverallStatusText() -> String {
        let score = overallScore
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
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let triggerContent = "button_text=\(buttonText)\ntimestamp=\(timestamp)\nstatus=completed\n"
        if let data = triggerContent.data(using: .utf8) {
            try? data.write(to: URL(fileURLWithPath: finalTriggerFilePath), options: .atomic)
            writeLog("Preset5: Created trigger file at \(finalTriggerFilePath)", logLevel: .debug)
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

/// Badge-style stat display (like Audit Builder Hub)
struct StatBadge: View {
    let value: Int
    let label: String
    let color: Color
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 4 * scale) {
            Text("\(value)")
                .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
            Text(label)
                .font(.system(size: 11 * scale, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 6 * scale)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

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
    @Binding var isExpanded: Bool  // Controlled by parent for expand/collapse all
    @State private var showingCategoryHelp = false
    @State private var animateProgress = false
    @State private var cachedSortedItems: [CategoryItemData] = []  // PERF: Cache sorted items
    @State private var cachedValidationProgress: Double = 0  // PERF: Cache to avoid recomputing on every render
    @State private var cachedIsFullyValidated: Bool = false

    // PERF: Simple accessor for cached value - actual computation in updateValidationProgress()
    private var categoryValidationProgress: Double { cachedValidationProgress }
    private var isCategoryFullyValidated: Bool { cachedIsFullyValidated }

    // PERF: Compute validation progress only when validation count changes
    private func updateValidationProgress() {
        let total = category.items.count
        guard total > 0 else {
            cachedValidationProgress = 1.0
            cachedIsFullyValidated = true
            return
        }
        var validatedCount = 0
        for item in category.items {
            if inspectState.plistValidationResults[item.id] != nil {
                validatedCount += 1
            }
        }
        cachedValidationProgress = Double(validatedCount) / Double(total)
        cachedIsFullyValidated = validatedCount == total
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with category title - tappable to expand/collapse
            HStack {
                HStack(spacing: 8 * scale) {
                    // Chevron indicator
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12 * scale, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16 * scale)

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

                // Compact progress indicator in header (always visible)
                Text("\(category.passed)/\(category.total)")
                    .font(.system(size: 12 * scale, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                // Status badge - shows shimmer effect while validating
                if isCategoryFullyValidated {
                    Text(getStatusText())
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundStyle(colorThresholds.getColor(for: category.score))
                        .padding(.horizontal, 10 * scale)
                        .padding(.vertical, 4 * scale)
                        .background(
                            Capsule()
                                .fill(colorThresholds.getColor(for: category.score).opacity(0.1))
                        )
                } else {
                    // Validating state with shimmer
                    Text("Validating...")
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10 * scale)
                        .padding(.vertical, 4 * scale)
                        .background(
                            Capsule()
                                .fill(Color.gray.opacity(0.15))
                        )
                        .shimmer()
                }
            }
            .padding(.horizontal, 20 * scale)
            .padding(.top, 20 * scale)
            .padding(.bottom, isCategoryFullyValidated ? 16 * scale : 8 * scale)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Per-card validation progress bar (shows during validation)
            if !isCategoryFullyValidated {
                VStack(spacing: 4 * scale) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background track
                            RoundedRectangle(cornerRadius: 2 * scale)
                                .fill(Color.gray.opacity(0.15))
                                .frame(height: 4 * scale)

                            // Progress fill
                            RoundedRectangle(cornerRadius: 2 * scale)
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: geometry.size.width * categoryValidationProgress, height: 4 * scale)
                                .animation(.easeInOut(duration: 0.3), value: categoryValidationProgress)
                        }
                    }
                    .frame(height: 4 * scale)
                    .padding(.horizontal, 20 * scale)

                    // Validation status text
                    let validatedCount = Int(categoryValidationProgress * Double(category.items.count))
                    Text("Validating \(validatedCount)/\(category.items.count)...")
                        .font(.system(size: 9 * scale, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 12 * scale)
            }

            // Only show divider and content when expanded
            if isExpanded {
                // Divider
                Divider()
                    .padding(.horizontal, 20 * scale)

                // Main content area: Items list on left, Progress indicator on right
                HStack(alignment: .top, spacing: 24 * scale) {
                    // Items list - takes up most space
                    ScrollView {
                        LazyVStack(spacing: 4 * scale) {
                            // PERF: Use cached sorted items instead of calling getCategoryItems() twice
                            ForEach(cachedSortedItems, id: \.id) { item in
                                ItemRowView(
                                    item: item,
                                    scale: scale,
                                    colorThresholds: colorThresholds
                                )

                                if item.id != cachedSortedItems.last?.id {
                                    Divider()
                                        .padding(.horizontal, 16 * scale)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220 * scale)
                    .onAppear {
                        // PERF: Cache sorted items once when expanded
                        if cachedSortedItems.isEmpty {
                            cachedSortedItems = getCategoryItems()
                        }
                    }

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
            updateValidationProgress()  // PERF: Initialize cached values
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6).delay(0.1)) {
                animateProgress = true
            }
        }
        .onChange(of: inspectState.plistValidationResults.count) { _, newCount in
            updateValidationProgress()  // PERF: Update only when validation count changes
            // Ensure final update when ALL validation completes
            if newCount == inspectState.items.count {
                updateValidationProgress()
            }
        }
        .onChange(of: category.passed) { _, _ in
            // Category was rebuilt with new values - refresh cached progress
            updateValidationProgress()
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
        // Use pre-computed items from category (already validated, no re-render loops)
        return category.items.map { complianceItem in
            // Look up displayName from inspectState.items
            let displayName = inspectState.items
                .first(where: { $0.id == complianceItem.id })?
                .displayName ?? complianceItem.id

            return CategoryItemData(
                id: complianceItem.id,
                displayName: displayName,
                isValid: complianceItem.finding,
                isCritical: complianceItem.isCritical,
                isInProgress: complianceItem.isInProgress
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
    // PERF: Removed @ObservedObject inspectState - not used in view, was causing all ItemRowViews to re-render on every state change

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
                                                .foregroundStyle(inspectState.colorThresholds.getValidationColor(isValid: inspectState.plistValidationResults[item.id] ?? false))
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
                                // PERF: Use cached validation result instead of blocking FileManager calls
                                let isValid = inspectState.plistValidationResults[item.id] ?? false
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

                                    // Show paths with cached validation status (no FileManager calls)
                                    ForEach(item.paths, id: \.self) { path in
                                        HStack {
                                            Text("Path:")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 60, alignment: .leading)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(path)
                                                    .font(.system(.caption, design: .monospaced))
                                                    .foregroundStyle(inspectState.colorThresholds.getValidationColor(isValid: isValid))
                                                    .lineLimit(2)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                    }

                                    // Status based on cached validation result
                                    HStack {
                                        Text("Status:")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 60, alignment: .leading)
                                        Text(isValid ? "✓ File exists" : "✗ File not found")
                                            .font(.caption)
                                            .foregroundStyle(inspectState.colorThresholds.getValidationColor(isValid: isValid))
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
    
    // PERF: Only use cached validation results - NEVER block main thread with sync validation
    private func isItemValid(_ item: InspectConfig.ItemConfig) -> Bool {
        // Only use cached results - validation should already be complete
        return inspectState.plistValidationResults[item.id] ?? false
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
    let items: [ComplianceItem]  // Include items to avoid re-validation
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

// MARK: - Shimmer Animation Modifier

/// Creates a subtle shimmer/skeleton loading effect for visual feedback during loading
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        gradient: Gradient(colors: [
                            .clear,
                            .white.opacity(0.4),
                            .clear
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 2)
                    .offset(x: phase * geometry.size.width * 2 - geometry.size.width)
                }
            )
            .mask(content)
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    /// Apply shimmer effect for skeleton loading states
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}
