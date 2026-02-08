//
//  Preset10.swift
//  dialog
//
//  Preset10: Reserved placeholder
//  This preset slot is reserved for future use.
//

import SwiftUI

struct Preset10View: View {
    @ObservedObject var inspectState: InspectState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.dashed")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Reserved for future use")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preset10 Wrapper

struct Preset10Wrapper: View {
    @ObservedObject var coordinator: InspectState

    var body: some View {
        Preset10View(inspectState: coordinator)
    }
}
