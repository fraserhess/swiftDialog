//
//  Preset9.swift
//  dialog
//
//  Created by Henry Stamerjohann, Declarative IT GmbH, 10/10/2025
//
//  Preset9: Modern Two-Panel Onboarding Flow
//  Modern split-screen layout with large layered content area and detailed sidebar
//  Features: Layered imagery, comprehensive progress tracking, macOS 14+ compatible
//

import SwiftUI

struct Preset9State: InspectPersistableState {
    let currentPage: Int
    let completedPages: Set<Int>
    let pickerSelections: GuidanceFormInputState?  // Persisted picker selections (optional for backward compatibility)
    let timestamp: Date
}

// Validation result for caching to prevent flickering
private struct Preset9ValidationResult {
    let isValid: Bool
    let isInstalled: Bool
    let timestamp: Date
    let source: Preset9ValidationSource
}

private enum Preset9ValidationSource {
    case fileSystem
    case plist
    case emptyPaths
}

struct Preset9View: View, InspectLayoutProtocol {
    @ObservedObject var inspectState: InspectState
    @State private var currentPage: Int = 0
    @State private var completedPages: Set<Int> = []
    @State private var showDetailOverlay = false
    @State private var showItemDetailOverlay = false
    @State private var selectedItemForDetail: InspectConfig.ItemConfig?
    @StateObject private var iconCache = PresetIconCache()
    @State private var showSuccess: Bool = false
    @State private var showResetFeedback: Bool = false
    @State private var monitoringTimer: Timer?
    @State private var validationCache: [String: Preset9ValidationResult] = [:]
    @State private var lastValidationTime: [String: Date] = [:]
    @State private var isFullscreenImagePresented: Bool = false
    @State private var fullscreenImagePath: String = ""
    
    // Persistence manager using generic InspectPersistence framework
    private let persistence = InspectPersistence<Preset9State>(presetName: "preset9")

    init(inspectState: InspectState) {
        self.inspectState = inspectState
        writeLog("Initializing - Items count: \(inspectState.items.count)")
    }

    // Calculate total pages based on number of items
    private var totalPages: Int {
        return max(1, inspectState.items.count)
    }

    // Get current page item
    private var currentPageItem: InspectConfig.ItemConfig? {
        guard currentPage < inspectState.items.count else { return nil }
        return inspectState.items[currentPage]
    }

    // MARK: - Picker Mode Helpers

    /// Check if picker mode is enabled
    private var isPickerMode: Bool {
        guard let selectionMode = inspectState.config?.pickerConfig?.selectionMode else {
            return false
        }
        return selectionMode == "single" || selectionMode == "multi"
    }

    /// Check if an item is currently selected
    private func isItemSelected(_ item: InspectConfig.ItemConfig) -> Bool {
        guard isPickerMode,
              let formState = inspectState.guidanceFormInputs["preset9_selections"] else {
            return false
        }

        let selectionMode = inspectState.config?.pickerConfig?.selectionMode ?? "none"

        if selectionMode == "single" {
            return formState.radios["selected_item"] == item.id
        } else if selectionMode == "multi" {
            return formState.checkboxes[item.id] == true
        }

        return false
    }

    /// Get count of selected items (for multi-select)
    private var selectedCount: Int {
        guard let formState = inspectState.guidanceFormInputs["preset9_selections"] else {
            return 0
        }

        let selectionMode = inspectState.config?.pickerConfig?.selectionMode ?? "none"

        if selectionMode == "multi" {
            return formState.checkboxes.values.filter { $0 }.count
        } else if selectionMode == "single" {
            return formState.radios["selected_item"] != nil ? 1 : 0
        }

        return 0
    }

    // MARK: - Picker Mode Selection Handlers

    /// Handle item selection in picker mode
    private func handleItemSelection(_ item: InspectConfig.ItemConfig) {
        guard isPickerMode else { return }

        // Initialize form state if needed
        if inspectState.guidanceFormInputs["preset9_selections"] == nil {
            inspectState.guidanceFormInputs["preset9_selections"] = GuidanceFormInputState()
        }

        let selectionMode = inspectState.config?.pickerConfig?.selectionMode ?? "none"

        switch selectionMode {
        case "single":
            // Single-select: toggle - if already selected, deselect it
            let currentSelection = inspectState.guidanceFormInputs["preset9_selections"]?.radios["selected_item"]

            if currentSelection == item.id {
                // Clicking the same item again - deselect it
                inspectState.guidanceFormInputs["preset9_selections"]?.radios.removeAll()
                writeLog("Preset9: Deselected item: \(item.id) (\(item.displayName))", logLevel: .info)
            } else {
                // Selecting a different item - clear all and select this one
                inspectState.guidanceFormInputs["preset9_selections"]?.radios.removeAll()
                inspectState.guidanceFormInputs["preset9_selections"]?.radios["selected_item"] = item.id
                writeLog("Preset9: Single-selected item: \(item.id) (\(item.displayName))", logLevel: .info)
            }

        case "multi":
            // Multi-select: toggle checkbox
            let currentState = inspectState.guidanceFormInputs["preset9_selections"]?.checkboxes[item.id] ?? false
            inspectState.guidanceFormInputs["preset9_selections"]?.checkboxes[item.id] = !currentState
            writeLog("Preset9: Multi-select toggled \(item.id) (\(item.displayName)): \(!currentState)", logLevel: .info)

        default:
            break
        }

        writeInteractionLog("item_selected", page: currentPage, itemId: item.id)
    }

    /// Validate selections before allowing completion
    private func validateSelections() -> Bool {
        guard isPickerMode else { return true } // Always valid in onboarding mode

        let allowContinue = inspectState.config?.pickerConfig?.allowContinueWithoutSelection ?? false

        // If continuation without selection is allowed, always valid
        if allowContinue {
            return true
        }

        // Check if any selection was made
        return selectedCount > 0
    }

