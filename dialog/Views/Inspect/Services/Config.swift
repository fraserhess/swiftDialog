//
//  Config.swift
//  dialog
//
//  Created by Henry Stamerjohann, Declarative IT GmbH, 25/07/2025
//  Business logic service used for configuration loading and processing
//

import Foundation

// MARK: - Configuration Models

struct ConfigurationRequest {
    let environmentVariable: String
    let fallbackToTestData: Bool
    
    static let `default` = ConfigurationRequest(
        environmentVariable: "DIALOG_INSPECT_CONFIG",
        fallbackToTestData: true
    )
}

struct ConfigurationResult {
    let config: InspectConfig
    let source: ConfigurationSource
    let warnings: [String]
}


enum ConfigurationError: Error, LocalizedError {
    case fileNotFound(path: String)
    case invalidJSON(path: String, error: Error)
    case missingEnvironmentVariable(name: String)
    case testDataCreationFailed(error: Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Configuration file not found at: \(path)"
        case .invalidJSON(let path, let error):
            // Read JSON file to provide snippet context in error
            let jsonString = try? String(contentsOfFile: path, encoding: .utf8)
            return "Invalid JSON in configuration file \(path): \(Self.formatJSONError(error, jsonString: jsonString))"
        case .missingEnvironmentVariable(let name):
            return "Environment variable '\(name)' not set and no fallback available"
        case .testDataCreationFailed(let error):
            return "Failed to create test configuration: \(error.localizedDescription)"
        }
    }

    /// Format JSON decoding errors with helpful details including line/column for syntax errors
    static func formatJSONError(_ error: Error, jsonString: String? = nil) -> String {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .keyNotFound(let key, let context):
                let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
                let location = path.isEmpty ? "root" : "'\(path)'"
                var message = "Missing required field '\(key.stringValue)' at \(location)"

                // Try to show the JSON section where error occurred
                if let json = jsonString, !path.isEmpty {
                    let result = extractJSONSnippet(json: json, path: path)
                    if let lineNum = result.lineNumber {
                        message += " (line \(lineNum))"
                    }
                    if let snippet = result.snippet {
                        message += "\n\n📍 Error location:\n\(snippet)"
                    }
                }

                // Add helpful hint for common missing fields
                if let hint = fieldHint(for: key.stringValue) {
                    message += "\n\n💡 Hint: \(hint)"
                }
                return message

            case .typeMismatch(let type, let context):
                let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
                var message = "Type mismatch at '\(path)': expected \(type)"

                if let json = jsonString, !path.isEmpty {
                    let result = extractJSONSnippet(json: json, path: path)
                    if let lineNum = result.lineNumber {
                        message += " (line \(lineNum))"
                    }
                    if let snippet = result.snippet {
                        message += "\n\n📍 Error location:\n\(snippet)"
                    }
                }

                // Add type hint for common fields
                if let hint = typeHint(for: path, expectedType: type) {
                    message += "\n\n💡 Hint: \(hint)"
                }
                return message

            case .valueNotFound(let type, let context):
                let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
                var message = "Missing value at '\(path)': expected \(type)"

                if let json = jsonString, !path.isEmpty {
                    let result = extractJSONSnippet(json: json, path: path)
                    if let lineNum = result.lineNumber {
                        message += " (line \(lineNum))"
                    }
                }
                return message

            case .dataCorrupted(let context):
                let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
                let location = path.isEmpty ? "document" : "'\(path)'"
                return "Data corrupted at \(location): \(context.debugDescription)"

            @unknown default:
                return error.localizedDescription
            }
        }

        // For NSError from JSONSerialization (syntax errors)
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == "NSCocoaErrorDomain" {
            // Try to extract line/column from userInfo if available
            if let debugDesc = nsError.userInfo[NSDebugDescriptionErrorKey] as? String {
                // Format: "... around line X, column Y"
                var message = "JSON syntax error (line "

                // Try to extract line number and show context
                if let json = jsonString,
                   let range = debugDesc.range(of: "line \\d+", options: .regularExpression),
                   let lineNum = Int(debugDesc[range].dropFirst(5)) {
                    message += "\(lineNum)): \(debugDesc)"
                    let lines = json.components(separatedBy: "\n")
                    if lineNum > 0 && lineNum <= lines.count {
                        let startLine = max(0, lineNum - 3)
                        let endLine = min(lines.count, lineNum + 2)
                        var snippet = "\n\n📍 Around line \(lineNum):\n"
                        for i in startLine..<endLine {
                            let marker = (i + 1 == lineNum) ? "→ " : "  "
                            snippet += "\(marker)\(i + 1): \(lines[i])\n"
                        }
                        message += snippet
                    }
                } else {
                    message = "JSON syntax error: \(debugDesc)"
                }
                return message
            }
        }

        return error.localizedDescription
    }

    /// Extract JSON snippet around a coding path for error context
    /// Returns tuple with optional line number and optional snippet string
    private static func extractJSONSnippet(json: String, path: String) -> (lineNumber: Int?, snippet: String?) {
        // Parse path to find the item index and field name
        // e.g., "items.Index 0.guidanceContent.Index 0.state" -> items[0].guidanceContent[0], field: state
        let components = path.split(separator: ".")

        var arrayKey = ""
        var itemIndex = 0
        var fieldName: String?

        for component in components {
            let comp = String(component)
            if comp.hasPrefix("Index ") {
                if let idx = Int(comp.dropFirst(6)) {
                    itemIndex = idx
                }
            } else {
                // Track nested arrays (items, guidanceContent, etc.)
                if ["items", "guidanceContent", "plistSources"].contains(comp) {
                    arrayKey = comp
                    itemIndex = 0  // Reset for nested array
                } else {
                    // Last non-index component is the field name (for typeMismatch)
                    fieldName = comp
                }
            }
        }

        let lines = json.components(separatedBy: "\n")
        var foundKeyLine = -1
        var braceCount = 0
        var inTargetArray = false
        var currentItemIndex = -1
        var itemStartLine = -1
        var itemEndLine = -1

        // First pass: find the item block
        for (lineIdx, line) in lines.enumerated() {
            if line.contains("\"\(arrayKey)\"") && line.contains("[") {
                inTargetArray = true
                braceCount = 0
            }

            if inTargetArray {
                for char in line {
                    if char == "{" {
                        if braceCount == 0 {
                            currentItemIndex += 1
                            if currentItemIndex == itemIndex {
                                itemStartLine = lineIdx
                            }
                        }
                        braceCount += 1
                        if currentItemIndex == itemIndex && braceCount == 1 {
                            foundKeyLine = lineIdx
                        }
                    } else if char == "}" {
                        braceCount -= 1
                        if braceCount == 0 && currentItemIndex == itemIndex {
                            itemEndLine = lineIdx
                        }
                    }
                }

                if line.contains("]") && braceCount <= 0 {
                    inTargetArray = false
                }
            }

            if foundKeyLine >= 0 && braceCount == 0 {
                break
            }
        }

        // If we have a specific field name, search within the item block for it
        if let field = fieldName, itemStartLine >= 0 {
            let searchEnd = itemEndLine >= 0 ? itemEndLine : min(lines.count, itemStartLine + 20)
            for i in itemStartLine...searchEnd where lines[i].contains("\"\(field)\"") {
                foundKeyLine = i
                break
            }
        }

        if foundKeyLine >= 0 {
            let startLine = max(0, foundKeyLine - 2)
            let endLine = min(lines.count, foundKeyLine + 6)
            var snippet = ""
            for i in startLine..<endLine {
                let marker = (i == foundKeyLine) ? "→ " : "  "
                snippet += "\(marker)\(i + 1): \(lines[i])\n"
            }
            return (foundKeyLine + 1, snippet)
        }

        return (nil, nil)
    }

    /// Provide helpful hints for common missing fields
    private static func fieldHint(for fieldName: String) -> String? {
        switch fieldName {
        case "paths":
            return "Add \"paths\": [] to each item. This array lists file paths to monitor for completion."
        case "id":
            return "Add \"id\": \"unique-identifier\" to each item. This must be unique across all items."
        case "displayName":
            return "Add \"displayName\": \"Name\" to each item. This is shown in the UI."
        case "guiIndex":
            return "Add \"guiIndex\": 0 to each item. This determines the display order (0 = first)."
        case "preset":
            return "Add \"preset\": \"preset1\" at the root level. Valid: preset1-9, or named: deployment, cards, compact, compliance, dashboard, guidance, guide, onboarding, display."
        case "items":
            return "Add \"items\": [] at the root level. This array contains the items to display."
        case "title":
            return "Add \"title\": \"Your Title\" at the root level."
        case "guidanceContent":
            return "Add \"guidanceContent\": [] to items that need guidance panels. Array of content blocks."
        case "type":
            return "Add \"type\": \"text\" to guidance content blocks. Types: text, badge, button, spacer, divider, etc."
        case "content":
            return "Add \"content\": \"...\" to guidance content blocks for the display text."
        case "state":
            return "Add \"state\": \"pending\" to badge blocks. States: pending, success, fail, info, etc."
        default:
            return nil
        }
    }

    /// Provide helpful hints for type mismatch errors
    private static func typeHint(for path: String, expectedType: Any.Type) -> String? {
        let fieldName = path.split(separator: ".").last.map(String.init) ?? ""

        switch fieldName {
        case "guiIndex":
            return "\"guiIndex\" must be a number without quotes. Use guiIndex: 0, not guiIndex: \"0\""
        case "state":
            return "\"state\" must be a string. Use state: \"pending\", not state: 0"
        case "paths":
            return "\"paths\" must be an array. Use paths: [\"/path/to/file\"], not paths: \"/path\""
        case "items":
            return "\"items\" must be an array of objects. Use items: [{...}], not items: {...}"
        case "guidanceContent":
            return "\"guidanceContent\" must be an array. Use guidanceContent: [{...}], not guidanceContent: {...}"
        default:
            // Generic type hints
            let typeStr = String(describing: expectedType)
            if typeStr.contains("Int") {
                return "This field expects a number without quotes."
            } else if typeStr.contains("Bool") {
                return "This field expects true or false without quotes."
            } else if typeStr.contains("String") {
                return "This field expects a string value in quotes."
            } else if typeStr.contains("Array") {
                return "This field expects an array using square brackets []."
            }
            return nil
        }
    }
}

