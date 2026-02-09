//
//  PresetCommonHelpers.swift
//  dialog
//
//  Created by Henry Stamerjohann, Declarative IT GmbH, 23/09/2025
//
//  Common utilities for preset layouts
//  Note: IconCache, GuidanceContentView, StatusComponents, MediaComponents,
//  ComplianceComponents, WallpaperPicker have been extracted to Components/ folder
//

import SwiftUI
import AVKit
import WebViewKit

// MARK: - Common View Components
struct PresetCommonViews {

    // MARK: Progress Bar
    @ViewBuilder
    static func progressBar(
        state: InspectState,
        width: CGFloat = 250,
        height: CGFloat = 4,
        showLabel: Bool = true,
        labelSize: CGFloat = 11
    ) -> some View {
        let progress = state.items.isEmpty ? 0.0 :
            Double(state.completedItems.count) / Double(state.items.count)

        VStack(spacing: 8) {
            ProgressView(value: progress)
                .progressViewStyle(LinearProgressViewStyle())
                .frame(width: width)
                .frame(height: height)

            if showLabel {
                Text(getProgressText(state: state))
                    .font(.system(size: labelSize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Status Indicator
    @ViewBuilder
    static func statusIndicator(
        for item: InspectConfig.ItemConfig,
        state: InspectState,
        size: CGFloat = 20
    ) -> some View {
        if state.completedItems.contains(item.id) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: size))
        } else if state.downloadingItems.contains(item.id) {
            ProgressView()
                .scaleEffect(size / 25)
                .frame(width: size, height: size)
        } else {
            Circle()
                .strokeBorder(Color.gray.opacity(0.3), lineWidth: 2)
                .frame(width: size, height: size)
        }
    }

    // MARK: Button Area
    @ViewBuilder
    static func buttonArea(
        state: InspectState,
        spacing: CGFloat = 12,
        controlSize: ControlSize = .large
    ) -> some View {
        // Check if all items are completed and auto-enable is configured
        let allItemsCompleted = !state.items.isEmpty && state.completedItems.count == state.items.count
        let shouldUseAutoEnableText = allItemsCompleted &&
                                      state.buttonConfiguration.autoEnableButton &&
                                      state.config?.autoEnableButtonText != nil

        // Determine final button text with proper fallback chain
        // Priority: autoEnableButtonText (when complete) > finalButtonText > button1Text > buttonConfiguration > "Continue"
        let finalButtonText = shouldUseAutoEnableText
            ? (state.config?.autoEnableButtonText ?? "OK")
            : (state.config?.finalButtonText ??
               state.config?.button1Text ??
               (state.buttonConfiguration.button1Text.isEmpty ? "Continue" : state.buttonConfiguration.button1Text))

        HStack(spacing: spacing) {
            // Button 2 (Secondary) - show in demo mode or when all complete
            if (state.configurationSource == .testData || state.completedItems.count == state.items.count) &&
               state.buttonConfiguration.button2Visible &&
               !state.buttonConfiguration.button2Text.isEmpty {
                Button(state.buttonConfiguration.button2Text) {
                    // Check if we're in demo mode and button is for creating configuration
                    if state.configurationSource == .testData && (state.buttonConfiguration.button2Text.contains("Create") || state.buttonConfiguration.button2Text.contains("Config")) {
                        writeLog("Preset: Creating sample configuration", logLevel: .info)
                        state.createSampleConfiguration()
                    } else {
                        writeLog("Preset: User clicked button2 - exiting with code 2", logLevel: .info)
                        exit(2)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(controlSize)
            }

            // Button 1 (Primary) - uses finalButtonText with fallback chain
            Button(finalButtonText) {
                writeLog("Preset: User clicked button1 (\(finalButtonText)) - exiting with code 0", logLevel: .info)
                exit(0)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(controlSize)
            .disabled(state.buttonConfiguration.button1Disabled)
        }
    }

    // MARK: Item Status Text
    static func getItemStatus(for item: InspectConfig.ItemConfig, state: InspectState) -> String {
        // Priority 1: Log monitor status (real-time from log file)
        if let logStatus = state.logMonitorStatuses[item.id] {
            return logStatus
        }

        // Priority 2-4: Existing status logic (completed/downloading/pending)
        if state.completedItems.contains(item.id) {
            // Priority: item-specific > global UILabels > default
            if let customStatus = item.completedStatus {
                return customStatus
            } else if let globalStatus = state.config?.uiLabels?.completedStatus {
                return globalStatus
            } else {
                return "Completed"
            }
        } else if state.downloadingItems.contains(item.id) {
            // Priority: item-specific > global UILabels > default
            if let customStatus = item.downloadingStatus {
                return customStatus
            } else if let globalStatus = state.config?.uiLabels?.downloadingStatus {
                return globalStatus
            } else {
                return "Installing..."
            }
        } else {
            // Priority: item-specific > global UILabels > default
            if let customStatus = item.pendingStatus {
                return customStatus
            } else if let globalStatus = state.config?.uiLabels?.pendingStatus {
                return globalStatus
            } else {
                return "Waiting"
            }
        }
    }

    // MARK: Progress Text
    /// Get progress bar text with template support
    /// Supports template variables: {completed}, {total}
    /// Example template: "{completed} of {total} apps installed"
    static func getProgressText(state: InspectState) -> String {
        let completed = state.completedItems.count
        let total = state.items.count

        if let template = state.config?.uiLabels?.progressFormat {
            return template
                .replacingOccurrences(of: "{completed}", with: "\(completed)")
                .replacingOccurrences(of: "{total}", with: "\(total)")
        }

        return "\(completed) of \(total) completed"
    }

    // MARK: Sorted Items
    static func getSortedItemsByStatus(_ state: InspectState) -> [InspectConfig.ItemConfig] {
        let completed = state.items.filter { state.completedItems.contains($0.id) }
        let downloading = state.items.filter { state.downloadingItems.contains($0.id) }
        let pending = state.items.filter { item in
            !state.completedItems.contains(item.id) &&
            !state.downloadingItems.contains(item.id)
        }

        return completed + downloading + pending
    }
}


// MARK: - Layout Sizing Helper
struct PresetSizing {
    static func getScaleFactor(for sizeMode: String) -> CGFloat {
        switch sizeMode {
        case "compact": return 0.85
        case "large": return 1.15
        default: return 1.0  // standard
        }
    }

    static func getWindowSize(for state: InspectState) -> CGSize {
        // Check for explicit overrides first
        if let width = state.uiConfiguration.width,
           let height = state.uiConfiguration.height {
            return CGSize(width: CGFloat(width), height: CGFloat(height))
        }

        // Use InspectSizes
        let sizeMode = state.uiConfiguration.size ?? "standard"
        let preset = state.uiConfiguration.preset
        let (width, height) = InspectSizes.getSize(preset: preset, mode: sizeMode)

        return CGSize(width: width, height: height)
    }
}


// MARK: - Category Icon Bubble Component (Shared between presets)

/// Small app icon bubble for context (e.g., Finder, Safari, Word)
struct CategoryIconBubble: View {
    let iconName: String
    let iconBasePath: String?
    let iconCache: PresetIconCache
    let scaleFactor: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 36 * scaleFactor, height: 36 * scaleFactor)
                .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.8), lineWidth: 1)
                )

            if let resolvedPath = iconCache.resolveImagePath(iconName, basePath: iconBasePath),
               let image = NSImage(contentsOfFile: resolvedPath) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24 * scaleFactor, height: 24 * scaleFactor)
                    .clipShape(Circle())
            } else {
                // Fallback to SF Symbol if image not found
                Image(systemName: getSFSymbolForApp(iconName))
                    .font(.system(size: 16 * scaleFactor, weight: .medium))
                    .foregroundStyle(.blue)
            }
        }
    }

    private func getSFSymbolForApp(_ name: String) -> String {
        let lowercased = name.lowercased()
        if lowercased.contains("finder") { return "folder.fill" }
        if lowercased.contains("safari") { return "safari.fill" }
        if lowercased.contains("word") || lowercased.contains("office") { return "doc.text.fill" }
        if lowercased.contains("excel") { return "tablecells.fill" }
        if lowercased.contains("powerpoint") { return "play.rectangle.fill" }
        if lowercased.contains("terminal") { return "terminal.fill" }
        if lowercased.contains("settings") || lowercased.contains("preferences") { return "gearshape.fill" }
        if lowercased.contains("chrome") { return "globe" }
        if lowercased.contains("firefox") { return "flame.fill" }
        if lowercased.contains("mail") { return "envelope.fill" }
        if lowercased.contains("calendar") { return "calendar" }
        if lowercased.contains("notes") { return "note.text" }
        if lowercased.contains("photos") { return "photo.fill" }
        return "app.fill"
    }
}

