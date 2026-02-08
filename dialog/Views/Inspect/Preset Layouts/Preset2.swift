//
//  Preset2.swift
//  dialog
//
//  Created by Henry Stamerjohann, Declarative IT GmbH, 19/07/2025
//
//  Card-based display with carousel navigation, option for banner image
//

import SwiftUI

struct Preset2View: View, InspectLayoutProtocol {
    @ObservedObject var inspectState: InspectState
    @State private var showingAboutPopover = false
    @State private var showDetailOverlay = false
    @State private var showItemDetailOverlay = false
    @State private var selectedItemForDetail: InspectConfig.ItemConfig?
    @StateObject private var iconCache = PresetIconCache()
    @State private var scrollOffset: Int = 0
    @State private var lastDownloadingItem: String?

    init(inspectState: InspectState) {
        self.inspectState = inspectState
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top section - either banner or icon
            if inspectState.uiConfiguration.bannerImage != nil {
                // Banner display
                ZStack {
                    if let bannerNSImage = iconCache.bannerImage {
                        Image(nsImage: bannerNSImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: windowSize.width, height: CGFloat(inspectState.uiConfiguration.bannerHeight))
                            .clipped()

                        // Optional title overlay on banner
                        if let bannerTitle = inspectState.uiConfiguration.bannerTitle {
                            Text(bannerTitle)
                                .font(.largeTitle)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 3, x: 2, y: 2)
                        }
                    }
                }
                .frame(width: windowSize.width, height: CGFloat(inspectState.uiConfiguration.bannerHeight))
                .onAppear { iconCache.cacheBannerImage(for: inspectState) }

                // Title below banner
                Text(inspectState.uiConfiguration.windowTitle)
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20 * scaleFactor)
                    .padding(.bottom, 20 * scaleFactor)
            } else {
                // Original icon display (when no banner is set)
                VStack(spacing: 20 * scaleFactor) {
                    // Main icon - DOMINANT visual element with FIXED height
                    IconView(
                        image: getMainIconPath(),
                        overlay: iconCache.getOverlayIconPath(for: inspectState),
                        defaultImage: "briefcase.fill",
                        defaultColour: "accent"
                    )
                    .frame(height: 120 * scaleFactor)
                    .onAppear { iconCache.cacheMainIcon(for: inspectState) }

                    // Title - positioned below icon, centered
                    Text(inspectState.uiConfiguration.windowTitle)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40 * scaleFactor)
            }

            // Rotating side messages - always visible
            if let currentMessage = inspectState.getCurrentSideMessage() {
                Text(currentMessage)
                    .font(.system(size: 11 * scaleFactor))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 50 * scaleFactor)
                    .frame(minHeight: 45 * scaleFactor)
                    .animation(.easeInOut(duration: InspectConstants.standardAnimationDuration), value: inspectState.uiConfiguration.currentSideMessageIndex)
            }

            // App cards with navigation arrows
            VStack(spacing: 6 * scaleFactor) {
                let visibleCount = sizeMode == "compact" ? 4 : (sizeMode == "large" ? 6 : 5)
                let allItemsFit = inspectState.items.count <= visibleCount

                HStack(spacing: 16 * scaleFactor) {
                    // Left arrow (hidden when all items fit)
                    if !allItemsFit {
                        Button(action: {
                            scrollLeft()
                        }) {
                            Image(systemName: "chevron.left.circle.fill")
                                .font(.system(size: 28 * scaleFactor))
                                .foregroundStyle(canScrollLeft() ? Color(hex: inspectState.uiConfiguration.highlightColor) : .gray.opacity(0.3))
                        }
                        .disabled(!canScrollLeft())
                        .buttonStyle(PlainButtonStyle())
                    }

                    // App cards - show 5 at a time
                    HStack(spacing: 12 * scaleFactor) {
                        ForEach(getVisibleItemsWithOffset(), id: \.id) { item in
                            Preset2ItemCardView(
                                item: item,
                                isCompleted: inspectState.completedItems.contains(item.id),
                                isDownloading: inspectState.downloadingItems.contains(item.id),
                                isFailed: inspectState.failedItems.contains(item.id),
                                highlightColor: inspectState.uiConfiguration.highlightColor,
                                scale: scaleFactor,
                                resolvedIconPath: getIconPathForItem(item),
                                inspectState: inspectState,
                                onInfoTapped: {
                                    selectedItemForDetail = item
                                    showItemDetailOverlay = true
                                }
                            )
                        }

                        // Fill remaining slots with placeholder cards when scrolling
                        if !allItemsFit {
                            ForEach(0..<max(0, visibleCount - getVisibleItemsWithOffset().count), id: \.self) { _ in
                                Preset2PlaceholderCardView(scale: scaleFactor)
                            }
                        }
                    }
                    .animation(.easeInOut(duration: InspectConstants.standardAnimationDuration), value: scrollOffset)
                    .animation(.easeInOut(duration: InspectConstants.longAnimationDuration), value: inspectState.completedItems.count)
                    .animation(.easeInOut(duration: InspectConstants.longAnimationDuration), value: inspectState.downloadingItems.count)
                    .onChange(of: inspectState.downloadingItems) { _, _ in
                        updateScrollForProgress()
                    }
                    .onChange(of: inspectState.completedItems) { _, _ in
                        updateScrollForProgress()
                    }

                    // Right arrow (hidden when all items fit)
                    if !allItemsFit {
                        Button(action: {
                            scrollRight()
                        }) {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 28 * scaleFactor))
                                .foregroundStyle(canScrollRight() ? Color(hex: inspectState.uiConfiguration.highlightColor) : .gray.opacity(0.3))
                        }
                        .disabled(!canScrollRight())
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 40 * scaleFactor)
            }

            Spacer()
                //.frame(maxHeight: 30 * scaleFactor)

            // Bottom progress section
            VStack(spacing: 12) {
                // Progress bar
                ProgressView(value: Double(inspectState.completedItems.count), total: Double(inspectState.items.count))
                    .progressViewStyle(.linear)
                    .frame(width: 600 * scaleFactor)
                    .tint(Color(hex: inspectState.uiConfiguration.highlightColor))

                // Progress text (customizable via uiLabels.progressFormat)
                Text(getProgressText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 16 * scaleFactor)

            // Bottom buttons
            HStack {
                // Install details button (always visible)
                Button(inspectState.uiConfiguration.popupButtonText) {
                    showingAboutPopover.toggle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .font(.body)
                .popover(isPresented: $showingAboutPopover) {
                    InstallationInfoPopoverView(inspectState: inspectState)
                }

                Spacer()

                // Action buttons (appear when complete)
                HStack(spacing: 20 * scaleFactor) {
                    // About button or Button2 if configured
                    if inspectState.buttonConfiguration.button2Visible {
                        Button(action: {
                            // Check if we're in demo mode and button says "Create Config"
                            if inspectState.configurationSource == .testData && inspectState.buttonConfiguration.button2Text == "Create Config" {
                                writeLog("Preset2LayoutServiceBased: Creating sample configuration", logLevel: .info)
                                inspectState.createSampleConfiguration()
                            } else {
                                // Normal button2 action - typically quits with code 2
                                writeLog("Preset2LayoutServiceBased: User clicked button2", logLevel: .info)
                                exit(2)
                            }
                        }) {
                            Text(inspectState.buttonConfiguration.button2Text)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        // Show immediately in demo mode, otherwise show when complete
                        .opacity((inspectState.configurationSource == .testData || inspectState.completedItems.count == inspectState.items.count) ? 1.0 : 0.0)
                    }

                    // Main action button - uses finalButtonText with fallback chain
                    let finalButtonText = inspectState.config?.finalButtonText ??
                                         inspectState.config?.button1Text ??
                                         (inspectState.buttonConfiguration.button1Text.isEmpty ? "Continue" : inspectState.buttonConfiguration.button1Text)

                    Button(action: {
                        writeLog("Preset2LayoutServiceBased: User clicked button1 (\(finalButtonText))", logLevel: .info)
                        exit(0)
                    }) {
                        Text(finalButtonText)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(inspectState.buttonConfiguration.button1Disabled)
                    .opacity(inspectState.completedItems.count == inspectState.items.count ? 1.0 : 0.0)
                }
            }
            .padding(.horizontal, 40 * scaleFactor)
            .padding(.bottom, 24 * scaleFactor)
        }
        //.frame(width: windowSize.width, height: windowSize.height)
        .background(Color(NSColor.windowBackgroundColor))
        .ignoresSafeArea()
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
        .onAppear {
            writeLog("Preset2LayoutServiceBased: Using InspectState", logLevel: .info)
        }
    }

    // MARK: - Navigation Methods

    private func canScrollLeft() -> Bool {
        scrollOffset > 0
    }

    private func canScrollRight() -> Bool {
        let visibleCount = sizeMode == "compact" ? 4 : (sizeMode == "large" ? 6 : 5)
        return scrollOffset + visibleCount < inspectState.items.count
    }

    private func scrollLeft() {
        if canScrollLeft() {
            scrollOffset = max(0, scrollOffset - 1)  // Shift by 1 for smoother navigation
        }
    }

    private func scrollRight() {
        if canScrollRight() {
            let visibleCount = sizeMode == "compact" ? 4 : (sizeMode == "large" ? 6 : 5)
            scrollOffset = min(inspectState.items.count - visibleCount, scrollOffset + 1)  // Shift by 1
        }
    }

    private func getVisibleItemsWithOffset() -> [InspectConfig.ItemConfig] {
        // Adjust visible cards based on size mode
        let visibleCount: Int
        switch sizeMode {
        case "compact": visibleCount = 4  // increased from 3 to 4
        case "large": visibleCount = 6
        default: visibleCount = 5  // standard - increased from 4 to 5
        }

        let startIndex = scrollOffset
        let endIndex = min(startIndex + visibleCount, inspectState.items.count)

        if startIndex >= inspectState.items.count {
            return []
        }

        return Array(inspectState.items[startIndex..<endIndex])
    }

    // MARK: - Icon Management

    private func getMainIconPath() -> String {
        return iconCache.getMainIconPath(for: inspectState)
    }




    private func getIconPathForItem(_ item: InspectConfig.ItemConfig) -> String {
        return iconCache.getItemIconPath(for: item, state: inspectState)
    }

    // MARK: - Auto-centering for downloading items

    private func updateScrollForProgress() {
        // Switch here to find the currently downloading item
        guard let downloadingItem = inspectState.downloadingItems.first,
              let downloadingIndex = inspectState.items.firstIndex(where: { $0.id == downloadingItem }) else {
            return
        }

        let visibleCount = sizeMode == "compact" ? 4 : (sizeMode == "large" ? 6 : 5)

        // Optimized try to keep downloading item in view position (index 1) when possible
        // Ther ordewr should be: [1 completed] [downloading] [penidng] [pending]...
        let preferredPositionFromLeft = 1

        // Calc offset to place downloading item at preferred position
        var targetOffset = downloadingIndex - preferredPositionFromLeft

        // Set up valid range
        targetOffset = max(0, targetOffset)  // We try to don't scroll before start
        targetOffset = min(targetOffset, max(0, inspectState.items.count - visibleCount))  // Don't scroll past end - needs observation if this works better

        // Scroll to target position if different
        if targetOffset != scrollOffset {
            withAnimation(.easeInOut(duration: 0.6)) {
                scrollOffset = targetOffset
            }

            // Update here for next change
            lastDownloadingItem = downloadingItem
        }
    }

    /// Get progress bar text with template support
    private func getProgressText() -> String {
        let completed = inspectState.completedItems.count
        let total = inspectState.items.count

        if let template = inspectState.config?.uiLabels?.progressFormat {
            return template
                .replacingOccurrences(of: "{completed}", with: "\(completed)")
                .replacingOccurrences(of: "{total}", with: "\(total)")
        }

        return "\(completed) of \(total) completed"
    }
}

// MARK: - Enhanced Card Views for Preset2

private struct Preset2ItemCardView: View {
    let item: InspectConfig.ItemConfig
    let isCompleted: Bool
    let isDownloading: Bool
    let isFailed: Bool
    let highlightColor: String
    let scale: CGFloat
    let resolvedIconPath: String
    let inspectState: InspectState
    let onInfoTapped: (() -> Void)?

    init(item: InspectConfig.ItemConfig, isCompleted: Bool, isDownloading: Bool, isFailed: Bool = false, highlightColor: String, scale: CGFloat, resolvedIconPath: String, inspectState: InspectState, onInfoTapped: (() -> Void)? = nil) {
        self.item = item
        self.isCompleted = isCompleted
        self.isDownloading = isDownloading
        self.isFailed = isFailed
        self.highlightColor = highlightColor
        self.scale = scale
        self.resolvedIconPath = resolvedIconPath
        self.inspectState = inspectState
        self.onInfoTapped = onInfoTapped
    }

    private var hasValidationWarning: Bool {
        // Only check validation for completed items
        guard isCompleted else { return false }
        
        // Check if item has any plist validation configuration
        let hasPlistValidation = item.plistKey != nil || 
                               inspectState.plistSources?.contains(where: { source in
                                   item.paths.contains(source.path)
                               }) == true
        
        // If item has plist validation, check the results
        if hasPlistValidation {
            return !(inspectState.plistValidationResults[item.id] ?? true)
        }
        
        return false
    }

    private func getStatusText() -> String {
        // Priority 1: Log monitor status (includes failure messages)
        if let logStatus = inspectState.logMonitorStatuses[item.id] {
            return logStatus
        }

        if isFailed {
            // Use custom failed status if available
            return inspectState.config?.uiLabels?.failedStatus ?? "Failed"
        } else if isCompleted {
            if hasValidationWarning {
                // Use custom validation warning text if available, otherwise default
                return inspectState.config?.uiLabels?.failedStatus ?? "Failed"
            } else if let bundleInfo = inspectState.getBundleInfoForItem(item) {
                return bundleInfo
            } else {
                // Use the new customization system for completed status
                if let customStatus = item.completedStatus {
                    return customStatus
                } else if let globalStatus = inspectState.config?.uiLabels?.completedStatus {
                    return globalStatus
                } else {
                    return "Completed"
                }
            }
        } else if isDownloading {
            // Use the new customization system for downloading status
            if let customStatus = item.downloadingStatus {
                return customStatus
            } else if let globalStatus = inspectState.config?.uiLabels?.downloadingStatus {
                return globalStatus
            } else {
                return "Installing..."
            }
        } else {
            // Use the new customization system for pending status
            if let customStatus = item.pendingStatus {
                return customStatus
            } else if let globalStatus = inspectState.config?.uiLabels?.pendingStatus {
                return globalStatus
            } else {
                return "Waiting"
            }
        }
    }

    private func getStatusColor() -> Color {
        if isFailed {
            return .red
        } else if isCompleted {
            return hasValidationWarning ? .orange : .green
        } else if isDownloading {
            return .blue
        } else {
            return .gray
        }
    }

    var body: some View {
        VStack(spacing: 4 * scale) {
            // Icon with status overlay
            ZStack {
                // Item icon - larger size
                IconView(image: resolvedIconPath, defaultImage: "app.fill", defaultColour: "accent")
                    .frame(width: 90 * scale, height: 90 * scale)
                    .clipShape(.rect(cornerRadius: 16 * scale))

                // Info button overlay (top-left) - only show if detailOverlay or itemOverlay is configured
                if onInfoTapped != nil && (inspectState.config?.detailOverlay != nil || item.itemOverlay != nil) {
                    VStack {
                        HStack {
                            Button(action: {
                                onInfoTapped?()
                            }) {
                                ZStack {
                                    Circle()
                                        .foregroundStyle(.white.opacity(0.8))
                                    Image(systemName: "info")
                                        .font(.system(size: 8 * scale, weight: .semibold))
                                        .foregroundStyle(.blue)
                                }
                                .frame(width: 18 * scale, height: 18 * scale)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Show item information")

                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(4 * scale)
                }

                // Status indicator overlay (top-right)
                VStack {
                    HStack {
                        Spacer()
                        if isFailed {
                            // Red circle with X for failed
                            Circle()
                                .fill(Color.red)
                                .frame(width: 26 * scale, height: 26 * scale)
                                .overlay(
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12 * scale, weight: .bold))
                                        .foregroundStyle(.white)
                                )
                                .help("Installation failed")
                        } else if isCompleted {
                            Circle()
                                .fill(hasValidationWarning ? Color.orange : Color.green)
                                .frame(width: 26 * scale, height: 26 * scale)
                                .overlay(
                                    Image(systemName: hasValidationWarning ? "exclamationmark" : "checkmark")
                                        .font(.system(size: 12 * scale, weight: .bold))
                                        .foregroundStyle(.white)
                                )
                                .help(hasValidationWarning ?
                                      "Configuration validation failed - check plist settings" :
                                      "\(getStatusText()) and validated")
                        } else if isDownloading {
                            // Blue circle with white spinner - matches checkmark style
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 26 * scale, height: 26 * scale)
                                .overlay(
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .tint(Color.white)
                                        .colorScheme(.dark)  // Makes spinner white
                                )
                        }
                    }
                    Spacer()
                }
                .padding(2 * scale)
            }

            // App name and status
            VStack(spacing: 2 * scale) {
                Text(item.displayName)
                    .font(.system(size: 12 * scale, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isDownloading ? Color(hex: highlightColor) : .primary)

                // Status text
                Text(getStatusText())
                    .font(.system(size: 9 * scale))
                    .foregroundStyle(getStatusColor())
            }
            .frame(width: 110 * scale, height: 35 * scale)
        }
        .frame(width: 130 * scale, height: 160 * scale)
        .padding(6 * scale)
        .background(
            RoundedRectangle(cornerRadius: 10 * scale)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10 * scale)
                        .stroke(isDownloading ? Color(hex: highlightColor).opacity(0.5) : Color.gray.opacity(0.15),
                               lineWidth: isDownloading ? 1.5 : 1)
                )
        )
        .opacity(isCompleted ? 1.0 : (isDownloading ? 1.0 : 0.75))
        .animation(.easeInOut(duration: 0.3), value: isCompleted)
        .animation(.easeInOut(duration: 0.3), value: isDownloading)
    }
}

private struct Preset2PlaceholderCardView: View {
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 4 * scale) {
            RoundedRectangle(cornerRadius: 14 * scale)
                .fill(Color.gray.opacity(0.05))
                .frame(width: 72 * scale, height: 72 * scale)

            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.05))
                .frame(width: 70 * scale, height: 10 * scale)
        }
        .frame(width: 110 * scale, height: 120 * scale)
        .padding(6 * scale)
    }
}

// MARK: - Item Info Popover

private struct ItemInfoPopoverView: View {
    let item: InspectConfig.ItemConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with item name
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.headline)
                        .fontWeight(.semibold)

                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            Divider()

            // Installation paths info
            if !item.paths.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "folder.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Installation Paths")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(item.paths, id: \.self) { path in
                        HStack(alignment: .top, spacing: 6) {
                            Text("→")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 12, alignment: .leading)

                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else {
                Text("No additional installation details available.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