// MARK: - Configuration Service

class Config {
    
    // MARK: - Inspect API
    
    /// Load configuration from explicit file path via commandline --inspect-config arg (see https://github.com/swiftDialog/swiftDialog/commit/e884ee60f8925c7e47a3096ec6d89f5d92b72d5b#diff-c3b51bf2b51dc1dab1f2d5e8d90baaefa239d674a20f4cf22d67903bef14cb45, else use environment variable,, or fallback to test data
    /// - Parameters:
    ///   - request: Configuration request with environment variable and fallback settings
    ///   - fromFile: Optional explicit file path to load configuration from (takes precedence over environment)
    /// - Returns: Result containing configuration or error
    func loadConfiguration(_ request: ConfigurationRequest = .default, fromFile: String = "") -> Result<ConfigurationResult, ConfigurationError> {
        // Priority 1: Use explicit file path if provided
        if !fromFile.isEmpty {
            writeLog("ConfigurationService: Using config from provided file: \(fromFile)", logLevel: .info)
            return loadConfigurationFromFile(at: fromFile)
        }
        
        // Priority 2: Get config path from environment
        if let configPath = getConfigPath(from: request.environmentVariable) {
            writeLog("ConfigurationService: Using config from environment: \(configPath)", logLevel: .info)
            return loadConfigurationFromFile(at: configPath)
        }
        
        // Priority 3: Check if fallback is allowed
        guard request.fallbackToTestData else {
            return .failure(.missingEnvironmentVariable(name: request.environmentVariable))
        }
        
        writeLog("ConfigurationService: No config path provided, using test data", logLevel: .info)
        return createTestConfiguration()
    }
    