// MARK: - Processing Countdown View

/// Displays a processing countdown with spinner and custom message
/// Used for steps with `stepType: "processing"` and `processingDuration`
struct ProcessingCountdownView: View {
    let countdown: Int
    let message: String?
    let scaleFactor: CGFloat

    var body: some View {
        VStack(spacing: 8 * scaleFactor) {
            ProgressView()
                .scaleEffect(0.8)

            if let message = message {
                Text(message.replacingOccurrences(of: "{countdown}", with: "\(countdown)"))
                    .font(.system(size: 13 * scaleFactor))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16 * scaleFactor)
    }
}


// MARK: - Step Type Indicator Badge

/// Visual indicator showing the step type (info, confirmation, processing, completion)
/// Can be used as an overlay badge on cards or inline indicators
struct StepTypeIndicator: View {
    let stepType: String
    let scaleFactor: CGFloat
    let style: IndicatorStyle

    enum IndicatorStyle {
        case badge      // Small badge overlay
        case inline     // Inline with text
        case prominent  // Large, featured indicator
    }

    var body: some View {
        HStack(spacing: 4 * scaleFactor) {
            Image(systemName: iconName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(iconColor)

            if style == .inline || style == .prominent {
                Text(displayLabel)
                    .font(.system(size: textSize, weight: .medium))
                    .foregroundStyle(iconColor)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            Capsule()
                .fill(backgroundColor)
                .overlay(
                    Capsule()
                        .stroke(iconColor.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var iconName: String {
        switch stepType {
        case "confirmation":
            return "checkmark.circle.fill"
        case "processing":
            return "hourglass"
        case "completion":
            return "checkmark.seal.fill"
        default: // "info"
            return "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch stepType {
        case "confirmation":
            return .orange
        case "processing":
            return .purple
        case "completion":
            return .green
        default: // "info"
            return .blue
        }
    }

    private var backgroundColor: Color {
        iconColor.opacity(0.1)
    }

    private var displayLabel: String {
        switch stepType {
        case "confirmation":
            return "Confirm"
        case "processing":
            return "Processing"
        case "completion":
            return "Complete"
        default:
            return "Info"
        }
    }

    private var iconSize: CGFloat {
        switch style {
        case .badge:
            return 10 * scaleFactor
        case .inline:
            return 12 * scaleFactor
        case .prominent:
            return 16 * scaleFactor
        }
    }

    private var textSize: CGFloat {
        switch style {
        case .inline:
            return 11 * scaleFactor
        case .prominent:
            return 13 * scaleFactor
        default:
            return 0
        }
    }

    private var horizontalPadding: CGFloat {
        switch style {
        case .badge:
            return 6 * scaleFactor
        case .inline:
            return 8 * scaleFactor
        case .prominent:
            return 12 * scaleFactor
        }
    }

    private var verticalPadding: CGFloat {
        switch style {
        case .badge:
            return 4 * scaleFactor
        case .inline:
            return 5 * scaleFactor
        case .prominent:
            return 6 * scaleFactor
        }
    }
}


// MARK: - Highlight Chip Styles

/// ViewModifier for highlighting content with chip/badge style that works in both light and dark modes
/// Uses system accent color with high contrast for optimal readability
///
/// **Usage Example:**
/// ```swift
/// Text("5-10 Minutes")
///     .font(.system(size: 14, weight: .semibold, design: .monospaced))
///     .foregroundStyle(.primary)
///     .modifier(HighlightChipStyle(accentColor: .blue, scaleFactor: 1.0))
/// ```
///
/// **Features:**
/// - Automatically adapts to light/dark mode
/// - Uses `.primary` foregroundStyle for proper text contrast
/// - Configurable accent color (defaults to system accent)
/// - Scales proportionally with scaleFactor
/// - Provides depth with subtle shadow
struct HighlightChipStyle: ViewModifier {
    let accentColor: Color
    let scaleFactor: CGFloat

    init(accentColor: Color = .accentColor, scaleFactor: CGFloat = 1.0) {
        self.accentColor = accentColor
        self.scaleFactor = scaleFactor
    }

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 6 * scaleFactor)
            .padding(.horizontal, 12 * scaleFactor)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(accentColor.opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(accentColor.opacity(0.6), lineWidth: 1.5)
            )
            .shadow(color: accentColor.opacity(0.1), radius: 2, y: 1)
    }
}

/// ViewModifier for secondary/subtle highlighting with system secondary color
struct SecondaryChipStyle: ViewModifier {
    let secondaryColor: Color
    let scaleFactor: CGFloat

    init(secondaryColor: Color = .secondary, scaleFactor: CGFloat = 1.0) {
        self.secondaryColor = secondaryColor
        self.scaleFactor = scaleFactor
    }

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 6 * scaleFactor)
            .padding(.horizontal, 12 * scaleFactor)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(secondaryColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(secondaryColor.opacity(0.3), lineWidth: 1)
            )
    }
}


// MARK: - Instruction Banner Component

/// Reusable instruction banner for user guidance across all Inspect presets
/// Displays a semi-transparent banner with text and optional icon at the top of the view
struct InstructionBanner: View {
    let text: String
    let autoDismiss: Bool
    let dismissDelay: Double
    let backgroundColor: Color
    let icon: String?

    @State private var isVisible: Bool = true
    @State private var dismissTimer: Timer?

    init(
        text: String,
        autoDismiss: Bool = true,
        dismissDelay: Double = 5.0,
        backgroundColor: Color = Color.black.opacity(0.7),
        icon: String? = nil
    ) {
        self.text = text
        self.autoDismiss = autoDismiss
        self.dismissDelay = dismissDelay
        self.backgroundColor = backgroundColor
        self.icon = icon
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 12) {
                if let iconName = icon {
                    Image(systemName: iconName)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                }

                Text(text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Spacer()

                // Manual dismiss button
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Dismiss instruction")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                backgroundColor
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            )
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: isVisible)
            .onAppear {
                if autoDismiss {
                    startDismissTimer()
                }
            }
            .onDisappear {
                dismissTimer?.invalidate()
            }
        }
    }

