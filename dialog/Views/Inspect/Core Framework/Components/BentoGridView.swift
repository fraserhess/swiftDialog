//
//  BentoGridView.swift
//  dialog
//
//  Created by Henry Stamerjohann, Declarative IT GmbH, 25/01/2026
//
//  Bento-Grid Component for Preset11
//  CSS Grid-like layouts with variable cell sizes (1x1, 2x1, 1x2, 2x2)
//

import SwiftUI

// MARK: - Bento Layout Engine

/// Calculates precise cell positions for bento grid layout
struct BentoLayoutEngine {
    /// Calculated placement for a single cell
    struct CellPlacement: Identifiable {
        let id: String
        let cellId: String
        let row: Int
        let column: Int
        let columnSpan: Int
        let rowSpan: Int
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    /// Calculate placements for all cells
    /// - Parameters:
    ///   - cells: Array of cell configurations
    ///   - columns: Total number of columns in grid
    ///   - cellWidth: Width of a single column (including gaps calculated in)
    ///   - rowHeight: Height of a single row
    ///   - gap: Gap between cells
    /// - Returns: Array of calculated cell placements
    static func calculate(
        cells: [InspectConfig.GuidanceContent.BentoCellConfig],
        columns: Int,
        cellWidth: CGFloat,
        rowHeight: CGFloat,
        gap: CGFloat
    ) -> [CellPlacement] {
        var placements: [CellPlacement] = []

        for cell in cells {
            let colSpan = min(cell.columnSpan ?? 1, columns - cell.column)
            let rowSpan = cell.rowSpan ?? 1

            // Calculate position
            let x = CGFloat(cell.column) * (cellWidth + gap)
            let y = CGFloat(cell.row) * (rowHeight + gap)

            // Calculate size (spanning cells include the gaps between spanned columns/rows)
            let width = CGFloat(colSpan) * cellWidth + CGFloat(colSpan - 1) * gap
            let height = CGFloat(rowSpan) * rowHeight + CGFloat(rowSpan - 1) * gap

            let placement = CellPlacement(
                id: cell.id,
                cellId: cell.id,
                row: cell.row,
                column: cell.column,
                columnSpan: colSpan,
                rowSpan: rowSpan,
                x: x,
                y: y,
                width: width,
                height: height
            )

            placements.append(placement)
        }

        return placements
    }

    /// Calculate the total height needed for the grid
    static func calculateGridHeight(cells: [InspectConfig.GuidanceContent.BentoCellConfig], rowHeight: CGFloat, gap: CGFloat) -> CGFloat {
        guard !cells.isEmpty else { return 0 }

        var maxRow = 0
        for cell in cells {
            let rowSpan = cell.rowSpan ?? 1
            let cellEndRow = cell.row + rowSpan
            maxRow = max(maxRow, cellEndRow)
        }

        return CGFloat(maxRow) * rowHeight + CGFloat(maxRow - 1) * gap
    }
}

// MARK: - Bento Cell View

/// Individual cell in the bento grid with 4 content modes: image, text, icon, mixed
struct BentoCell: View {
    let config: InspectConfig.GuidanceContent.BentoCellConfig
    let width: CGFloat
    let height: CGFloat
    let scaleFactor: CGFloat
    let accentColor: Color
    let iconBasePath: String?
    let onTap: () -> Void

    private var cornerRadius: CGFloat {
        CGFloat(config.cornerRadius ?? 12) * scaleFactor
    }