    /// Write selections to output plist
    private func writeSelectionsToOutput() {
        guard let config = inspectState.config?.pickerConfig,
              config.returnSelections == true else {
            writeLog("Preset9: returnSelections not enabled, skipping output", logLevel: .debug)
            return
        }

        let outputPath = config.outputPath ?? "/tmp/preset9_selections.plist"
        let selectionMode = config.selectionMode ?? "none"

        // Build output data
        var outputData: [String: Any] = [
            "timestamp": Date(),
            "selectionMode": selectionMode,
            "totalItems": inspectState.items.count
        ]

        // Get selections from guidanceFormInputs
        if let formState = inspectState.guidanceFormInputs["preset9_selections"] {
            if selectionMode == "single" {
                // Single selection - return the selected item details
                if let selectedId = formState.radios["selected_item"],
                   let item = inspectState.items.first(where: { $0.id == selectedId }) {
                    outputData["selectedItem"] = [
                        "id": item.id,
                        "displayName": item.displayName,
                        "subtitle": item.subtitle ?? "",
                        "icon": item.icon ?? "",
                        "guiIndex": item.guiIndex
                    ]
                }
            } else if selectionMode == "multi" {
                // Multi selection - return array of selected items
                var selectedItems: [[String: Any]] = []
                for (itemId, isSelected) in formState.checkboxes where isSelected {
                    if let item = inspectState.items.first(where: { $0.id == itemId }) {
                        selectedItems.append([
                            "id": item.id,
                            "displayName": item.displayName,
                            "subtitle": item.subtitle ?? "",
                            "icon": item.icon ?? "",
                            "guiIndex": item.guiIndex
                        ])
                    }
                }
                outputData["selectedItems"] = selectedItems
                outputData["selectionCount"] = selectedItems.count
            }
        }

        // Write plist atomically
        do {
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: outputData,
                format: .xml,
                options: 0
            )
            try plistData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            writeLog("Preset9: Wrote selections to \(outputPath)", logLevel: .info)
        } catch {
            writeLog("Preset9: Failed to write selections plist: \(error.localizedDescription)", logLevel: .error)
        }
    }

    // Check if we're on the last page
    private var isLastPage: Bool {
        return currentPage >= totalPages - 1
    }

    // Check if all pages are complete
    private var allPagesComplete: Bool {
        return completedPages.count == totalPages
    }

    var body: some View {
        let _ = print("Rendering Preset9 Modern - currentPage: \(currentPage), totalPages: \(totalPages)")
        let _ = print("   - Button1 disabled: \(inspectState.buttonConfiguration.button1Disabled)")
        
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                // Left Panel - Main Content Area with Layered Images
                ZStack {
                    // Background gradient - per-item color if available
                    createConfigurableGradient(for: currentPageItem)
                        .ignoresSafeArea()
                    
                    // Layered content display
                    layeredContentArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    // Overlay navigation controls (top-left)
                    VStack {
                        HStack {
                            // Back button - always visible when not on first page
                            if currentPage > 0 {
                                Button(action: navigateBack) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundStyle(.white)
                                        .frame(width: 36, height: 36)
                                        .background(
                                            Circle()
                                                .fill(Color.black.opacity(0.3))
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("Previous step")
                            }
                            
                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        
                        Spacer()
                    }
                    
                    // Fullscreen image overlay within left panel only
                    if isFullscreenImagePresented {
                        LeftPanelFullscreenImageView(
                            imagePath: fullscreenImagePath,
                            basePath: inspectState.uiConfiguration.iconBasePath,
                            iconCache: iconCache,
                            isPresented: $isFullscreenImagePresented
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .zIndex(1000)
                    }
                    
                    // Fullscreen expand button - positioned in top-right corner when image is present
                    if let item = currentPageItem, let iconPath = item.icon, !iconPath.lowercased().hasPrefix("sf=") {
                        VStack {
                            HStack {
                                Spacer()
                                Button(action: {
                                    fullscreenImagePath = iconPath
                                    isFullscreenImagePresented = true
                                }) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .background(
                                            Circle()
                                                .fill(Color.black.opacity(0.7))
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("View fullscreen")
                                .padding(.trailing, 24)
                                .padding(.top, 80) // Position below the back button area
                            }
                            Spacer()
                        }
                    }

                    // Logo overlay - positioned based on logoConfig
                    if let logoConfig = inspectState.config?.logoConfig {
                        logoOverlay(config: logoConfig)
                    }
                }
                .frame(width: geometry.size.width * 0.65) // Reduced from 70% to 65%
                .animation(.easeInOut(duration: 0.3), value: isFullscreenImagePresented)
                
                // Right Panel - Detailed Sidebar (now larger)
                modernSidebar()
                    .frame(width: geometry.size.width * 0.35) // Increased from 30% to 35%
                    .background(
                        // Enhanced sidebar background with subtle gradient
                        ZStack {
                            // Base dark background
                            Rectangle()
                                .fill(Color.black.opacity(0.9))
                            
                            // Subtle gradient overlay
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.8),
                                    Color.black.opacity(0.95),
                                    Color.black.opacity(0.8)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            
                            // Very subtle accent color overlay
                            Rectangle()
                                .fill(getConfigurableAccentColor().opacity(0.03))
                        }
                    )
            }
        }
        .frame(minWidth: windowSize.width, minHeight: windowSize.height)
        .ignoresSafeArea()
        .onAppear(perform: handleViewAppear)
        .onDisappear(perform: handleViewDisappear)
        .overlay {
            // Help button (positioned according to config)
            if let helpButtonConfig = inspectState.config?.helpButton,
               helpButtonConfig.enabled ?? true {
                PositionedHelpButton(
                    config: helpButtonConfig,
                    action: { showDetailOverlay = true },
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

    // MARK: - Modern Two-Panel Layout Components

    @ViewBuilder
    private func layeredContentArea() -> some View {
        GeometryReader { geometry in
            ZStack {
                // Background layers for depth
                layeredBackgroundElements(size: geometry.size)
                
                // Main content layer - ensure it uses full available space
                if let item = currentPageItem {
                    mainContentLayer(item: item, size: geometry.size)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        ))
                } else {
                    welcomeContentLayer(size: geometry.size)
                }

                // Selection button overlay (picker mode only)
                if let item = currentPageItem, isPickerMode {
                    let isSelected = isItemSelected(item)
                    let labels = inspectState.config?.pickerLabels
                    let selectionMode = inspectState.config?.pickerConfig?.selectionMode ?? "none"

                    VStack {
                        Spacer()

                        // Floating selection button at bottom-center
                        Button(action: {
                            handleItemSelection(item)
                        }) {
                            HStack(spacing: 8) {
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                }

                                // Button text: in single-select mode, show deselect option when selected
                                let buttonText: String = {
                                    if isSelected {
                                        if selectionMode == "single" {
                                            return labels?.deselectButtonText ?? "Tap to Deselect"
                                        } else {
                                            return labels?.selectedButtonText ?? "✓ Selected"
                                        }
                                    } else {
                                        return labels?.selectButtonText ?? "Select This"
                                    }
                                }()

                                Text(buttonText)
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.green : Color.blue)
                                    .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 6)
                            )
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(isSelected ? 1.05 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
                        .padding(.bottom, 40)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)  // Ensure full geometry usage
        }
    }

    @ViewBuilder
    private func layeredBackgroundElements(size: CGSize) -> some View {
        // Subtle layered background elements for depth - positioned to not interfere with content
        ZStack {
            // Far background shapes - positioned lower to avoid top space
            Circle()
                .fill(getConfigurableTextColor().opacity(0.03))
                .frame(width: size.width * 0.8)
                .offset(x: size.width * 0.2, y: size.height * 0.1) // Moved down from -0.1
                .blur(radius: 40)
            
            // Mid background shapes - repositioned
            RoundedRectangle(cornerRadius: 40)
                .fill(getConfigurableTextColor().opacity(0.05))
                .frame(width: size.width * 0.6, height: size.height * 0.4)
                .offset(x: -size.width * 0.1, y: size.height * 0.35) // Moved down from 0.2
                .blur(radius: 20)
                .rotationEffect(.degrees(-15))
            
            // Near background accent - positioned in lower area
            if currentPage > 0 {
                RoundedRectangle(cornerRadius: 20)
                    .fill(getConfigurableAccentColor().opacity(0.1))
                    .frame(width: size.width * 0.3, height: size.height * 0.2)
                    .offset(x: size.width * 0.25, y: size.height * 0.45) // Moved down from 0.3
                    .blur(radius: 10)
                    .rotationEffect(.degrees(25))
                    .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: currentPage)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: currentPage)
    }

    @ViewBuilder
    private func mainContentLayer(item: InspectConfig.ItemConfig, size: CGSize) -> some View {
        GeometryReader { contentGeometry in
            ZStack {
                if let iconPath = item.icon {
                    if iconPath.lowercased().hasPrefix("sf=") {
                        // Large SF Symbol display - centered in available space
                        sfSymbolMainDisplay(from: iconPath)
                            .scaleEffect(0.9)
                            .background(
                                Circle()
                                    .fill(getConfigurableAccentColor().opacity(0.1))
                                    .overlay(
                                        Circle()
                                            .stroke(.white.opacity(0.1), lineWidth: 1)
                                    )
                            )
                            .position(
                                x: contentGeometry.size.width / 2,
                                y: (contentGeometry.size.height + 80) / 2
                            )
                    } else {
                        // Image display with modern styling - scaled to use full left panel
                        let availableWidth = contentGeometry.size.width
                        let availableHeight = contentGeometry.size.height - 60 // Minimal offset for back button
                        let imageWidth = availableWidth * 0.98  // Use 98% of available width
                        let imageHeight = availableHeight * 0.95 // Use 95% of available height
                        
                        AsyncImageView(
                            iconPath: iconPath,
                            basePath: inspectState.uiConfiguration.iconBasePath,
                            maxWidth: imageWidth,  // No border reduction - use full calculated size
                            maxHeight: imageHeight, // No border reduction - use full calculated size
                            fallback: { 
                                modernImagePlaceholder(for: item, size: CGSize(width: imageWidth, height: imageHeight))
                            }
                        )
                        .frame(width: imageWidth, height: imageHeight)
                        .position(
                            x: contentGeometry.size.width / 2,
                            y: (contentGeometry.size.height + 30) / 2 // Reduced offset to move image higher
                        )
                        .background(Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                        .onTapGesture {
                            fullscreenImagePath = iconPath
                            isFullscreenImagePresented = true
                        }
                    }
                } else {
                    // Placeholder - scaled to match image sizing
                    let availableWidth = contentGeometry.size.width
                    let availableHeight = contentGeometry.size.height - 60
                    let placeholderWidth = availableWidth * 0.98  // Match image scaling
                    let placeholderHeight = availableHeight * 0.95  // Match image scaling
                    
                    modernImagePlaceholder(for: item, size: CGSize(width: placeholderWidth, height: placeholderHeight))
                        .position(
                            x: contentGeometry.size.width / 2,
                            y: (contentGeometry.size.height + 30) / 2
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func welcomeContentLayer(size: CGSize) -> some View {
        GeometryReader { contentGeometry in
            ZStack {
                // Large welcome symbol - centered in available space
                VStack(spacing: 30) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 120, weight: .thin))
                        .foregroundStyle(LinearGradient(
                            colors: [getConfigurableTextColor(), getConfigurableAccentColor()],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .background(
                            Circle()
                                .fill(.white.opacity(0.05))
                                .overlay(
                                    Circle()
                                        .stroke(.white.opacity(0.1), lineWidth: 1)
                                )
                        )
                    
                    // Animated accent rings
                    ZStack {
                        Circle()
                            .stroke(getConfigurableAccentColor().opacity(0.3), lineWidth: 2)
                            .frame(width: 200, height: 200)
                            .scaleEffect(showResetFeedback ? 1.2 : 1.0)
                            .opacity(showResetFeedback ? 0.3 : 0.6)
                            .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: UUID())
                        
                        Circle()
                            .stroke(getConfigurableTextColor().opacity(0.2), lineWidth: 1)
                            .frame(width: 280, height: 280)
                            .scaleEffect(showResetFeedback ? 0.8 : 1.0)
                            .opacity(showResetFeedback ? 0.6 : 0.3)
                            .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: UUID())
                    }
                }
                .position(
                    x: contentGeometry.size.width / 2,
                    y: (contentGeometry.size.height + 60) / 2 // Center with slight offset for back button area
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func modernSidebar() -> some View {
        VStack(spacing: 0) {
            // Ultra-compact header - minimal space usage
            modernSidebarHeader()
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 16)  // Improved visual hierarchy

            // Ultra-compact progress visualization - minimal height
            modernProgressTracker()
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 20)  // Better breathing room
            
            // Maximized main content area - uses all remaining space
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {  // Improved spacing (was 6pt)
                    // Text content - now takes up most of the space with maximum room
                    modernStepCard()

                    Spacer(minLength: 12)  // Better separation
                    
                    // Compact action buttons at bottom
                    modernCompactActionButtons()
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)    // Improved breathing room (was 4pt)
                .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private func modernSidebarHeader() -> some View {
        VStack(alignment: .leading, spacing: 6) {  // Slightly increased spacing for better hierarchy
            HStack {
                VStack(alignment: .leading, spacing: 2) {  
                    HStack(spacing: 8) {
                        // Integrated category icon with step title
                        if let item = currentPageItem, let categoryIcon = item.categoryIcon {
                            CategoryIconBubble(
                                iconName: categoryIcon,
                                iconBasePath: inspectState.uiConfiguration.iconBasePath,
                                iconCache: iconCache,
                                scaleFactor: 1.0
                            )
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(getConfigurableAccentColor(for: currentPageItem).opacity(0.15))
                                    .overlay(
                                        Circle()
                                            .stroke(getConfigurableAccentColor(for: currentPageItem).opacity(0.3), lineWidth: 1.5)
                                    )
                            )
                            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                        }
                        
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Step \(currentPage + 1)")
                                .font(.system(size: 20, weight: .bold))  // Made larger and more prominent
                                .foregroundStyle(.white)
                            
                            Text(inspectState.config?.uiLabels?.guideInformationLabel ?? "Guide Information")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                
                Spacer()
                
                // Very compact page counter like Apple style
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(currentPage + 1)/\(totalPages)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))  
                        .foregroundStyle(.white)
                    
                    Text(inspectState.config?.uiLabels?.sectionsLabel ?? "SECTIONS")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .textCase(.uppercase)
                        .tracking(0.3)
                }
                .scaleEffect(showResetFeedback ? 1.1 : 1.0)
                .opacity(showResetFeedback ? 0.7 : 1.0)
                .animation(.easeInOut(duration: 0.3), value: showResetFeedback)
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.option) {
                        handleManualReset()
                    }
                }
                .help("Option-click to reset progress")
            }
        }
    }

    @ViewBuilder
    private func modernProgressTracker() -> some View {
        VStack(spacing: 10) {  // More breathing room between progress bar and dots
            // Enhanced progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.25))
                        .frame(height: 4)  // Thinner bar

                    // Current position indicator
                    RoundedRectangle(cornerRadius: 2)
                        .fill(getConfigurableAccentColor(for: currentPageItem))
                        .frame(width: geometry.size.width * (CGFloat(currentPage + 1) / CGFloat(totalPages)), height: 4)
                        .animation(.easeInOut(duration: 0.5), value: currentPage)
                }
            }
            .frame(height: 4)  // Match bar height

            // Simple dot navigation - adaptive sizing based on count
            let dotSize: CGFloat = totalPages > 10 ? 12 : (totalPages > 6 ? 14 : 16)
            let spacing: CGFloat = totalPages > 10 ? 3 : 4
            
            HStack(spacing: spacing) {
                ForEach(0..<totalPages, id: \.self) { index in
                    Button(action: {
                        navigateToPage(index)
                    }) {
                        Circle()
                            .fill(getSectionIndicatorColor(for: index))
                            .frame(width: dotSize, height: dotSize)
                            .overlay(
                                // Only show numbers if we have space
                                Group {
                                    if totalPages <= 8 {
                                        Text("\(index + 1)")
                                            .font(.system(size: dotSize * 0.5, weight: .bold))
                                            .foregroundStyle(index == currentPage ? .white : .white.opacity(0.8))
                                    }
                                }
                            )
                            .overlay(
                                Circle()
                                    .stroke(
                                        index == currentPage 
                                            ? Color.white.opacity(0.4) 
                                            : Color.clear, 
                                        lineWidth: 1
                                    )
                                    .frame(width: dotSize + 2, height: dotSize + 2)
                            )
                            .scaleEffect(index == currentPage ? 1.0 : 0.85)
                    }
                    .buttonStyle(.plain)
                    .help("Go to step \(index + 1)")
                    .animation(.easeInOut(duration: 0.3), value: currentPage)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }


    @ViewBuilder
    private func modernCompactActionButtons() -> some View {
        VStack(spacing: 8) {  // Compact spacing
            // Primary navigation button - much smaller and Apple-like
            Button(action: {
                // In picker mode, validate selections on last page
                if isPickerMode && isLastPage {
                    if validateSelections() {
                        writeSelectionsToOutput()
                        writeLog("Preset9: Picker completed - exiting", logLevel: .info)
                        exit(0)
                    } else {
                        writeLog("Preset9: Cannot finish - no selection made", logLevel: .info)
                        return
                    }
                }

                if isLastPage {
                    writeLog("Preset9: Guide completed - exiting", logLevel: .info)
                    exit(0)
                } else {
                    navigateForward()
                }
            }) {
                HStack(spacing: 6) {
                    // Button text with picker labels support
                    let buttonText: String = {
                        if isLastPage {
                            if isPickerMode {
                                return inspectState.config?.pickerLabels?.finishButton ?? "Close Guide"
                            }
                            return "Close Guide"
                        } else {
                            if isPickerMode {
                                return inspectState.config?.pickerLabels?.continueButton ?? "Next"
                            }
                            return "Next"
                        }
                    }()

                    Text(buttonText)
                        .font(.system(size: 14, weight: .semibold))  // Smaller font

                    // Show selection count in picker mode
                    if isPickerMode && selectedCount > 0 {
                        Text("(\(selectedCount))")
                            .font(.system(size: 12, weight: .regular))
                            .opacity(0.8)
                    }

                    if !isLastPage {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))  // Smaller icon
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))  // Smaller icon
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)  // Much smaller height - Apple style
                .background(
                    RoundedRectangle(cornerRadius: 8)  // Smaller corner radius
                        .fill(LinearGradient(
                            colors: getItemGradient(for: currentPageItem),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)  // Thinner stroke
                        )
                )
                .shadow(color: getConfigurableAccentColor(for: currentPageItem).opacity(0.2), radius: 4, x: 0, y: 2)  // Smaller shadow
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.1), value: isLastPage)
            
            // Secondary action button (only show if button2 is configured and we're on first page)
            if currentPage == 0 && inspectState.buttonConfiguration.button2Visible && !inspectState.buttonConfiguration.button2Text.isEmpty {
                Button(inspectState.buttonConfiguration.button2Text) {
                    handleButton2Action()
                }
                .font(.system(size: 12, weight: .medium))  // Smaller font
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 32)  // Smaller height
                .background(
                    RoundedRectangle(cornerRadius: 8)  // Smaller corner radius
                        .fill(Color.white.opacity(0.08))  // Subtler background
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)  // Thinner stroke
                        )
                )
                .buttonStyle(.plain)
            }
        }
    }

    // Helper function for section indicator colors (navigation-focused)
    // Now uses per-item highlightColor for colored step dots
    private func getSectionIndicatorColor(for index: Int) -> Color {
        let item = inspectState.items.indices.contains(index) ? inspectState.items[index] : nil
        let itemColor = getConfigurableAccentColor(for: item)

        if index == currentPage {
            return itemColor
        } else if index < currentPage {
            return itemColor.opacity(0.6)
        } else {
            // Future items: show their color at low opacity
            return itemColor.opacity(0.3)
        }
    }

    @ViewBuilder
    private func modernStepCard() -> some View {
        VStack(spacing: 0) {
            if let item = currentPageItem {
                VStack(alignment: .leading, spacing: 20) {  // Increased spacing for better readability
                    // Guide header with enhanced typography for prominent display
                    VStack(alignment: .leading, spacing: 10) {  // Increased header spacing
                        HStack(alignment: .top, spacing: 8) {
                            Text(item.displayName)
                                .font(.system(size: 22, weight: .bold))  // Optimized size for 35% panel
                                .foregroundStyle(.white)
                                .lineLimit(3)  // Allow more lines in wider sidebar
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(2)  // Better line spacing for multi-line titles

                            // Info button for itemOverlay
                            if item.itemOverlay != nil {
                                Button(action: {
                                    selectedItemForDetail = item
                                    showItemDetailOverlay = true
                                }) {
                                    Image(systemName: "info.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(getConfigurableAccentColor(for: item))
                                }
                                .buttonStyle(.plain)
                                .help("More information")
                            }
                        }

                        // Category or type indicator if available
                        if let stepType = item.stepType {
                            Text(stepType.uppercased())
                                .font(.system(size: 10, weight: .semibold))  // Made more prominent
                                .foregroundStyle(getConfigurableAccentColor(for: item))
                                .textCase(.uppercase)
                                .tracking(1.0)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(getConfigurableAccentColor(for: item).opacity(0.15))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(getConfigurableAccentColor(for: item).opacity(0.3), lineWidth: 0.5)
                                        )
                                )
                        }
                    }

                    // Main description/information with optimized spacing for readability
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: 15, weight: .regular))  // Optimized for wider sidebar
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(nil) // Allow unlimited lines for guide content
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(5)  // Improved line spacing for better readability
                    }

                    // Additional information with bullet points or structured content
                    if let additionalInfo = getGuideInformation(for: item) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center, spacing: 8) {
                                Image(systemName: "lightbulb.fill")
                                    .font(.system(size: 14, weight: .medium))  // Slightly larger
                                    .foregroundStyle(getConfigurableAccentColor(for: item))

                                Text(inspectState.config?.uiLabels?.keyPointsLabel ?? "Key Points")
                                    .font(.system(size: 12, weight: .bold))  // Made bolder
                                    .foregroundStyle(getConfigurableAccentColor(for: item))
                                    .textCase(.uppercase)
                                    .tracking(0.8)
                            }
                            
                            // Enhanced text formatting for bullet points and multiple paragraphs
                            Text(additionalInfo)
                                .font(.system(size: 13, weight: .regular))  // Optimized for wider space
                                .foregroundStyle(.white.opacity(0.9))  
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(4)  // Better line spacing for multiple paragraphs
                        }
                        .padding(.top, 4)
                    }
                    
                    // Add enhanced bullet point examples if available
                    if let bulletPoints = getEnhancedGuideContent(for: item) {
                        VStack(alignment: .leading, spacing: 10) {  // Increased spacing between bullets
                            ForEach(bulletPoints.indices, id: \.self) { index in
                                HStack(alignment: .top, spacing: 10) {  // Increased spacing
                                    // Enhanced bullet point indicator
                                    Circle()
                                        .fill(getConfigurableAccentColor(for: item))
                                        .frame(width: 5, height: 5)  // Slightly larger
                                        .padding(.top, 7)  // Adjusted alignment

                                    Text(bulletPoints[index])
                                        .font(.system(size: 13, weight: .regular))  // Consistent with other text
                                        .foregroundStyle(.white.opacity(0.9))
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .lineSpacing(3)  // Improved line spacing within bullets
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 20)  // Reduced from 24 for better use of space
                .padding(.vertical, 20)    
            } else {
                // Welcome state with enhanced typography for prominence
                VStack(alignment: .leading, spacing: 16) {  // Increased welcome spacing
                    VStack(alignment: .leading, spacing: 8) {
                        Text(inspectState.config?.uiLabels?.welcomeTitle ?? "Welcome")
                            .font(.system(size: 22, weight: .bold))  // Consistent with items
                            .foregroundStyle(.white)

                        Text(inspectState.config?.uiLabels?.welcomeBadge ?? "GETTING STARTED")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(getConfigurableAccentColor())
                            .textCase(.uppercase)
                            .tracking(1.0)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(getConfigurableAccentColor().opacity(0.15))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(getConfigurableAccentColor().opacity(0.3), lineWidth: 0.5)
                                    )
                            )
                    }

                    // Enhanced welcome text with better formatting
                    VStack(alignment: .leading, spacing: 14) {  // Increased spacing
                        Text(inspectState.config?.uiLabels?.welcomeParagraph1 ?? "This comprehensive guide will walk you through all the important information, settings, and steps you need to know.")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(5)  // Better line spacing

                        Text(inspectState.config?.uiLabels?.welcomeParagraph2 ?? "Take your time to read through each section carefully. Each step contains detailed information to help you understand the process.")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(4)  // Improved spacing
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func modernActionButtons() -> some View {
        VStack(spacing: 12) {
            // Primary navigation button
            Button(action: {
                // In picker mode, validate selections on last page
                if isPickerMode && isLastPage {
                    if validateSelections() {
                        writeSelectionsToOutput()
                        writeLog("Preset9: Picker completed - exiting", logLevel: .info)
                        exit(0)
                    } else {
                        writeLog("Preset9: Cannot finish - no selection made", logLevel: .info)
                        return
                    }
                }

                if isLastPage {
                    writeLog("Preset9: Guide completed - exiting", logLevel: .info)
                    exit(0)
                } else {
                    navigateForward()
                }
            }) {
                HStack(spacing: 8) {
                    // Button text with picker labels support
                    let buttonText: String = {
                        if isLastPage {
                            if isPickerMode {
                                return inspectState.config?.pickerLabels?.finishButton ?? "Close Guide"
                            }
                            return "Close Guide"
                        } else {
                            if isPickerMode {
                                return inspectState.config?.pickerLabels?.continueButton ?? "Next"
                            }
                            return "Next"
                        }
                    }()

                    Text(buttonText)
                        .font(.system(size: 16, weight: .semibold))

                    // Show selection count in picker mode
                    if isPickerMode && selectedCount > 0 {
                        Text("(\(selectedCount))")
                            .font(.system(size: 14, weight: .regular))
                            .opacity(0.8)
                    }

                    if !isLastPage {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(
                            colors: getItemGradient(for: currentPageItem),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                )
                .shadow(color: getConfigurableAccentColor(for: currentPageItem).opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.1), value: isLastPage)
            
            // Secondary action button or back button
            if currentPage > 0 {
                Button(action: navigateBack) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 14, weight: .medium))

                        Text(inspectState.config?.pickerLabels?.backButton ?? "Previous")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            } else if inspectState.buttonConfiguration.button2Visible && !inspectState.buttonConfiguration.button2Text.isEmpty {
                Button(inspectState.buttonConfiguration.button2Text) {
                    handleButton2Action()
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                )
                .buttonStyle(.plain)
            }
        }
    }



    // Helper function to generate guide information
    private func getGuideInformation(for item: InspectConfig.ItemConfig) -> String? {
        // First check if item has custom key points text (for custom configs)
        if let customText = item.keyPointsText, !customText.isEmpty {
            writeLog("Preset9: Using custom keyPointsText for item: \(item.id)", logLevel: .debug)
            return customText
        }

        // Return configuration instructions as placeholder
        let totalPages = inspectState.items.count
        let pageNumber = currentPage + 1

        return "Section \(pageNumber) of \(totalPages)\n\nTo customize this text, add \"keyPointsText\" to your item config:\n\n\"keyPointsText\": \"Your description text here. Supports multiple sentences and paragraphs.\""
    }
    
    // Helper function to generate enhanced bullet point content
    private func getEnhancedGuideContent(for item: InspectConfig.ItemConfig) -> [String]? {
        // First check if item has custom info array (for picker mode or custom configs)
        if let customInfo = item.info, !customInfo.isEmpty {
            return customInfo
        }

        // Return configuration instructions as placeholder bullets
        return [
            "Add \"info\" array to your item config:",
            "\"info\": [\"First bullet point\", \"Second bullet point\"]",
            "Each string becomes a bullet point",
            "Supports any number of items"
        ]
    }

    @ViewBuilder
    private func stepInformationCard() -> some View {
        // This is now handled by modernStepCard()
        modernStepCard()
    }

    @ViewBuilder
    private func minimalActionButtons() -> some View {
        // This is now handled by modernActionButtons()
        modernActionButtons()
    }

    private func sfSymbolMainDisplay(from iconPath: String) -> some View {
        // Parse SF Symbol for main display
        let components = iconPath.components(separatedBy: ",")
        var symbolName = "questionmark.circle"
        var weight = Font.Weight.light
        var color1 = getConfigurableTextColor()
        var color2: Color?

        for component in components {
            let parts = component.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                
                switch key {
                case "sf":
                    symbolName = value
                case "weight":
                    weight = parseWeight(value)
                case "colour1", "color1":
                    color1 = Color(hex: value)
                case "colour2", "color2":
                    color2 = Color(hex: value)
                default:
                    break
                }
            }
        }

        return Group {
            if let color2 = color2 {
                Image(systemName: symbolName)
                    .font(.system(size: 140, weight: weight))
                    .foregroundStyle(LinearGradient(colors: [color1, color2], startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 140, weight: weight))
                    .foregroundStyle(color1)
            }
        }
    }

    // swiftlint:disable:next function_body_length
    private func modernImagePlaceholder(for item: InspectConfig.ItemConfig, size: CGSize) -> some View {
        ZStack {
            // Background with proper sizing that accounts for the border
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            getConfigurableTextColor().opacity(0.05),
                            getConfigurableTextColor().opacity(0.02)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                )
            
            // Centered content
            VStack(spacing: 20) {
                Image(systemName: getMinimalIcon(for: currentPage))
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(getConfigurableTextColor().opacity(0.6))
                
                Text("Step \(currentPage + 1)")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(getConfigurableTextColor().opacity(0.8))
            }
        }
        .frame(width: size.width, height: size.height)  // Use the provided size which already accounts for borders
    }

    @ViewBuilder
    private func compactStatusBadge() -> some View {
        Image(systemName: getStatusIcon())
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(getStatusColor())
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.3), lineWidth: 2)
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
    }

    // MARK: - Legacy Components (for compatibility)

    @ViewBuilder
    private func fullSpanImageArea() -> some View {
        GeometryReader { geometry in
            if let item = currentPageItem {
                // Display the full-span image
                if let iconPath = item.icon {
                    // Handle SF Symbol icons
                    if iconPath.lowercased().hasPrefix("sf=") {
                        // For SF Symbols, create a nice background with the symbol
                        ZStack {
                            // Gradient background for SF Symbols - use per-item colors if available
                            createConfigurableGradient(for: item)
                            
                            // Large SF Symbol
                            sfSymbolView(from: iconPath)
                                .scaleEffect(0.8)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    } else {
                        // Handle image files - full span
                        AsyncImageView(
                            iconPath: iconPath,
                            basePath: inspectState.uiConfiguration.iconBasePath,
                            maxWidth: geometry.size.width,
                            maxHeight: geometry.size.height,
                            fallback: { 
                                fullSpanPlaceholderContent(
                                    for: item,
                                    width: geometry.size.width,
                                    height: geometry.size.height
                                ) 
                            }
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    }
                } else {
                    // Enhanced placeholder for full span
                    fullSpanPlaceholderContent(
                        for: item,
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                }
            } else {
                // Default welcome content - full span with configurable gradient
                ZStack {
                    createConfigurableGradient()
                    
                    VStack(spacing: 30) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 120, weight: .thin))
                            .foregroundStyle(getConfigurableTextColor())
                        
                        Text("Welcome")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(getConfigurableTextColor())
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    @ViewBuilder
    private func fullSpanPlaceholderContent(for item: InspectConfig.ItemConfig, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            // Configurable gradient background - per-item color
            createConfigurableGradient(for: item)
            
            // Subtle pattern overlay
            ZStack {
                // Large background icon
                Image(systemName: getMinimalIcon(for: currentPage))
                    .font(.system(size: min(width, height) * 0.3, weight: .ultraLight))
                    .foregroundStyle(getConfigurableTextColor().opacity(0.1))
                    .offset(x: width * 0.2, y: -height * 0.1)
                
                // Content
                VStack(spacing: 24) {
                    Image(systemName: getMinimalIcon(for: currentPage))
                        .font(.system(size: 80, weight: .light))
                        .foregroundStyle(getConfigurableTextColor())
                    
                    Text("Step \(currentPage + 1)")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(getConfigurableTextColor())
                }
            }
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private func overlayStatusIndicator() -> some View {
        HStack(spacing: 10) {
            // Status icon
            Image(systemName: getStatusIcon())
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)

            // Status text
            Text(getStatusText())
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            // Subtle step type badge (if specified)
            if let item = currentPageItem, let stepType = item.stepType {
                StepTypeIndicator(
                    stepType: stepType,
                    scaleFactor: 0.8,
                    style: .badge
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(getStatusColor().opacity(0.8))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
        .scaleEffect(0.9)
        .animation(.easeInOut(duration: 0.3), value: completedPages)
        .animation(.easeInOut(duration: 0.3), value: currentPage)
    }



    @ViewBuilder
    private func minimalPlaceholderContent(for item: InspectConfig.ItemConfig) -> some View {
        VStack(spacing: 24) {
            // Simple, elegant placeholder
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.1),
                            Color.white.opacity(0.05)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 400, height: 280)
                .overlay(
                    VStack(spacing: 20) {
                        Image(systemName: getMinimalIcon(for: currentPage))
                            .font(.system(size: 60, weight: .ultraLight))
                            .foregroundStyle(.white.opacity(0.7))
                        
                        Text("Step \(currentPage + 1)")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        }
    }


    // MARK: - Status Helper Functions
    
    // Helper functions for status overlay
    private func getStatusIcon() -> String {
        // Show overall success if all items completed
        if showSuccess {
            return "checkmark.circle.fill"
        }
        
        guard let item = currentPageItem else {
            return "circle.dotted"
        }
        
        // Check validation results and completion status
        if inspectState.completedItems.contains(item.id) {
            return "checkmark.circle.fill"
        } else if let isValid = inspectState.plistValidationResults[item.id] {
            if isValid {
                return "checkmark.circle.fill"
            } else {
                return "exclamationmark.triangle.fill" // Warning for failed validation
            }
        } else if currentPage == 0 && completedPages.isEmpty {
            return "play.circle"
        } else {
            return "circle.dotted"
        }
    }
    
    private func getStatusColor() -> Color {
        // Show success color if all items completed
        if showSuccess {
            return inspectState.colorThresholds.getColor(for: 1.0)
        }
        
        guard let item = currentPageItem else {
            return getConfigurableAccentColor()
        }
        
        // Check validation results and completion status
        if inspectState.completedItems.contains(item.id) {
            // Use configured color thresholds for completion
            return inspectState.colorThresholds.getColor(for: 1.0)
        } else if let isValid = inspectState.plistValidationResults[item.id] {
            if isValid {
                return inspectState.colorThresholds.getColor(for: 1.0) // Green for valid
            } else {
                return inspectState.colorThresholds.getColor(for: 0.6) // Warning color for invalid
            }
        } else {
            return getConfigurableAccentColor()
        }
    }
    
    private func getStatusText() -> String {
        // Show overall success if all items completed
        if showSuccess {
            return inspectState.config?.uiLabels?.completionMessage ?? "All Complete"
        }
        
        guard let item = currentPageItem else {
            if currentPage == 0 && completedPages.isEmpty {
                return "Ready to Start"
            }
            return "In Progress"
        }
        
        // Check validation results and completion status
        if inspectState.completedItems.contains(item.id) {
            return "Completed"
        } else if let isValid = inspectState.plistValidationResults[item.id] {
            if isValid {
                return "Condition Met"
            } else {
                return "Condition Not Met"
            }
        } else if inspectState.downloadingItems.contains(item.id) {
            return "Checking..."
        } else if currentPage == 0 && completedPages.isEmpty {
            return "Ready to Start"
        } else {
            return "Pending"
        }
    }

    // MARK: - Legacy Components (keeping for backward compatibility)

    @ViewBuilder
    private func minimalProgressDots() -> some View {
        HStack(spacing: 12) {
            ForEach(0..<totalPages, id: \.self) { index in
                Circle()
                    .fill(index == currentPage ? getConfigurableTextColor() : getConfigurableTextColor().opacity(0.3))
                    .frame(width: index == currentPage ? 10 : 8, height: index == currentPage ? 10 : 8)
                    .scaleEffect(index == currentPage ? 1.0 : 0.8)
                    .animation(.easeInOut(duration: 0.3), value: currentPage)
                    .onTapGesture {
                        navigateToPage(index)
                    }
            }
        }
    }

    @ViewBuilder
    private func minimalDescriptionText() -> some View {
        VStack(spacing: 12) {
            if let item = currentPageItem {
                Text(item.displayName)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(getConfigurableTextColor())
                    .multilineTextAlignment(.center)
                    .animation(.easeInOut(duration: 0.3), value: currentPage)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(getConfigurableTextColor().opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .animation(.easeInOut(duration: 0.3), value: currentPage)
                }
            } else {
                Text("Get Started")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(getConfigurableTextColor())
                    .multilineTextAlignment(.center)

                Text("Follow the steps to complete setup")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(getConfigurableTextColor().opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 60)
    }

    @ViewBuilder
    private func minimalBottomButton() -> some View {
        HStack(spacing: 16) {
            // Secondary button (Go/Skip) - left side
            if inspectState.buttonConfiguration.button2Visible && 
               !inspectState.buttonConfiguration.button2Text.isEmpty {
                Button(inspectState.buttonConfiguration.button2Text) {
                    print("Secondary button clicked!")
                    handleButton2Action()
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(height: 50)
                .padding(.horizontal, 24)
                .background(Color.white.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .buttonStyle(.plain)
            } else {
                // Placeholder secondary button for layout consistency
                Button("Go") {
                    print("Go button clicked!")
                    // Could be used for alternative action or skip
                    navigateForward()
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(height: 50)
                .padding(.horizontal, 24)
                .background(Color.white.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .buttonStyle(.plain)
            }
            
            Spacer()
            
            // Primary Continue button - blue and prominent
            Button(action: {
                print("CONTINUE CLICKED! Page: \(currentPage)")

                // In picker mode, validate selections on last page
                if isPickerMode && isLastPage {
                    if validateSelections() {
                        writeSelectionsToOutput()
                        writeLog("Preset9: Picker completed - exiting", logLevel: .info)
                        exit(0)
                    } else {
                        // Show validation error (could add alert here)
                        writeLog("Preset9: Cannot finish - no selection made", logLevel: .info)
                        return
                    }
                }

                if isLastPage {
                    writeLog("Preset9: Final step completed - exiting", logLevel: .info)
                    exit(0)
                } else {
                    navigateForward()
                }
            }) {
                HStack(spacing: 8) {
                    // Show selection indicator in picker mode
                    if isPickerMode && isLastPage && selectedCount > 0 {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .medium))
                    }

                    // Button text with picker labels support
                    let buttonText: String = {
                        if isLastPage {
                            if isPickerMode {
                                return inspectState.config?.pickerLabels?.finishButton ?? inspectState.config?.button1Text ?? "Finish"
                            }
                            return inspectState.config?.button1Text ?? "Finish"
                        } else {
                            if isPickerMode {
                                return inspectState.config?.pickerLabels?.continueButton ?? inspectState.config?.button1Text ?? "Continue"
                            }
                            return inspectState.config?.button1Text ?? "Continue"
                        }
                    }()

                    Text(buttonText)
                        .font(.system(size: 17, weight: .medium))

                    // Show selection count in picker mode
                    if isPickerMode && selectedCount > 0 {
                        Text("(\(selectedCount))")
                            .font(.system(size: 15, weight: .regular))
                            .opacity(0.8)
                    }

                    if !isLastPage {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .medium))
                    }
                }
                .foregroundStyle(.white)
                .frame(height: 50)
                .padding(.horizontal, 32)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: getItemGradient(for: currentPageItem)),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .help(isLastPage ? "Complete setup" : "Continue to next step")
        }
    }

    // Helper function for minimal icons
    private func getMinimalIcon(for pageIndex: Int) -> String {
        let minimalIcons = [
            "hand.wave",
            "gearshape",
            "arrow.down.circle",
            "checkmark.circle",
            "star",
            "shield",
            "bell",
            "checkmark.seal"
        ]
        return minimalIcons[pageIndex % minimalIcons.count]
    }

    // MARK: - Legacy View Builders (kept for compatibility)

    private func sfSymbolView(from iconPath: String) -> some View {
        // Parse SF Symbol configuration for minimal design
        let components = iconPath.components(separatedBy: ",")
        var symbolName = "questionmark.circle"
        var weight = Font.Weight.ultraLight
        var color1 = Color.white.opacity(0.8)
        var color2: Color?

        for component in components {
            let parts = component.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                
                switch key {
                case "sf":
                    symbolName = value
                case "weight":
                    weight = parseWeight(value)
                case "colour1", "color1":
                    color1 = Color(hex: value)
                case "colour2", "color2":
                    color2 = Color(hex: value)
                default:
                    break
                }
            }
        }

        // Create minimal symbol view
        return Group {
            if let color2 = color2 {
                // Gradient symbol
                Image(systemName: symbolName)
                    .font(.system(size: 100, weight: weight))
                    .foregroundStyle(LinearGradient(colors: [color1, color2], startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                // Single color symbol
                Image(systemName: symbolName)
                    .font(.system(size: 100, weight: weight))
                    .foregroundStyle(color1)
            }
        }
    }

    private func parseWeight(_ weightString: String) -> Font.Weight {
        switch weightString.lowercased() {
        case "ultralight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "regular": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return .regular
        }
    }

    @ViewBuilder
    private func placeholderContent(for item: InspectConfig.ItemConfig) -> some View {
        VStack(spacing: 20) {
            // Large placeholder rectangle mimicking a screenshot
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(
                        gradient: Gradient(colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: windowSize.width * 0.6, height: windowSize.height * 0.4)
                    .overlay(
                        VStack {
                            Image(systemName: getPlaceholderIcon(for: currentPage))
                                .font(.system(size: 60))
                                .foregroundStyle(.blue.opacity(0.6))
                            
                            Text("Step \(currentPage + 1)")
                                .font(.title2)
                                .fontWeight(.medium)
                                .multilineTextAlignment(.center)
                                .padding(.top, 10)
                        }
                    )
                    .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
            }
        }
    }

    @ViewBuilder
    private func enhancedPlaceholderContent(for item: InspectConfig.ItemConfig) -> some View {
        VStack(spacing: 24) {
            // Enhanced placeholder with more detail
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.blue.opacity(0.08),
                                Color.indigo.opacity(0.12),
                                Color.purple.opacity(0.08)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: windowSize.width * 0.6, height: windowSize.height * 0.4)
                    .overlay(
                        VStack(spacing: 16) {
                            // Dynamic icon based on step
                            Image(systemName: getEnhancedPlaceholderIcon(for: currentPage))
                                .font(.system(size: 64, weight: .medium))
                                .foregroundStyle(
                                    LinearGradient(
                                        gradient: Gradient(colors: [Color.blue, Color.indigo]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            
                            VStack(spacing: 4) {
                                Text("Step \(currentPage + 1)")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                                
                                Text(getStepDescription(for: currentPage, itemName: item.displayName))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding()
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.blue.opacity(0.3),
                                        Color.purple.opacity(0.2)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            }
        }
    }

    // MARK: - Configuration-based Color & Gradient Helpers
    
    /// Creates a configurable gradient based on JSON config or fallback to defaults
    /// - Parameter item: Optional item to get per-item gradient colors from
    private func createConfigurableGradient(for item: InspectConfig.ItemConfig? = nil) -> LinearGradient {
        // Priority 1: Check if per-item gradient colors are provided
        if let item = item, let gradientColors = item.gradientColors, !gradientColors.isEmpty {
            let colors = gradientColors.compactMap { Color(hex: $0) }
            if !colors.isEmpty {
                return LinearGradient(
                    gradient: Gradient(colors: colors),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }

        // Priority 2: Check if per-item highlight color is provided
        if let item = item, let highlightColor = item.highlightColor {
            let baseColor = Color(hex: highlightColor)
            return LinearGradient(
                gradient: Gradient(colors: [
                    baseColor.opacity(0.8),
                    baseColor.opacity(0.6),
                    baseColor.opacity(0.8)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        // Priority 3: Check if global gradient colors are provided in config
        if let gradientColors = inspectState.config?.gradientColors, !gradientColors.isEmpty {
            let colors = gradientColors.compactMap { Color(hex: $0) }
            if !colors.isEmpty {
                return LinearGradient(
                    gradient: Gradient(colors: colors),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }

        // Priority 4: Check if global highlight color is provided
        if let highlightColor = inspectState.config?.highlightColor {
            let baseColor = Color(hex: highlightColor)
            return LinearGradient(
                gradient: Gradient(colors: [
                    baseColor.opacity(0.8),
                    baseColor.opacity(0.6),
                    baseColor.opacity(0.8)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        // Fallback to system accent color based gradient
        return LinearGradient(
            gradient: Gradient(colors: [
                Color.accentColor.opacity(0.8),
                Color.accentColor.opacity(0.6),
                Color.accentColor.opacity(0.8)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    /// Gets configurable background color or image
    @ViewBuilder
    private func getConfigurableBackground() -> some View {
        if let backgroundImage = inspectState.config?.backgroundImage {
            // Try to load background image
            if let resolvedPath = iconCache.resolveImagePath(backgroundImage, basePath: inspectState.uiConfiguration.iconBasePath),
               let nsImage = NSImage(contentsOfFile: resolvedPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(inspectState.config?.backgroundOpacity ?? 1.0)
            } else {
                // Fallback to color if image fails to load
                getConfigurableBackgroundColor()
            }
        } else {
            getConfigurableBackgroundColor()
        }
    }
    
    /// Gets configurable background color
    private func getConfigurableBackgroundColor() -> Color {
        if let backgroundColor = inspectState.config?.backgroundColor {
            return Color(hex: backgroundColor)
        }
        return Color.black // Default background
    }
    
    /// Gets configurable text color for overlays
    private func getConfigurableTextColor() -> Color {
        if let textOverlayColor = inspectState.config?.textOverlayColor {
            return Color(hex: textOverlayColor)
        }
        return Color.white.opacity(0.9) // Default text color
    }
    
    /// Gets configurable accent color for status indicators and buttons
    /// If item is provided, uses item's highlightColor if set, otherwise falls back to global
    private func getConfigurableAccentColor(for item: InspectConfig.ItemConfig? = nil) -> Color {
        // First check per-item highlightColor
        if let item = item, let itemColor = item.highlightColor {
            return Color(hex: itemColor)
        }
        // Fall back to global highlightColor
        if let highlightColor = inspectState.config?.highlightColor {
            return Color(hex: highlightColor)
        }
        // Fall back to system accent color
        return Color.accentColor
    }

    /// Gets gradient colors for an item, or falls back to accent color gradient
    private func getItemGradient(for item: InspectConfig.ItemConfig?) -> [Color] {
        // Check for per-item gradient
        if let item = item, let gradientColors = item.gradientColors, gradientColors.count >= 2 {
            return gradientColors.map { Color(hex: $0) }
        }
        // Check for global gradient
        if let gradientColors = inspectState.config?.gradientColors, gradientColors.count >= 2 {
            return gradientColors.map { Color(hex: $0) }
        }
        // Fall back to accent color gradient
        let accentColor = getConfigurableAccentColor(for: item)
        return [accentColor, accentColor.opacity(0.8)]
    }

    /// Logo overlay view with configurable positioning and styling
    @ViewBuilder
    private func logoOverlay(config: InspectConfig.LogoConfig) -> some View {
        let position = config.position ?? "topleft"
        let padding = config.padding ?? 20
        let maxWidth = config.maxWidth ?? 80
        let maxHeight = config.maxHeight ?? 80
        let bgColor = config.backgroundColor.map { Color(hex: $0) } ?? Color.clear
        let bgOpacity = config.backgroundOpacity ?? 0.2
        let cornerRadius = config.cornerRadius ?? 8

        // Resolve logo image path
        if let resolvedPath = iconCache.resolveImagePath(config.imagePath, basePath: inspectState.uiConfiguration.iconBasePath),
           let nsImage = NSImage(contentsOfFile: resolvedPath) {

            let logoImage = Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(bgColor.opacity(bgOpacity))
                        .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
                )

            // Position the logo based on config
            VStack {
                if position == "bottomleft" || position == "bottomright" {
                    Spacer()
                }

                HStack {
                    if position == "topright" || position == "bottomright" {
                        Spacer()
                    }

                    logoImage

                    if position == "topleft" || position == "bottomleft" {
                        Spacer()
                    }
                }

                if position == "topleft" || position == "topright" {
                    Spacer()
                }
            }
            .padding(padding)
        }
    }

    // MARK: - Background Evaluation & Monitoring
    
    /// Triggers evaluation for a specific item (file/plist checks) with caching to prevent flickering
    private func triggerItemEvaluation(_ item: InspectConfig.ItemConfig) {
        writeLog("Preset9: Triggering evaluation for item: \(item.id)", logLevel: .info)
        
        // Log interaction for external scripts
        writeInteractionLog("evaluate_item", page: currentPage, itemId: item.id)
        
        // Check validation cache to prevent rapid re-evaluation
        let now = Date()
        if let lastValidation = lastValidationTime[item.id],
           let cachedResult = validationCache[item.id],
           now.timeIntervalSince(lastValidation) < 2.0 { // Cache for 2 seconds
            
            writeLog("Preset9: Using cached validation result for item: \(item.id)", logLevel: .debug)
            applyCachedValidationResult(item: item, result: cachedResult)
            return
        }
        
        // Skip validation for items with empty paths - treat as always valid/completed
        guard !item.paths.isEmpty else {
            writeLog("Preset9: Item \(item.id) has empty paths array - skipping validation and marking as completed", logLevel: .info)
            
            let result = Preset9ValidationResult(
                isValid: true,
                isInstalled: true,
                timestamp: now,
                source: .emptyPaths
            )
            
            cacheAndApplyValidationResult(item: item, result: result)
            return
        }
        
        // Validate the item using InspectState's validation system
        DispatchQueue.global(qos: .userInitiated).async { [inspectState] in
            // Check file system paths for completion first
            let isInstalled = item.paths.first { path in
                FileManager.default.fileExists(atPath: path)
            } != nil
            
            // For plist validation, we need to access the InspectState on the main queue
            // because it's an @ObservedObject and needs to be accessed from the main thread
            DispatchQueue.main.async {
                let isValid: Bool
                let validationSource: Preset9ValidationSource
                
                // Determine validation method and result - prioritize file existence
                if isInstalled {
                    // If file exists, it's always valid and completed
                    isValid = true
                    validationSource = .fileSystem
                } else if item.plistKey != nil || item.paths.contains(where: { $0.hasSuffix(".plist") }) {
                    // Only check plist if file doesn't exist
                    isValid = inspectState.validatePlistItem(item)
                    validationSource = .plist
                } else {
                    // For non-plist items, file existence is the only validation
                    isValid = false
                    validationSource = .fileSystem
                }
                
                writeLog("Preset9: Item \(item.id) evaluation result: isValid=\(isValid), isInstalled=\(isInstalled), source=\(validationSource)", logLevel: .info)
                
                // Create validation result
                let result = Preset9ValidationResult(
                    isValid: isValid,
                    isInstalled: isInstalled,
                    timestamp: now,
                    source: validationSource
                )
                
                // Cache and apply the result
                self.cacheAndApplyValidationResult(item: item, result: result)
            }
        }
    }
    
    /// Caches validation result and applies the outcome
    private func cacheAndApplyValidationResult(item: InspectConfig.ItemConfig, result: Preset9ValidationResult) {
        // Cache the result
        validationCache[item.id] = result
        lastValidationTime[item.id] = result.timestamp
        
        // Apply the result
        applyCachedValidationResult(item: item, result: result)
    }
    
    /// Applies a cached validation result with stable state management
    private func applyCachedValidationResult(item: InspectConfig.ItemConfig, result: Preset9ValidationResult) {
        let wasCompleted = inspectState.completedItems.contains(item.id)
        let shouldBeCompleted = result.isInstalled
        
        // Special handling for items with empty paths - once marked as completed, never remove them
        if item.paths.isEmpty && wasCompleted {
            writeLog("Preset9: Item \(item.id) has empty paths and is already completed - preserving state", logLevel: .debug)
            return
        }
        
        // Only update completion state if there's a real change
        if shouldBeCompleted && !wasCompleted {
            inspectState.completedItems.insert(item.id)
            writeLog("Preset9: Item \(item.id) marked as completed (\(result.source))", logLevel: .info)
            
            // Check for overall completion after marking an item as complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.checkForCompletion()
            }
        } else if !shouldBeCompleted && wasCompleted {
            // Only remove if we're certain from file system check
            if result.source == .fileSystem {
                inspectState.completedItems.remove(item.id)
                writeLog("Preset9: Item \(item.id) removed from completed (\(result.source))", logLevel: .info)
                
                // Check for overall completion after removing an item from complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.checkForCompletion()
                }
            }
        }
        
        // Log status change for external monitoring
        let status = result.isInstalled ? "completed" : (result.isValid ? "condition_met" : "condition_not_met")
        print("[Preset9_STATUS_CHANGE] item=\(item.id) status=\(status) source=\(result.source) cached=\(lastValidationTime[item.id] != result.timestamp)")
        
        // Write detailed status to plist for reliable monitoring
        writeStatusPlist(item: item, result: result, status: status)
    }
    
    /// Writes status to plist with error handling
    private func writeStatusPlist(item: InspectConfig.ItemConfig, result: Preset9ValidationResult, status: String) {
        let statusPath = "/tmp/Preset9_status.plist"
        let statusData: [String: Any] = [
            "timestamp": result.timestamp,
            "item_id": item.id,
            "item_name": item.displayName,
            "status": status,
            "is_valid": result.isValid,
            "is_installed": result.isInstalled,
            "validation_source": "\(result.source)",
            "cached": lastValidationTime[item.id] != result.timestamp
        ]
        
        do {
            let plistData = try PropertyListSerialization.data(fromPropertyList: statusData,
                                                               format: .xml,
                                                               options: 0)
            try plistData.write(to: URL(fileURLWithPath: statusPath), options: .atomic)
        } catch {
            writeLog("Preset9: Failed to write status plist: \(error.localizedDescription)", logLevel: .error)
        }
    }
    
    /// Starts monitoring an item when we navigate to its page
    private func startItemMonitoring(_ item: InspectConfig.ItemConfig) {
        writeLog("Preset9: Starting monitoring for item: \(item.id)", logLevel: .debug)
        
        // Immediate evaluation
        triggerItemEvaluation(item)
        
        // Log page entry for external scripts
        writeInteractionLog("page_entered", page: currentPage, itemId: item.id)
    }

    // MARK: - Navigation Methods

    private func handleButton2Action() {
        writeLog("Preset9: User clicked secondary action - exiting with code 2", logLevel: .info)
        exit(2)
    }

    private func navigateBack() {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentPage = max(0, currentPage - 1)
        }
        writeInteractionLog("navigate_back", page: currentPage)
        
        // Start monitoring the new current item
        if let currentItem = currentPageItem {
            startItemMonitoring(currentItem)
        }
        
        savePersistedState()
    }

    private func navigateForward() {
        print("navigateForward called - currentPage: \(currentPage), totalPages: \(totalPages)")
        
        // Mark current page as completed
        completedPages.insert(currentPage)
        print("   - Marked page \(currentPage) as completed")
        
        // Trigger background evaluation for current item
        if let currentItem = currentPageItem {
            triggerItemEvaluation(currentItem)
        }
        
        // Always just move to next page
        withAnimation(.easeInOut(duration: 0.3)) {
            currentPage = min(totalPages - 1, currentPage + 1)
        }
        print("   - New currentPage: \(currentPage)")
        
        writeInteractionLog("navigate_forward", page: currentPage)
        
        // Start monitoring the new current item
        if let newCurrentItem = currentPageItem {
            startItemMonitoring(newCurrentItem)
        }
        
        // Check for completion after navigation
        checkForCompletion()
        
        savePersistedState()
    }

    private func navigateToPage(_ pageIndex: Int) {
        guard pageIndex != currentPage && pageIndex >= 0 && pageIndex < totalPages else { return }
        
        withAnimation(.easeInOut(duration: 0.3)) {
            currentPage = pageIndex
        }
        writeInteractionLog("navigate_to_page", page: currentPage)
        
        // Start monitoring the new current item
        if let currentItem = currentPageItem {
            startItemMonitoring(currentItem)
        }
        
        savePersistedState()
    }

    // MARK: - Helper Methods

    private func handleManualReset() {
        writeLog("Preset9: Manual reset triggered via option-click", logLevel: .info)

        // Show visual feedback
        withAnimation {
            showResetFeedback = true
        }

        // Reset after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.resetProgress()

            // Clear feedback after reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation {
                    self.showResetFeedback = false
                }
            }
        }
    }

    private func resetProgress() {
        withAnimation(.spring()) {
            completedPages.removeAll()
            currentPage = 0
            inspectState.completedItems.removeAll()
            showSuccess = false
        }

        // Clear the persisted state
        persistence.clearState()

        writeInteractionLog("reset", page: 0)
        writeLog("Preset9: Progress reset to beginning", logLevel: .info)
        
        // Trigger evaluation/completion check after reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.checkForCompletion()
        }
    }

    private func checkForCompletion() {
        // Check if ALL items are complete, not just visible ones
        let allComplete = inspectState.items.allSatisfy { inspectState.completedItems.contains($0.id) }

        if allComplete && !showSuccess {
            withAnimation(.easeInOut(duration: 0.5).delay(0.3)) {
                showSuccess = true
            }
            writeInteractionLog("completed", page: currentPage)
            writeLog("Preset9: All items completed - showing success state", logLevel: .info)
        } else if !allComplete && showSuccess {
            // Reset success state if completion is no longer true
            withAnimation(.easeInOut(duration: 0.3)) {
                showSuccess = false
            }
            writeLog("Preset9: Success state reset - not all items completed", logLevel: .info)
        }
    }

    private func getPlaceholderIcon(for pageIndex: Int) -> String {
        let icons = ["bell.badge", "lock.shield", "arrow.down.circle", "app.badge", "square.stack.3d.up", "externaldrive.badge.timemachine", "hand.raised", "checkmark.seal"]
        return icons[pageIndex % icons.count]
    }

    private func getEnhancedPlaceholderIcon(for pageIndex: Int) -> String {
        let enhancedIcons = [
            "bell.badge.fill",           // Welcome/Introduction
            "lock.shield.fill",          // Security/Privacy
            "arrow.down.circle.fill",    // Download/Install
            "app.badge.fill",            // App Configuration
            "square.stack.3d.up.fill",   // Organization
            "externaldrive.badge.timemachine.fill", // Backup
            "hand.raised.fill",          // Permissions
            "checkmark.seal.fill"        // Completion
        ]
        return enhancedIcons[pageIndex % enhancedIcons.count]
    }

    private func getStepDescription(for pageIndex: Int, itemName: String) -> String {
        let descriptions = [
            "Getting started with \(itemName)",
            "Configuring security settings",
            "Installing required components",
            "Setting up your preferences",
            "Organizing your workspace",
            "Creating backup configuration",
            "Granting necessary permissions",
            "Finalizing setup"
        ]
        return descriptions[pageIndex % descriptions.count]
    }

    /// Handle final button press with safe callback mechanisms
    /// Writes trigger file, updates plist, logs event, then exits
    private func handleFinalButtonPress(buttonText: String) {
        writeLog("Preset9: User clicked final button (\(buttonText))", logLevel: .info)

        // 1. Write to interaction log for script monitoring
        let logPath = "/tmp/preset9_interaction.log"
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
        let triggerPath = "/tmp/preset9_final_button.trigger"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let triggerContent = "button_text=\(buttonText)\ntimestamp=\(timestamp)\nstatus=completed\n"
        if let data = triggerContent.data(using: .utf8) {
            try? data.write(to: URL(fileURLWithPath: triggerPath), options: .atomic)
            writeLog("Preset9: Created trigger file at \(triggerPath)", logLevel: .debug)
        }

        // 3. Write to plist for structured data access
        let plistPath = "/tmp/preset9_interaction.plist"
        let plistData: [String: Any] = [
            "finalButtonPressed": true,
            "buttonText": buttonText,
            "timestamp": timestamp,
            "preset": "preset9"
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plistData, format: .xml, options: 0) {
            try? data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            writeLog("Preset9: Updated interaction plist at \(plistPath)", logLevel: .debug)
        }

        // 4. Small delay to ensure file operations complete
        usleep(100000) // 100ms

        // 5. Exit with success code
        writeLog("Preset9: Exiting with code 0", logLevel: .info)
        exit(0)
    }

    // MARK: - Event Handlers

    private func handleViewAppear() {
        writeLog("Preset9: View appearing, loading state...", logLevel: .info)
        iconCache.cacheItemIcons(for: inspectState)
        iconCache.cacheBannerImage(for: inspectState)
        loadPersistedState()
        
        // Start monitoring current item
        if let currentItem = currentPageItem {
            startItemMonitoring(currentItem)
        }
        
        // Start continuous monitoring timer
        startContinuousMonitoring()
        
        // Check for completion on appear
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.checkForCompletion()
        }
    }

    private func handleViewDisappear() {
        savePersistedState()
        stopContinuousMonitoring()
    }
    
    /// Starts continuous monitoring of current item every few seconds
    private func startContinuousMonitoring() {
        stopContinuousMonitoring() // Stop any existing timer
        
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            // Re-evaluate current item periodically (reduced frequency to prevent flickering)
            if let currentItem = self.currentPageItem {
                self.triggerItemEvaluation(currentItem)
            }
        }
        
        writeLog("Preset9: Started continuous monitoring timer", logLevel: .debug)
    }
    
    /// Stops continuous monitoring
    private func stopContinuousMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        writeLog("Preset9: Stopped continuous monitoring timer", logLevel: .debug)
    }

    // MARK: - Interaction Logging

    private func writeInteractionLog(_ event: String, page: Int, itemId: String? = nil) {
        let itemInfo = itemId != nil ? " item=\(itemId!)" : ""
        print("[Preset9_INTERACTION] event=\(event) page=\(page) total=\(totalPages)\(itemInfo)")
        
        // Write to plist for reliable monitoring
        let plistPath = "/tmp/Preset9_interaction.plist"
        var interaction: [String: Any] = [
            "timestamp": Date(),
            "event": event,
            "page": page,
            "totalPages": totalPages,
            "completedPages": Array(completedPages)
        ]
        
        if let itemId = itemId {
            interaction["item_id"] = itemId
            
            // Include current status information
            if let item = inspectState.items.first(where: { $0.id == itemId }) {
                interaction["item_name"] = item.displayName
                interaction["is_completed"] = inspectState.completedItems.contains(itemId)
                interaction["is_downloading"] = inspectState.downloadingItems.contains(itemId)
                if let isValid = inspectState.plistValidationResults[itemId] {
                    interaction["validation_result"] = isValid
                }
            }
        }
        
        if let plistData = try? PropertyListSerialization.data(fromPropertyList: interaction,
                                                               format: .xml,
                                                               options: 0) {
            try? plistData.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        }
    }

    // MARK: - State Persistence

    private func savePersistedState() {
        let state = Preset9State(
            currentPage: currentPage,
            completedPages: completedPages,
            pickerSelections: inspectState.guidanceFormInputs["preset9_selections"],
            timestamp: Date()
        )
        persistence.saveState(state)

        let hasPickerData = state.pickerSelections != nil
        let selectionInfo = hasPickerData ? "picker: ✓" : "picker: ✗"
        writeLog("Preset9: State saved - page \(currentPage), completed: \(completedPages.count), \(selectionInfo)", logLevel: .debug)
    }

    private func loadPersistedState() {
        guard let state = persistence.loadState() else {
            writeLog("Preset9: No previous state found", logLevel: .debug)
            writeInteractionLog("launched", page: 0)
            return
        }

        // Check if state is stale (older than 24 hours)
        if persistence.isStateStale(state, hours: 24) {
            writeLog("Preset9: State is stale, starting fresh", logLevel: .info)
            writeInteractionLog("launched", page: 0)
            return
        }

        writeLog("Preset9: Loaded state - page: \(state.currentPage), completed: \(state.completedPages)", logLevel: .info)

        // Apply the validated state
        currentPage = min(state.currentPage, max(0, totalPages - 1))
        completedPages = state.completedPages

        // Restore picker selections if present
        if let pickerSelections = state.pickerSelections {
            inspectState.guidanceFormInputs["preset9_selections"] = pickerSelections
            let radioCount = pickerSelections.radios.count
            let checkboxCount = pickerSelections.checkboxes.filter { $0.value }.count
            writeLog("Preset9: Restored picker selections - radios: \(radioCount), checkboxes: \(checkboxCount)", logLevel: .info)
        }

        // Log the restoration
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        writeLog("Preset9: Resumed from \(formatter.string(from: state.timestamp)) - page \(currentPage)", logLevel: .info)

        writeInteractionLog("resumed", page: currentPage)
    }
}

// MARK: - Fullscreen Image View

private struct FullscreenImageView: View {
    let imagePath: String
    let basePath: String?
    let iconCache: PresetIconCache
    @Binding var isPresented: Bool
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Black background
            Color.black.ignoresSafeArea()
            
            // Full image
            AsyncImageView(
                iconPath: imagePath,
                basePath: basePath,
                maxWidth: .infinity,
                maxHeight: .infinity,
                fallback: {
                    VStack(spacing: 20) {
                        Image(systemName: "photo")
                            .font(.system(size: 60, weight: .light))
                            .foregroundStyle(.white.opacity(0.6))
                        
                        Text("Image not available")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            )
            .aspectRatio(contentMode: .fit)
            .clipped()
            
            // Close button
            Button(action: {
                isPresented = false
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .padding(20)
        }
        .onTapGesture {
            isPresented = false
        }
    }
}

// MARK: - Left Panel Fullscreen Image View

private struct LeftPanelFullscreenImageView: View {
    let imagePath: String
    let basePath: String?
    let iconCache: PresetIconCache
    @Binding var isPresented: Bool
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Semi-transparent black background
            Color.black.opacity(0.9)
                .ignoresSafeArea()
            
            // Full image within the left panel bounds
            AsyncImageView(
                iconPath: imagePath,
                basePath: basePath,
                maxWidth: .infinity,
                maxHeight: .infinity,
                fallback: {
                    VStack(spacing: 20) {
                        Image(systemName: "photo")
                            .font(.system(size: 60, weight: .light))
                            .foregroundStyle(.white.opacity(0.6))
                        
                        Text("Image not available")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            )
            .aspectRatio(contentMode: .fit)
            .clipped()
            .padding(20) // Add some padding from edges
            
            // Close button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPresented = false
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.7))
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            .padding(.trailing, 16)
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isPresented = false
            }
        }
        .onKeyPress(.escape) {
            withAnimation(.easeInOut(duration: 0.2)) {
                isPresented = false
            }
            return .handled
        }
    }
}

// MARK: - AsyncImageView Component
// Note: AsyncImageView is now imported from PresetCommonHelpers.swift
// Removed duplicate declaration (lines 2703-2837) to use shared implementation