    /// Dismiss the banner with animation
    func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) {
            isVisible = false
        }
        dismissTimer?.invalidate()
    }

    /// Start auto-dismiss timer
    private func startDismissTimer() {
        dismissTimer = Timer.scheduledTimer(withTimeInterval: dismissDelay, repeats: false) { _ in
            dismiss()
        }
    }
}

// MARK: - Safe Array Access Extension


// MARK: - List Item Status Icon

/// List item status icon view - renders SF Symbol with optional color
/// Shared component for dynamic status icons in list items (Inspect presets & future Dialog --listitem)
///
/// Supports formats:
/// - Simple icon: "shield"
/// - Icon with color: "shield.fill-green"
/// - Full SF syntax: "sf=shield.fill,colour=green"
///
/// Reuses IconView for rendering (inherits all SF Symbol + color capabilities)
struct ListItemStatusIconView: View {
    let status: String?           // Status string (e.g., "shield.fill-green" or "sf=shield,colour=blue")
    let size: CGFloat             // Icon size
    let defaultIcon: String?      // Fallback icon if status is nil

    var body: some View {
        Group {
            if let statusIcon = resolvedIconString {
                IconView(image: statusIcon, sfPaddingEnabled: false, corners: false)
                    .frame(width: size, height: size)
            } else if let fallback = defaultIcon {
                IconView(image: fallback, sfPaddingEnabled: false, corners: false)
                    .frame(width: size, height: size)
            } else {
                // No icon to display
                EmptyView()
            }
        }
    }

