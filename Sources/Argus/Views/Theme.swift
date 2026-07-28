import SwiftUI

// MARK: - Flight Deck theme
// Glass-cockpit-at-night: deep navy panel, instrument white, cyan for normal
// ops, amber strictly for "act now" (avionics color law). Identity and
// annunciators in Avenir Next Condensed caps; digits always tabular.

enum Deck {
    static let bg = Color(hex: 0x0C1826)
    static let line = Color(hex: 0x16293A)
    static let rowLine = Color(hex: 0x10202E)
    static let text = Color(hex: 0xDFE9F2)
    static let muted = Color(hex: 0x6F92AB)
    static let dim = Color(hex: 0x46617A)
    static let cyan = Color(hex: 0x55C8E8)
    static let amber = Color(hex: 0xFFB454)
    static let green = Color(hex: 0x63E6B0)
    static let stall = Color(hex: 0xC8B46A)
    static let red = Color(hex: 0xE8746A)

    static func display(_ size: CGFloat) -> Font {
        .custom("AvenirNextCondensed-DemiBold", size: size)
    }
    static func label(_ size: CGFloat) -> Font {
        .custom("AvenirNextCondensed-Medium", size: size)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    init(status: SessionStatus) {
        switch status {
        case .working: self = Deck.cyan
        case .needsYou: self = Deck.amber
        case .ready: self = Deck.green
        case .stalled: self = Deck.stall
        case .idle: self = Deck.muted
        case .dead: self = Deck.red
        case .ended: self = Deck.dim
        }
    }
}
