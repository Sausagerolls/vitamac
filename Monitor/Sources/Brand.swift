import SwiftUI

/// VitaMac brand palette, taken from the gauge-pulse app icon: dark navy base
/// with a blue → teal → green accent sweep and a light-cyan pulse highlight.
enum Brand {
    static let blue  = Color(red: 0.231, green: 0.510, blue: 0.965) // #3b82f6
    static let cyan  = Color(red: 0.133, green: 0.827, blue: 0.933) // #22d3ee
    static let teal  = Color(red: 0.176, green: 0.831, blue: 0.749) // #2dd4bf
    static let green = Color(red: 0.204, green: 0.827, blue: 0.600) // #34d399
    static let pulse = Color(red: 0.647, green: 0.953, blue: 0.988) // #a5f3fc
    static let slate = Color(red: 0.45,  green: 0.55,  blue: 0.70)

    static let accent = cyan

    static let bgTop = Color(red: 0.047, green: 0.090, blue: 0.200) // #0c1733
    static let bgBot = Color(red: 0.039, green: 0.071, blue: 0.149) // #0a1226
    static let navy = LinearGradient(colors: [bgTop, bgBot], startPoint: .top, endPoint: .bottom)

    /// Translucent row/card fill that sits a notch above the navy background
    /// instead of a stark dark block.
    static let card = Color.white.opacity(0.06)
    static let separator = Color.white.opacity(0.10)
}