    /// Resolves status string into IconView-compatible format
    /// Converts "icon-color" syntax to "sf=icon,colour=color"
    private var resolvedIconString: String? {
        guard let status = status, !status.isEmpty else { return nil }

        // Already in SF syntax format
        if status.hasPrefix("sf=") {
            return status
        }

        // Check for "icon-color" format (e.g., "shield.fill-green")
        if let dashIndex = status.lastIndex(of: "-") {
            let icon = String(status[..<dashIndex])
            let color = String(status[status.index(after: dashIndex)...])

            // Convert to SF syntax that IconView understands
            return "sf=\(icon),colour=\(color)"
        }

        // Plain icon name without color
        return "sf=\(status)"
    }
}


// MARK: - Info Popover Helper

/// Helper view that displays an info icon button that shows a popover with help text
struct InfoPopoverButton: View {
    let helpText: String
    let scaleFactor: Double
    @State private var showingPopover = false

    var body: some View {
        Button(action: {
            showingPopover.toggle()
        }) {
            Image(systemName: "info.circle")
                .font(.system(size: 14 * scaleFactor))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Help")
                        .font(.headline)
                }

                Text(helpText)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Close") {
                    showingPopover = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: 300)
        }
        .help(helpText)
    }
}


// MARK: - Button Helpers

