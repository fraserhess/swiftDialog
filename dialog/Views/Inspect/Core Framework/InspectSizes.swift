//
//  InspectSizes.swift
//  dialog
//  
//  Created by Henry Stamerjohann, Declarative IT GmbH, 22/09/2025
//
//  This file serves as the source for ech preset optimized window size
//

import Foundation
import CoreGraphics

/// Centralized sizing definitions for all Inspect Mode presets
public enum InspectSizes {

    /// Normalize preset name from short form to canonical form
    /// - Parameter preset: Preset name (e.g., "6" or "preset6")
    /// - Returns: Canonical preset name (e.g., "preset6")
    private static func normalizePreset(_ preset: String) -> String {
        if let number = Int(preset), number >= 1 && number <= 11 {
            return "preset\(number)"
        }
        // Handle named aliases
        let lowercased = preset.lowercased()
        switch lowercased {
        case "portal", "self-service", "webview-portal":
            return "preset11"
        case "bento", "modern-sidebar":
            return "preset6"
        default:
            return lowercased
        }
    }

    /// Get the window size for a specific preset and size mode
    /// - Parameters:
    ///   - preset: In JSON fiel call the preset by name (e.g., "preset1", "preset2", etc.)
    ///   - mode: Set the size mode ("compact", "standard", or "large")
    ///  - Returns: A tuple of (width, height) as CGFloat values
    public static func getSize(preset: String, mode: String) -> (CGFloat, CGFloat) {
        // Normalize short forms to canonical preset names
        let normalizedPreset = normalizePreset(preset)

        switch normalizedPreset {
        case "preset1":
            switch mode {
            case "compact": return (800, 600)
            case "large": return (1024, 768)
            default: return (900, 650)  // standard
            }

        case "preset2":
            switch mode {
            case "compact": return (800, 580)
            case "large": return (1200, 700)
            default: return (1000, 550)  // standard
            }

        case "preset3":
            switch mode {
            case "compact": return (800, 480)  // We are very narrow - special as we'll show two columns
            case "large": return (900, 750)
            default: return (850, 650)  // standard
            }

        case "preset4":
            switch mode {
            case "compact": return (750, 450)
            case "large": return (1100, 650)
            default: return (900, 550)  // standard
            }

        case "preset5":
            switch mode {
            case "compact": return (900, 600)
            case "large": return (1400, 900)
            default: return (1200, 750)  // standard
            }

        case "preset6":
            // Modern Sidebar Variant
            switch mode {
            case "compact": return (720, 480)
            case "large": return (960, 640)
            default: return (800, 560)  // standard
            }

        case "preset7":
            switch mode {
            case "compact": return (900, 600)
            case "large": return (1000, 700)
            default: return (1000, 640)  // standard
            }

        case "preset8":
            switch mode {
            case "compact": return (900, 600)
            case "large": return (1000, 700)
            default: return (1000, 640)  // standard
            }
            
        case "preset9":
            // Modern Two-Panel Onboarding Flow (formerly Preset11)
            switch mode {
            case "compact": return (1000, 680)
            case "large": return (1400, 950)
            default: return (1200, 750)  // standard - increased for better text balance
            }

        case "preset11":
            // Onboarding / Self-Service Portal
            // Fixed window sizes for consistent experience:
            // - Compact/default: 1024×640 (minimum)
            // - Standard: 1100×700 (ideal)
            // - Large: 1200×800 (maximum)
            switch mode {
            case "compact": return (1024, 640)   // Minimum/default
            case "large": return (1200, 800)     // Maximum
            default: return (1100, 700)          // Ideal
            }

        default:
            // Default fallback for unknown presets
            return (1000, 600)
        }
    }

    /// Get the default size for Inspect Mode when no preset is specified
    public static var defaultSize: (CGFloat, CGFloat) {
        return (1000, 600)
    }
}
