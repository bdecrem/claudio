import SwiftUI

enum Theme {
    // MARK: - Colors
    static let background = Color(hex: "0A0A0A")
    static let surface = Color(hex: "1A1A1A")
    static let accent = Color(hex: "D4A574")
    static let textPrimary = Color(hex: "F5F0EB")
    static let textSecondary = Color(hex: "8A8A8A")

    // MARK: - Fonts
    static let body: Font = .system(.body, design: .rounded)
    static let caption: Font = .system(.caption, design: .rounded)
    static let headline: Font = .system(.headline, design: .rounded)
    static let title: Font = .system(.title3, design: .rounded, weight: .semibold)

    // MARK: - Spacing
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 16
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
