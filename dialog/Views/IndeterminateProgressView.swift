//
//  IndeterminateProgressView.swift
//  dialog
//
//  Created by Bart Reardon on 12/9/2025.
//

import SwiftUI

// This is required as macOS 26 broke the indeterminate progress view animation
// idea source https://matthewcodes.uk/articles/indeterminate-linear-progress-view/

struct IndeterminateProgressView: View {
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
                Rectangle()
                    .foregroundColor(.gray.opacity(0.15))
                    .overlay(
                        Rectangle()
                            .fill(LinearGradient(colors: [.clear, .accentColor, .clear], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * 0.25, height: 8)
                            .clipShape(Capsule())
                            .offset(x: -geometry.size.width * 0.6, y: 0)
                            .offset(x: geometry.size.width * 1.2 * self.offset, y: 0)
                            .animation(.easeInOut.repeatForever().speed(0.25), value: self.offset)
                            .onAppear {
                                withAnimation {
                                    self.offset = 1
                                }
                            }
                    )
                    .clipShape(Capsule())
                    .frame(height: 8)
                    .padding(.top, 6)
            }
    }
}