    /// Fallback: Load configuration from specific file path 
    /// TODO: Reevaluate as this has been brittle - loading from file system to late to initialize UI accordingly
    func loadConfigurationFromFile(at path: String) -> Result<ConfigurationResult, ConfigurationError> {
        // Check if file exists
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(.fileNotFound(path: path))
        }
        
        do {
            // Load and parse JSON
            let data = try Data(contentsOf: URL(fileURLWithPath: path))

            // Auto-detect iconBasePath if not explicitly set
            var jsonData = data
            if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var mutableJSON = jsonObject

                // If iconBasePath is nil or missing, auto-set to config directory
                if mutableJSON["iconBasePath"] == nil {
                    let configDirectory = (path as NSString).deletingLastPathComponent
                    mutableJSON["iconBasePath"] = configDirectory
                    writeLog("ConfigurationService: Auto-set iconBasePath to: \(configDirectory)", logLevel: .debug)

                    // Re-serialize modified JSON
                    if let modifiedData = try? JSONSerialization.data(withJSONObject: mutableJSON, options: []) {
                        jsonData = modifiedData
                    }
                }
            }

            let decoder = JSONDecoder()
            let config = try decoder.decode(InspectConfig.self, from: jsonData)

            // Validate and apply defaults
            let processedConfig = applyConfigurationDefaults(to: config)
            let warnings = validateConfiguration(processedConfig)
            