/// Handle button action for inline buttons in guidance content
func handleButtonAction(block: InspectConfig.GuidanceContent, itemId: String, inspectState: InspectState) {
    guard let action = block.action else {
        writeLog("Button clicked but no action defined", logLevel: .error)
        return
    }

    switch action {
    case "url":
        if let urlString = block.url, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            writeLog("Button: Opened URL \(urlString)", logLevel: .info)
            inspectState.writeToInteractionLog("button:\(itemId):\(block.content ?? "button"):url:\(urlString)")
        } else {
            writeLog("Button: Invalid URL for action='url'", logLevel: .error)
        }

    case "shell":
        // Shell execution is not supported - log and ignore
        writeLog("Button: Shell action is not supported", logLevel: .info)
        inspectState.writeToInteractionLog("button:\(itemId):\(block.content ?? "button"):shell:NOT_SUPPORTED")

    case "custom":
        // Write to interaction log for script monitoring
        inspectState.writeToInteractionLog("button:\(itemId):\(block.content ?? "button"):custom")
        writeLog("Button: Custom action triggered for '\(block.content ?? "button")'", logLevel: .info)

    case "request":
        // Script callback pattern - Dialog writes request, script handles execution
        // Format: request:<requestId>:<itemId>:<badgeIndex>
        let requestId = block.requestId ?? "unknown"
        let badgeIndex = block.targetBadge?.blockIndex ?? 0
        let requestLine = "request:\(requestId):\(itemId):\(badgeIndex)"

        // Always write to interaction log (backwards compatible)
        inspectState.writeToInteractionLog(requestLine)

        // Optionally write to FIFO if configured (for instant delivery)
        if let pipePath = inspectState.config?.actionPipe {
            writeToPipeIfExists(path: pipePath, content: requestLine)
        }

        writeLog("Button: Request '\(requestId)' sent for item '\(itemId)'", logLevel: .info)

    default:
        writeLog("Button: Unknown action '\(action)'", logLevel: .error)
    }
}

/// Write content to a FIFO (named pipe) if it exists
/// Non-blocking: dispatches write to background queue to avoid blocking UI
/// Build portal headers dictionary from branding key and custom headers
/// - Parameters:
///   - brandingKey: Optional branding key to send as header
///   - brandingHeaderName: Header name for branding key (defaults to X-Brand-ID)
///   - blockHeaders: Additional custom headers from the block
/// - Returns: Dictionary of headers, or nil if empty
func buildPortalHeaders(
    brandingKey: String?,
    brandingHeaderName: String?,
    blockHeaders: [String: String]?
) -> [String: String]? {
    var headers: [String: String] = [:]

    if let key = brandingKey {
        let headerName = brandingHeaderName ?? "X-Brand-ID"
        headers[headerName] = key
    }

    if let blockHeaders = blockHeaders {
        headers.merge(blockHeaders) { _, new in new }
    }

    return headers.isEmpty ? nil : headers
}

/// - Parameters:
///   - path: Path to the FIFO file
///   - content: Content to write (newline will be appended)
private func writeToPipeIfExists(path: String, content: String) {
    // Check if path exists and is a FIFO
    var statInfo = stat()
    guard stat(path, &statInfo) == 0,
          (statInfo.st_mode & S_IFMT) == S_IFIFO else {
        writeLog("FIFO not found or not a pipe: \(path)", logLevel: .debug)
        return
    }

    // Write asynchronously to avoid blocking UI if no reader is waiting
    DispatchQueue.global(qos: .userInitiated).async {
        guard let handle = FileHandle(forWritingAtPath: path) else {
            writeLog("FIFO: Could not open for writing: \(path)", logLevel: .error)
            return
        }
        defer { handle.closeFile() }

        let data = (content + "\n").data(using: .utf8)!
        handle.write(data)
        writeLog("FIFO: Wrote request to \(path)", logLevel: .debug)
    }
}


