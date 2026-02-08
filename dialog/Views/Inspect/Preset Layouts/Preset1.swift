//
//  Preset1.swift
//  dialog
//
//  Created by Henry Stamerjohann, Declarative IT GmbH, 19/07/2025
//
//  Classic sidebar layout with FSevents based progress tracking
//  
//

import SwiftUI

struct Preset1View: View, InspectLayoutProtocol {
    @ObservedObject var inspectState: InspectState
    @State private var showingAboutPopover = false
    @State private var showDetailOverlay = false
    @State private var showItemDetailOverlay = false
    @State private var selectedItemForDetail: InspectConfig.ItemConfig?
    @StateObject private var iconCache = PresetIconCache()

    let systemImage: String = isLaptop ? "laptopcomputer.and.arrow.down" : "desktopcomputer.and.arrow.down"

    init(inspectState: InspectState) {
        self.inspectState = inspectState
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar with icon/image
            VStack {
                Spacer()
                    .frame(height: 80)  // Push icon down to center it better

                IconView(
                    image: iconCache.getMainIconPath(for: inspectState),
                    overlay: iconCache.getOverlayIconPath(for: inspectState),
                    defaultImage: "apps.iphone.badge.plus",
                    defaultColour: "accent"
                )
                .frame(width: 220 * scaleFactor, height: 220 * scaleFactor)
                .onAppear { iconCache.cacheMainIcon(for: inspectState) }

                // Progress bar
                if !inspectState.items.isEmpty {
                    PresetCommonViews.progressBar(
                        state: inspectState,
                        width: 200 * scaleFactor,
                        labelSize: 13  // Improved from caption
                    )
                    .padding(.top, 20 * scaleFactor)
                }

                Spacer()

                // Install info button - shows sheet if detailOverlay configured, otherwise popover
                Button(inspectState.uiConfiguration.popupButtonText) {
                    if inspectState.config?.detailOverlay != nil {
                        showDetailOverlay = true
                    } else {
                        showingAboutPopover.toggle()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .font(.body)
                .padding(.bottom, 20 * scaleFactor)
                .popover(isPresented: $showingAboutPopover, arrowEdge: .top) {
                    InstallationInfoPopoverView(inspectState: inspectState)
                }
            }
            .frame(width: 320 * scaleFactor)
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            // Right content area
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text(inspectState.uiConfiguration.windowTitle)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Spacer()

                    PresetCommonViews.buttonArea(state: inspectState)
                }
                .padding()

                if let currentMessage = inspectState.getCurrentSideMessage() {
                    Text(currentMessage)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal)
                        .padding(.bottom)
                        .frame(minHeight: 50)
                        .animation(.easeInOut(duration: 0.5), value: inspectState.uiConfiguration.currentSideMessageIndex)
                }

                Divider()

                // Item list
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Add top padding for better visual balance
                        Color.clear.frame(height: 60)
                        let sortedItems = PresetCommonViews.getSortedItemsByStatus(inspectState)
                        ForEach(sortedItems, id: \.id) { item in
                            // Add group separator if needed
                            if shouldShowGroupSeparator(for: item, in: sortedItems) {
                                HStack {
                                    Text(getStatusHeaderText(for: getItemStatusType(for: item)))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal)
                                .padding(.top, 10 * scaleFactor)
                                .padding(.bottom, 5 * scaleFactor)
                            }

                            itemRow(for: item)
                        }
                    }
                    .padding(.vertical, 10 * scaleFactor)
                }

                Divider()

                // Status bar
                HStack {
                    Text(inspectState.uiConfiguration.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            }
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .background(Color(NSColor.windowBackgroundColor))
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
            writeLog("Preset1View: Using refactored InspectState", logLevel: .info)
        }
    }

    // MARK: - Helper Methods

    @ViewBuilder
    private func itemRow(for item: InspectConfig.ItemConfig) -> some View {
        HStack(spacing: 12 * scaleFactor) {
            // Icon
            IconView(image: iconCache.getItemIconPath(for: item, state: inspectState))
                .frame(width: 48 * scaleFactor, height: 48 * scaleFactor)
                .aspectRatio(1, contentMode: .fit)
                .clipped()

            // Item info
            VStack(alignment: .leading, spacing: 2 * scaleFactor) {
                HStack(spacing: 4) {
                    Text(item.displayName)
                        .font(.system(size: 16 * scaleFactor, weight: .medium))
                        .foregroundStyle(.primary)

                    // Info button - only show if item has itemOverlay configured
                    if item.itemOverlay != nil {
                        Button(action: {
                            selectedItemForDetail = item
                            showItemDetailOverlay = true
                        }) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 14 * scaleFactor))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .help("View details about \(item.displayName)")
                    }
                }

                Text(getItemStatusWithValidation(for: item))
                    .font(.system(size: 13 * scaleFactor))
                    .foregroundStyle(getItemStatusColor(for: item))
            }

            Spacer()

            // Status indicator with validation support
            statusIndicatorWithValidation(for: item)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Sorting & Status

    private func getItemStatusType(for item: InspectConfig.ItemConfig) -> InspectItemStatus {
        if inspectState.failedItems.contains(item.id) { return .failed("") }
        if inspectState.completedItems.contains(item.id) { return .completed }
        if inspectState.downloadingItems.contains(item.id) { return .downloading }
        return .pending
    }

    private func shouldShowGroupSeparator(for item: InspectConfig.ItemConfig, in sortedItems: [InspectConfig.ItemConfig]) -> Bool {
        guard let index = sortedItems.firstIndex(where: { $0.id == item.id }), index > 0 else { return false }

        let previousItem = sortedItems[index - 1]
        let currentStatus = getItemStatusType(for: item)
        let previousStatus = getItemStatusType(for: previousItem)

        return currentStatus != previousStatus
    }

    private func getStatusHeaderText(for statusType: InspectItemStatus) -> String {
        switch statusType {
        case .completed:
            // Use section header if provided, otherwise fall back to status text
            return inspectState.config?.uiLabels?.sectionHeaderCompleted
                ?? inspectState.config?.uiLabels?.completedStatus
                ?? "Completed"
        case .downloading:
            // Use section header if provided, otherwise construct from status text
            if let header = inspectState.config?.uiLabels?.sectionHeaderPending {
                return header
            }
            let downloadingText = inspectState.config?.uiLabels?.downloadingStatus ?? "Installing..."
            let cleanText = downloadingText.replacingOccurrences(of: "...", with: "")
            return "Currently \(cleanText)"
        case .pending:
            // Use section header if provided, otherwise fall back to constructed text
            return inspectState.config?.uiLabels?.sectionHeaderPending ?? "Pending Installation"
        case .failed:
            // Use section header if provided, otherwise fall back to hardcoded
            return inspectState.config?.uiLabels?.sectionHeaderFailed ?? "Installation Failed"
        }
    }

    // MARK: - Validation Support

    private func hasValidationWarning(for item: InspectConfig.ItemConfig) -> Bool {
        // Only check validation for completed items  
        guard inspectState.completedItems.contains(item.id) else { return false }
        
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

    private func getItemStatusWithValidation(for item: InspectConfig.ItemConfig) -> String {
        if inspectState.completedItems.contains(item.id) {
            if hasValidationWarning(for: item) {
                // Use custom validation warning text if available, otherwise default
                return inspectState.config?.uiLabels?.failedStatus ?? "Failed"
            } else if let bundleInfo = inspectState.getBundleInfoForItem(item) {
                return bundleInfo
            } else {
                return getItemStatus(for: item)
            }
        } else {
            return getItemStatus(for: item)
        }
    }

    private func getItemStatusColor(for item: InspectConfig.ItemConfig) -> Color {
        if inspectState.failedItems.contains(item.id) {
            return .red
        } else if inspectState.completedItems.contains(item.id) {
            return hasValidationWarning(for: item) ? .orange : .green
        } else if inspectState.downloadingItems.contains(item.id) {
            return .blue
        } else {
            return .secondary
        }
    }

    @ViewBuilder
    private func statusIndicatorWithValidation(for item: InspectConfig.ItemConfig) -> some View {
        let size: CGFloat = 20 * scaleFactor

        if inspectState.failedItems.contains(item.id) {
            // Failed - show red X
            Circle()
                .fill(Color.red)
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.6, weight: .bold))
                        .foregroundStyle(.white)
                )
                .help("Installation failed")
        } else if inspectState.completedItems.contains(item.id) {
            // Completed - check for validation warnings
            Circle()
                .fill(hasValidationWarning(for: item) ? Color.orange : Color.green)
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: hasValidationWarning(for: item) ? "exclamationmark" : "checkmark")
                        .font(.system(size: size * 0.6, weight: .bold))
                        .foregroundStyle(.white)
                )
                .help(hasValidationWarning(for: item) ?
                      "Configuration validation failed - check plist settings" :
                      "Installed and validated")
        } else if inspectState.downloadingItems.contains(item.id) {
            // Downloading
            Circle()
                .fill(Color.blue)
                .frame(width: size, height: size)
                .overlay(
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Color.white)
                        .colorScheme(.dark)
                )
        } else {
            // Pending
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                .frame(width: size, height: size)
        }
    }
}