            writeLog("ConfigurationService: Successfully loaded configuration from \(path)", logLevel: .info)
            writeLog("ConfigurationService: Loaded \(config.items.count) items", logLevel: .debug)
            
            return .success(ConfigurationResult(
                config: processedConfig,
                source: .file(path: path),
                warnings: warnings
            ))
            
        } catch let error {
            // Get original JSON string for enhanced error reporting
            let jsonString = try? String(contentsOfFile: path, encoding: .utf8)
            let detailedError = ConfigurationError.formatJSONError(error, jsonString: jsonString)
            writeLog("ConfigurationService: Configuration loading failed for \(path):\n\(detailedError)", logLevel: .error)
            return .failure(.invalidJSON(path: path, error: error))
        }
    }
    
    /// Fallback for Demo: Create test configuration for development/fallback
    func createTestConfiguration() -> Result<ConfigurationResult, ConfigurationError> {
        let testConfigJSON = """
        {
            "title": "Software Installation Progress",
            "message": "Your IT department is installing essential applications. This process may take several minutes.",
            "preset": "preset1",
            "icon": "default",
            "button1text": "Continue",
            "button2text": "Create Sample Config",
            "button2visible": true,
            "popupButton": "Installation Details",
            "highlightColor": "#007AFF",
            "cachePaths": ["/tmp"],
            "uiLabels": {
                "completedStatus": "Installed",
                "downloadingStatus": "Installing...",
                "pendingStatus": "Pending",
                "progressFormat": "{completed} of {total} apps installed",
                "completionMessage": "All Applications Installed!",
                "completionSubtitle": "Your software is ready to use"
            },
            "items": [
                {
                    "id": "word",
                    "displayName": "Microsoft Word",
                    "guiIndex": 0,
                    "icon": "sf=doc.fill",
                    "paths": ["/Applications/Microsoft Word.app"]
                },
                {
                    "id": "excel",
                    "displayName": "Microsoft Excel",
                    "guiIndex": 1,
                    "icon": "sf=tablecells.fill",
                    "paths": ["/Applications/Microsoft Excel.app"]
                },
                {
                    "id": "teams",
                    "displayName": "Microsoft Teams",
                    "guiIndex": 2,
                    "icon": "sf=person.2.fill",
                    "paths": ["/Applications/Microsoft Teams.app"]
                },
                {
                    "id": "outlook",
                    "displayName": "Microsoft Outlook",
                    "guiIndex": 4,
                    "icon": "sf=envelope.fill",
                    "paths": ["/Applications/Microsoft Outlook.app"]
                }
            ]
        }
        """
        
        do {
            guard let jsonData = testConfigJSON.data(using: .utf8) else {
                throw NSError(domain: "TestDataError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create JSON data"])
            }
            
            let config = try JSONDecoder().decode(InspectConfig.self, from: jsonData)
            let processedConfig = applyConfigurationDefaults(to: config)
            
            writeLog("ConfigurationService: Created test configuration with \(config.items.count) items", logLevel: .debug)
            
            return .success(ConfigurationResult(
                config: processedConfig,
                source: .testData,
                warnings: []
            ))
            
        } catch let error {
            return .failure(.testDataCreationFailed(error: error))
        }
    }
    
    // MARK: - Internal Helper Methods
    
    private func getConfigPath(from environmentVariable: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment[environmentVariable] else {
            return nil
        }
        return path.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func applyConfigurationDefaults(to config: InspectConfig) -> InspectConfig {
        // Apply configuration defaults and process the config
        // TODO: This is where we would add more advanced post-processing logic
        
        // Sort items by guiIndex for consistent display
        let processedConfig = config
        // Note: InspectConfig is a struct, we can't modify it directly
        
        return processedConfig
    }
    
    /// TODO: better validate configuration and return warnings - 
    private func validateConfiguration(_ config: InspectConfig) -> [String] {
        var warnings: [String] = []
        
        // Check for common configuration issues
        if config.items.isEmpty && config.plistSources?.isEmpty != false {
            warnings.append("Configuration has no items or plist sources")
        }
        
        let validPresets = [
            // Full names
            "preset1", "preset2", "preset3", "preset4", "preset5",
            "preset6", "preset7", "preset8", "preset9",
            // Numeric shorthand
            "1", "2", "3", "4", "5", "6", "7", "8", "9",
            // Marketing names
            "deployment", "cards", "compact", "compliance",
            "dashboard", "guidance", "guide", "onboarding", "display"
        ]
        if !validPresets.contains(config.preset.lowercased()) {
            warnings.append("Unknown preset '\(config.preset)' - will default to preset1")
        }
        
        // Check for missing icon files
        if let iconPath = config.icon, !FileManager.default.fileExists(atPath: iconPath) {
            warnings.append("Icon file not found: \(iconPath)")
        }
        
        // Check for missing background images
        if let backgroundImage = config.backgroundImage, !FileManager.default.fileExists(atPath: backgroundImage) {
            warnings.append("Background image not found: \(backgroundImage)")
        }
        
        // Validate color thresholds
        if let thresholds = config.colorThresholds {
            if thresholds.excellent <= thresholds.good || thresholds.good <= thresholds.warning {
                warnings.append("Color thresholds should be in descending order (excellent > good > warning)")
            }
        }
        
        // Log warnings
        for warning in warnings {
            writeLog("ConfigurationService: Warning - \(warning)", logLevel: .info)
        }
        
        return warnings
    }
    
    // MARK: - Configuration Transformation Helpers
    
    func extractUIConfiguration(from config: InspectConfig) -> UIConfiguration {
        var uiConfig = UIConfiguration()

        print("Config.swift: extractUIConfiguration called")
        print("Config.swift: config.banner = \(config.banner ?? "nil")")
        print("Config.swift: config.bannerHeight = \(config.bannerHeight ?? 0)")
        print("Config.swift: config.bannerTitle = \(config.bannerTitle ?? "nil")")

        if let title = config.title {
            uiConfig.windowTitle = title
        }

        if let message = config.message {
            uiConfig.subtitleMessage = message
            uiConfig.statusMessage = message
        }

        if let icon = config.icon {
            uiConfig.iconPath = icon
        }

        if let sideMessage = config.sideMessage {
            uiConfig.sideMessages = sideMessage
        }

        if let popupButton = config.popupButton {
            uiConfig.popupButtonText = popupButton
        }

        uiConfig.preset = config.preset

        if let highlightColor = config.highlightColor {
            uiConfig.highlightColor = highlightColor
        }

        if let secondaryColor = config.secondaryColor {
            uiConfig.secondaryColor = secondaryColor
        }

        // Banner configuration
        if let banner = config.banner {
            print("Config.swift: Setting uiConfig.bannerImage = \(banner)")
            uiConfig.bannerImage = banner
        }

        if let bannerHeight = config.bannerHeight {
            print("Config.swift: Setting uiConfig.bannerHeight = \(bannerHeight)")
            uiConfig.bannerHeight = bannerHeight
        }

        if let bannerTitle = config.bannerTitle {
            print("Config.swift: Setting uiConfig.bannerTitle = \(bannerTitle)")
            uiConfig.bannerTitle = bannerTitle
        }

        print("Config.swift: After extraction - uiConfig.bannerImage = \(uiConfig.bannerImage ?? "nil")")

        if let iconsize = config.iconsize {
            uiConfig.iconSize = iconsize
        }

        // Window sizing configuration
        if let width = config.width {
            uiConfig.width = width
        }

        if let height = config.height {
            uiConfig.height = height
        }

        if let size = config.size {
            uiConfig.size = size
        }

        // Preset6 specific properties
        if let iconBasePath = config.iconBasePath {
            uiConfig.iconBasePath = iconBasePath
        }

        if let overlayicon = config.overlayicon {
            uiConfig.overlayIcon = overlayicon
        }

        if let rotatingImages = config.rotatingImages {
            uiConfig.rotatingImages = rotatingImages
        }

        if let imageRotationInterval = config.imageRotationInterval {
            uiConfig.imageRotationInterval = imageRotationInterval
        }

        if let imageShape = config.imageShape {
            uiConfig.imageFormat = imageShape  // Map to existing imageFormat property
        }

        if let imageSyncMode = config.imageSyncMode {
            uiConfig.imageSyncMode = imageSyncMode
        }

        if let stepStyle = config.stepStyle {
            uiConfig.stepStyle = stepStyle
        }

        if let listIndicatorStyle = config.listIndicatorStyle {
            uiConfig.listIndicatorStyle = listIndicatorStyle
            print("Config: Setting listIndicatorStyle to '\(listIndicatorStyle)' from JSON")
        } else {
            print("Config: No listIndicatorStyle in JSON, using default: '\(uiConfig.listIndicatorStyle)'")
        }

        return uiConfig
    }
    
    func extractBackgroundConfiguration(from config: InspectConfig) -> BackgroundConfiguration {
        var bgConfig = BackgroundConfiguration()
        
        if let backgroundColor = config.backgroundColor {
            bgConfig.backgroundColor = backgroundColor
        }
        
        if let backgroundImage = config.backgroundImage {
            bgConfig.backgroundImage = backgroundImage
        }
        
        if let backgroundOpacity = config.backgroundOpacity {
            bgConfig.backgroundOpacity = backgroundOpacity
        }
        
        if let textOverlayColor = config.textOverlayColor {
            bgConfig.textOverlayColor = textOverlayColor
        }
        
        if let gradientColors = config.gradientColors {
            bgConfig.gradientColors = gradientColors
        }
        
        return bgConfig
    }
    
    func extractButtonConfiguration(from config: InspectConfig) -> ButtonConfiguration {
        var buttonConfig = ButtonConfiguration()

        if let button1Text = config.button1Text {
            buttonConfig.button1Text = button1Text
            writeLog("Config: Extracted button1Text = '\(button1Text)'", logLevel: .info)
        } else {
            writeLog("Config: button1Text is nil in config", logLevel: .info)
        }

        if let button1Disabled = config.button1Disabled {
            buttonConfig.button1Disabled = button1Disabled
        }

        if let button2Text = config.button2Text {
            buttonConfig.button2Text = button2Text
            writeLog("Config: Extracted button2Text = '\(button2Text)'", logLevel: .info)
        } else {
            writeLog("Config: button2Text is nil in config", logLevel: .info)
        }

        // Deprecated: button2Disabled - button2 is always enabled when shown
        // if let button2Disabled = config.button2Disabled {
        //     buttonConfig.button2Disabled = button2Disabled
        // }

        if let button2Visible = config.button2Visible {
            buttonConfig.button2Visible = button2Visible
        }

        // Deprecated: buttonStyle - not used in Inspect mode
        // if let buttonStyle = config.buttonStyle {
        //     buttonConfig.buttonStyle = buttonStyle
        // }
        
        if let autoEnableButton = config.autoEnableButton {
            buttonConfig.autoEnableButton = autoEnableButton
        }
        
        return buttonConfig
    }
}