// MARK: - Observe-Only Helpers

/// Check if a specific item has observe-only mode enabled
/// Cascading priority: item.observeOnly → config.observeOnly → false (interactive)
func isItemObserveOnly(_ item: InspectConfig.ItemConfig?, config: InspectConfig?) -> Bool {
    item?.observeOnly ?? config?.observeOnly ?? false
}

/// Check if global observe-only mode is enabled
func isGlobalObserveOnly(config: InspectConfig?) -> Bool {
    config?.observeOnly ?? false
}


// MARK: - Button Helper Functions

/// Get SwiftUI button style from string
@ViewBuilder
func applyButtonStyle(_ button: some View, styleString: String?) -> some View {
    switch styleString {
    case "borderedProminent":
        button.buttonStyle(.borderedProminent)
    case "plain":
        button.buttonStyle(.plain)
    default: // "bordered" or nil
        button.buttonStyle(.bordered)
    }
}


// MARK: - Help Button Action Handler

/// Handles help button actions based on config (overlay, url, custom)
/// - Parameters:
///   - config: The help button configuration
///   - showOverlay: Binding to toggle overlay visibility (for action: "overlay")
///   - interactionLogPath: Path to write interaction log (for action: "custom")
func handleHelpButtonAction(
    config: InspectConfig.HelpButtonConfig,
    showOverlay: Binding<Bool>? = nil,
    interactionLogPath: String = "/var/tmp/dialog-inspect-interactions.log"
) {
    let actionType = config.action ?? "overlay"

    switch actionType {
    case "url":
        if let urlString = config.url, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            writeLog("HelpButton: Opened URL: \(urlString)", logLevel: .info)
        } else {
            writeLog("HelpButton: Invalid or missing URL for action 'url'", logLevel: .error)
        }

    case "custom":
        let customId = config.customId ?? config.label ?? "help"
        let message = "helpbutton:custom:\(customId)"
        // Write to interaction log for external script monitoring
        if let data = (message + "\n").data(using: .utf8) {
            if FileManager.default.fileExists(atPath: interactionLogPath) {
                if let handle = FileHandle(forWritingAtPath: interactionLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: interactionLogPath, contents: data, attributes: nil)
            }
        }
        writeLog("HelpButton: Custom action triggered: \(customId)", logLevel: .info)

    case "overlay", _:
        // Default: show overlay
        showOverlay?.wrappedValue = true
    }
}


// MARK: - Detail Overlay Help Button

/// A configurable help button that triggers the detail overlay
struct DetailOverlayHelpButton: View {
    let config: InspectConfig.HelpButtonConfig
    let action: () -> Void

    /// Icon to display (SF Symbol name)
    private var iconName: String {
        config.icon ?? "questionmark.circle"
    }

