import SwiftUI
import UIKit

/// Warm colors drawn from the app icon. Model vertex colors remain unchanged.
enum ScanTheme {
    static let background = Color(hex: 0xFCF6EA)
    static let surface = Color(hex: 0xF5E9D4)
    static let card = Color(hex: 0xFFFAF1)
    static let primary = Color(hex: 0x3E3023)
    static let secondary = Color(hex: 0x75634F)
    static let accent = Color(hex: 0xE8C98D)
    static let accentPressed = Color(hex: 0xDDBC7B)
    static let tint = Color(hex: 0x855722)
    static let border = Color(hex: 0xDAC7A8)
    static let destructive = Color(hex: 0xA33C30)

    // A warm, quiet backdrop keeps measured RGB point clouds easy to see.
    static let canvasUIColor = UIColor(red: 40 / 255, green: 34 / 255, blue: 29 / 255, alpha: 1)
    static let canvas = Color(uiColor: canvasUIColor)
    static let canvasAccent = Color(hex: 0xF1DAB0)
    static let canvasText = Color(hex: 0xF7ECD9)
    static let canvasTrack = Color(hex: 0x5A4D3E)
    static let canvasOverlay = Color(hex: 0x211B16).opacity(0.82)
    static let scrim = Color(hex: 0x3E3023).opacity(0.32)
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
