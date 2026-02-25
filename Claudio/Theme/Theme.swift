import SwiftUI

enum Theme {
    // MARK: - Colors
    static let background = Color(hex: "0A0A0A")
    static let surface = Color(hex: "161616")
    static let surface2 = Color(hex: "1E1E1E")
    static let border = Color(hex: "2A2A2A")
    static let accent = Color(hex: "D4A44C")
    static let accentDim = Color(hex: "D4A44C").opacity(0.12)
    static let textPrimary = Color(hex: "E8E8E8")
    static let textSecondary = Color(hex: "666666")
    static let textDim = Color(hex: "3A3A3A")
    static let green = Color(hex: "3DBD6C")
    static let danger = Color(hex: "C0392B")

    // MARK: - Fonts
    static let body: Font = .system(.body, design: .rounded)
    static let caption: Font = .system(.caption, design: .rounded)
    static let headline: Font = .system(.headline, design: .rounded)
    static let title: Font = .system(.title3, design: .rounded, weight: .semibold)
    static let mono: Font = .system(.caption, design: .monospaced)

    // MARK: - Spacing
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 14
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }
}