    /// Button style
    private var buttonStyle: String {
        config.style ?? "floating"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: buttonStyle == "floating" ? 18 : 14))

                if let label = config.label {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundStyle(buttonStyle == "floating" ? .white : .accentColor)
            .padding(buttonStyle == "floating" ? 10 : 6)
            .background(
                Group {
                    if buttonStyle == "floating" {
                        Circle()
                            .fill(Color.accentColor)
                            .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                    } else if buttonStyle == "toolbar" {
                        Capsule()
                            .fill(Color(NSColor.controlBackgroundColor))
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .help(config.tooltip ?? "Get Help")
    }
}


// MARK: - Detail Overlay View Modifier

/// View modifier for adding detail overlay support to any preset
/// Supports both standard text-based content and gallery presentation mode
/// Set `presentationMode: "gallery"` in config to display images in carousel format
struct DetailOverlayModifier: ViewModifier {
    @ObservedObject var inspectState: InspectState
    @Binding var showOverlay: Bool
    let config: InspectConfig.DetailOverlayConfig?

    func body(content: Content) -> some View {
        // Always use sheet presentation for slide-in effect
        content
            .sheet(isPresented: $showOverlay) {
                if let config = config {
                    // Check presentation mode
                    if config.presentationMode == "gallery" {
                        // Gallery mode - show carousel
                        GalleryCarouselView(
                            config: config,
                            onClose: { showOverlay = false }
                        )
                    } else {
                        // Standard mode - show traditional content overlay
                        DetailOverlayView(
                            inspectState: inspectState,
                            config: config,
                            onClose: { showOverlay = false }
                        )
                    }
                }
            }
    }
}

extension View {
    /// Adds detail overlay support to a view
    func detailOverlay(
        inspectState: InspectState,
        isPresented: Binding<Bool>,
        config: InspectConfig.DetailOverlayConfig?
    ) -> some View {
        modifier(DetailOverlayModifier(
            inspectState: inspectState,
            showOverlay: isPresented,
            config: config
        ))
    }
}


// MARK: - Item Info Button

/// A small info button (i) that can be placed next to each install item
/// Shows item-specific details when tapped
struct ItemInfoButton: View {
    let item: InspectConfig.ItemConfig
    let action: () -> Void
    let size: CGFloat

    init(item: InspectConfig.ItemConfig, action: @escaping () -> Void, size: CGFloat = 16) {
        self.item = item
        self.action = action
        self.size = size
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.system(size: size))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("More info about \(item.displayName)")
    }
}


// MARK: - Item Detail Overlay Modifier

/// View modifier for showing item-specific detail overlay
struct ItemDetailOverlayModifier: ViewModifier {
    @ObservedObject var inspectState: InspectState
    @Binding var showOverlay: Bool
    let item: InspectConfig.ItemConfig?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showOverlay) {
                if let item = item {
                    // Use item-specific overlay config if available, otherwise fall back to global
                    let config = item.itemOverlay ?? inspectState.config?.detailOverlay
                    if let config = config {
                        // Check presentation mode - gallery mode uses carousel view
                        if config.presentationMode == "gallery" {
                            GalleryCarouselView(
                                config: config,
                                onClose: { showOverlay = false }
                            )
                        } else {
                            // Standard mode - show traditional content overlay
                            // Create an item-specific config with the item's display name as title
                            let itemConfig = InspectConfig.DetailOverlayConfig(
                                enabled: config.enabled,
                                size: config.size,
                                title: config.title ?? item.displayName,
                                subtitle: config.subtitle,
                                icon: config.icon ?? item.icon,
                                overlayIcon: config.overlayIcon,
                                content: config.content,
                                showSystemInfo: config.showSystemInfo,
                                showProgressInfo: false,  // Don't show progress for item-specific
                                closeButtonText: config.closeButtonText,
                                backgroundColor: config.backgroundColor,
                                showDividers: config.showDividers
                            )
                            DetailOverlayView(
                                inspectState: inspectState,
                                config: itemConfig,
                                onClose: { showOverlay = false }
                            )
                        }
                    }
                }
            }
    }
}

extension View {
    /// Adds item-specific detail overlay support to a view
    func itemDetailOverlay(
        inspectState: InspectState,
        isPresented: Binding<Bool>,
        item: InspectConfig.ItemConfig?
    ) -> some View {
        modifier(ItemDetailOverlayModifier(
            inspectState: inspectState,
            showOverlay: isPresented,
            item: item
        ))
    }
}


// MARK: - Positioned Help Button Wrapper

/// Positions the help button according to config
/// Supports: topRight, topLeft, bottomRight, bottomLeft, sidebar, buttonBar
struct PositionedHelpButton: View {
    let config: InspectConfig.HelpButtonConfig
    let action: () -> Void
    let padding: CGFloat

    private var position: String {
        config.position ?? "bottomRight"
    }

    /// Whether this position uses floating overlay positioning
    var isFloatingPosition: Bool {
        !["sidebar", "buttonBar"].contains(position)
    }

    var body: some View {
        if isFloatingPosition {
            // Floating positions use full-frame overlay with alignment
            DetailOverlayHelpButton(config: config, action: action)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                .padding(padding)
        } else {
            // Non-floating positions (sidebar, buttonBar) are rendered inline
            // The parent view handles actual positioning
            DetailOverlayHelpButton(config: config, action: action)
        }
    }

    private var alignment: Alignment {
        switch position {
        case "topLeft": return .topLeading
        case "topRight": return .topTrailing
        case "bottomLeft": return .bottomLeading
        case "bottomRight": return .bottomTrailing
        default: return .bottomTrailing
        }
    }
}