    private var backgroundColor: Color {
        if let colorHex = config.backgroundColor {
            return Color(hex: colorHex)
        }
        return Color(.windowBackgroundColor).opacity(0.6)
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(backgroundColor)

                // Content based on type
                contentView
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    private var contentView: some View {
        switch config.contentType {
        case "image":
            imageContent
        case "text":
            textContent
        case "icon":
            iconContent
        case "mixed":
            mixedContent
        default:
            EmptyView()
        }
    }

    // MARK: - Content Views

    @ViewBuilder
    private var imageContent: some View {
        if let imagePath = config.imagePath {
            AsyncBentoImageView(
                imagePath: imagePath,
                basePath: iconBasePath,
                width: width,
                height: height,
                imageFit: config.imageFit ?? "fill"
            )
        }
    }

    @ViewBuilder
    private var textContent: some View {
        VStack(alignment: .leading, spacing: 4 * scaleFactor) {
            if let title = config.title {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(textColor)
                    .lineLimit(3)
            }

            if let subtitle = config.subtitle {
                Text(subtitle)
                    .font(.system(size: 13 * scaleFactor))
                    .foregroundStyle(textColor.opacity(0.7))
                    .lineLimit(2)
            }
        }
        .padding(12 * scaleFactor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var iconContent: some View {
        VStack(spacing: 8 * scaleFactor) {
            if let sfSymbol = config.sfSymbol {
                Image(systemName: sfSymbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .font(.system(size: CGFloat(config.iconSize ?? 48) * scaleFactor, weight: iconWeight))
                    .frame(width: CGFloat(config.iconSize ?? 48) * scaleFactor, height: CGFloat(config.iconSize ?? 48) * scaleFactor)
                    .foregroundStyle(iconColor)
            }

            if let title = config.title {
                Text(title)
                    .font(.system(size: 14 * scaleFactor, weight: .medium))
                    .foregroundStyle(textColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Icon color - uses iconColor from config, falls back to accentColor
    private var iconColor: Color {
        if let colorHex = config.iconColor {
            return Color(hex: colorHex)
        }
        return accentColor
    }

    /// Icon weight from config string
    private var iconWeight: Font.Weight {
        switch config.iconWeight?.lowercased() {
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
    private var mixedContent: some View {
        ZStack(alignment: .bottomLeading) {
            // Background image
            if let imagePath = config.imagePath {
                AsyncBentoImageView(
                    imagePath: imagePath,
                    basePath: iconBasePath,
                    width: width,
                    height: height,
                    imageFit: config.imageFit ?? "fill"
                )
            }

            // Gradient overlay for text readability
            LinearGradient(
                gradient: Gradient(colors: [.clear, .black.opacity(0.6)]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height * 0.5)
            .frame(maxHeight: .infinity, alignment: .bottom)

            // Text overlay
            VStack(alignment: .leading, spacing: 2 * scaleFactor) {
                if let title = config.title {
                    Text(title)
                        .font(.system(size: mixedTitleSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }

                if let subtitle = config.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12 * scaleFactor))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }
            }
            .padding(12 * scaleFactor)
        }
    }

    // MARK: - Helpers

    private var titleFont: Font {
        let size: CGFloat
        switch config.textSize {
        case "large":
            size = 32
        case "small":
            size = 14
        default: // "medium"
            size = 20
        }
        return .system(size: size * scaleFactor, weight: .bold)
    }

    private var mixedTitleSize: CGFloat {
        let size: CGFloat
        switch config.textSize {
        case "large":
            size = 24
        case "small":
            size = 14
        default:
            size = 18
        }
        return size * scaleFactor
    }

    private var textColor: Color {
        if let colorHex = config.textColor {
            return Color(hex: colorHex)
        }
        return .primary
    }
}

// MARK: - Async Bento Image View

/// Asynchronous image loader for bento cells
private struct AsyncBentoImageView: View {
    let imagePath: String
    let basePath: String?
    let width: CGFloat
    let height: CGFloat
    let imageFit: String

    @State private var loadedImage: NSImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: imageFit == "fill" ? .fill : .fit)
                    .frame(width: width, height: height)
                    .clipped()
            } else if isLoading {
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.8)
                    )
            } else {
                // Fallback placeholder
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .onAppear {
            loadImage()
        }
    }

    private func loadImage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let resolvedPath = resolveImagePath(imagePath, basePath: basePath)

            if let path = resolvedPath, let image = NSImage(contentsOfFile: path) {
                DispatchQueue.main.async {
                    self.loadedImage = image
                    self.isLoading = false
                }
            } else {
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
        }
    }

    private func resolveImagePath(_ path: String, basePath: String?) -> String? {
        // Absolute path
        if path.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }

        // Try with base path
        if let base = basePath {
            let fullPath = (base as NSString).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: fullPath) {
                return fullPath
            }
        }

        // Try ImageResolver if available
        if let resolved = ImageResolver.shared.resolveImagePath(path, basePath: basePath, fallbackIcon: nil),
           resolved.hasPrefix("/"),
           FileManager.default.fileExists(atPath: resolved) {
            return resolved
        }

        return nil
    }
}

// MARK: - Bento Detail View

/// Large overlay view for bento item details with full GuidanceContent support
struct BentoDetailView: View {
    let cellConfig: InspectConfig.GuidanceContent.BentoCellConfig
    let overlay: InspectConfig.DetailOverlayConfig
    let accentColor: Color
    let iconBasePath: String?
    @ObservedObject var inspectState: InspectState
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color {
        if let hex = overlay.backgroundColor {
            return Color(hex: hex)
        }
        return Color(NSColor.windowBackgroundColor)
    }

    private var headerIcon: String? {
        overlay.icon ?? cellConfig.sfSymbol
    }

    private var headerTitle: String {
        overlay.title ?? cellConfig.title ?? "Details"
    }

    private var headerSubtitle: String? {
        overlay.subtitle ?? cellConfig.subtitle
    }

    private var overlayWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        if overlay.wide == true {
            return (900, 1000, 1100)  // Wide mode
        }
        return (720, 800, 880)  // Default (20% narrower)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with gradient background
            headerView
                .background(
                    LinearGradient(
                        colors: [accentColor.opacity(0.15), backgroundColor],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Divider()

            // Scrollable content area
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Rich content using GuidanceContentView
                    if let content = overlay.content, !content.isEmpty {
                        GuidanceContentView(
                            contentBlocks: content,
                            scaleFactor: 1.0,
                            iconBasePath: iconBasePath,
                            inspectState: inspectState,
                            itemId: "bento-detail-\(cellConfig.id)",
                            onOverlayTap: nil
                        )
                    } else {
                        // Fallback if no content
                        Text("No additional details available.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    }
                }
                .padding(24)
            }

            Divider()

            // Footer with close button
            footerView
        }
        .frame(minWidth: overlayWidth.min, idealWidth: overlayWidth.ideal, maxWidth: overlayWidth.max)
        .frame(minHeight: 550, idealHeight: 650, maxHeight: 750)
        .background(backgroundColor)
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(spacing: 16) {
            // Icon
            if let iconName = headerIcon {
                Group {
                    if iconName.hasPrefix("sf=") || !iconName.contains("/") && !iconName.contains(".") {
                        // SF Symbol
                        let symbolName = iconName.hasPrefix("sf=") ? String(iconName.dropFirst(3)) : iconName
                        Image(systemName: symbolName)
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(accentColor)
                    } else {
                        // Image path
                        if let image = loadHeaderImage(iconName) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 32, weight: .medium))
                                .foregroundStyle(accentColor)
                        }
                    }
                }
                .frame(width: 48, height: 48)
            }

            // Title and subtitle
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.primary)

                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    // MARK: - Footer View

    private var footerView: some View {
        HStack {
            Spacer()

            Button(action: onClose) {
                Text(overlay.closeButtonText ?? "Close")
                    .frame(minWidth: 80)
            }
            .keyboardShortcut(.escape, modifiers: [])
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Helpers

    private func loadHeaderImage(_ path: String) -> NSImage? {
        // Try absolute path first
        if path.hasPrefix("/") && FileManager.default.fileExists(atPath: path) {
            return NSImage(contentsOfFile: path)
        }

        // Try with base path
        if let basePath = iconBasePath {
            let fullPath = (basePath as NSString).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: fullPath) {
                return NSImage(contentsOfFile: fullPath)
            }
        }

        return nil
    }
}

// MARK: - Bento Grid View

/// Main bento grid container using GeometryReader for precise sizing
struct BentoGridView: View {
    let cells: [InspectConfig.GuidanceContent.BentoCellConfig]
    let columns: Int
    let rowHeight: CGFloat
    let gap: CGFloat
    let scaleFactor: CGFloat
    let accentColor: Color
    let iconBasePath: String?
    @ObservedObject var inspectState: InspectState

    @State private var selectedCell: InspectConfig.GuidanceContent.BentoCellConfig?
    @State private var showDetail: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            let cellWidth = (availableWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let placements = BentoLayoutEngine.calculate(
                cells: cells,
                columns: columns,
                cellWidth: cellWidth,
                rowHeight: rowHeight * scaleFactor,
                gap: gap * scaleFactor
            )
            let gridHeight = BentoLayoutEngine.calculateGridHeight(
                cells: cells,
                rowHeight: rowHeight * scaleFactor,
                gap: gap * scaleFactor
            )

            ZStack(alignment: .topLeading) {
                ForEach(placements) { placement in
                    if let cellConfig = cells.first(where: { $0.id == placement.cellId }) {
                        BentoCell(
                            config: cellConfig,
                            width: placement.width,
                            height: placement.height,
                            scaleFactor: scaleFactor,
                            accentColor: accentColor,
                            iconBasePath: iconBasePath,
                            onTap: {
                                if cellConfig.detailOverlay != nil {
                                    selectedCell = cellConfig
                                    showDetail = true
                                }
                            }
                        )
                        .offset(x: placement.x, y: placement.y)
                    }
                }
            }
            .frame(width: availableWidth, height: gridHeight, alignment: .topLeading)
        }
        .frame(height: BentoLayoutEngine.calculateGridHeight(
            cells: cells,
            rowHeight: rowHeight * scaleFactor,
            gap: gap * scaleFactor
        ))
        .sheet(isPresented: $showDetail) {
            if let cell = selectedCell, let overlay = cell.detailOverlay {
                BentoDetailView(
                    cellConfig: cell,
                    overlay: overlay,
                    accentColor: accentColor,
                    iconBasePath: iconBasePath,
                    inspectState: inspectState,
                    onClose: {
                        showDetail = false
                        selectedCell = nil
                    }
                )
            }
        }
    }
}

// MARK: - Preview Provider

#if DEBUG
struct BentoGridView_Previews: PreviewProvider {
    static var previews: some View {
        BentoGridView(
            cells: [
                InspectConfig.GuidanceContent.BentoCellConfig(
                    id: "hero",
                    column: 0,
                    row: 0,
                    columnSpan: 2,
                    rowSpan: 2,
                    contentType: "text",
                    imagePath: nil,
                    imageFit: nil,
                    title: "Welcome",
                    subtitle: "Getting Started",
                    textSize: "large",
                    textColor: nil,
                    sfSymbol: nil,
                    iconSize: nil,
                    iconColor: nil,
                    iconWeight: nil,
                    backgroundColor: "#E8F4FD",
                    cornerRadius: nil,
                    detailOverlay: nil
                ),
                InspectConfig.GuidanceContent.BentoCellConfig(
                    id: "apps",
                    column: 2,
                    row: 0,
                    columnSpan: nil,
                    rowSpan: nil,
                    contentType: "icon",
                    imagePath: nil,
                    imageFit: nil,
                    title: "Apps",
                    subtitle: nil,
                    textSize: nil,
                    textColor: nil,
                    sfSymbol: "square.grid.2x2",
                    iconSize: 48,
                    iconColor: nil,
                    iconWeight: nil,
                    backgroundColor: "#F5F5F5",
                    cornerRadius: nil,
                    detailOverlay: nil
                ),
                InspectConfig.GuidanceContent.BentoCellConfig(
                    id: "year",
                    column: 3,
                    row: 0,
                    columnSpan: nil,
                    rowSpan: nil,
                    contentType: "text",
                    imagePath: nil,
                    imageFit: nil,
                    title: "2025",
                    subtitle: nil,
                    textSize: "large",
                    textColor: nil,
                    sfSymbol: nil,
                    iconSize: nil,
                    iconColor: nil,
                    iconWeight: nil,
                    backgroundColor: "#E8FDE8",
                    cornerRadius: nil,
                    detailOverlay: nil
                )
            ],
            columns: 4,
            rowHeight: 140,
            gap: 12,
            scaleFactor: 1.0,
            accentColor: .accentColor,
            iconBasePath: nil,
            inspectState: InspectState()
        )
        .frame(width: 600, height: 400)
        .padding()
    }
}
#endif
