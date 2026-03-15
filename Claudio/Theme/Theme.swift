import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Theme Manager (persists user's appearance preferences)

@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    var backgroundHex: String {
        didSet { UserDefaults.standard.set(backgroundHex, forKey: "theme_backgroundHex") }
    }

    /// When true, UI uses light text (for dark backgrounds). When false, dark text (for light backgrounds).
    var lightText: Bool {
        didSet { UserDefaults.standard.set(lightText, forKey: "theme_lightText") }
    }

    /// When true, hides the macOS title bar so the background color bleeds through.
    var transparentTitleBar: Bool {
        didSet {
            UserDefaults.standard.set(transparentTitleBar, forKey: "theme_transparentTitleBar")
            applyTitleBarStyle()
        }
    }

    private init() {
        self.backgroundHex = UserDefaults.standard.string(forKey: "theme_backgroundHex") ?? "0A0A0A"
        // Default to true (light text on dark background)
        if UserDefaults.standard.object(forKey: "theme_lightText") != nil {
            self.lightText = UserDefaults.standard.bool(forKey: "theme_lightText")
        } else {
            self.lightText = true
        }
        self.transparentTitleBar = UserDefaults.standard.bool(forKey: "theme_transparentTitleBar")
    }

    func applyTitleBarStyle() {
        #if targetEnvironment(macCatalyst)
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let titlebar = windowScene.titlebar else { return }
            if self.transparentTitleBar {
                titlebar.titleVisibility = .hidden
                titlebar.separatorStyle = .none
                windowScene.titlebar?.toolbar = nil
            }
        }
        #elseif os(macOS)
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first else { return }
            if self.transparentTitleBar {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
            }
        }
        #endif
    }
}

// MARK: - Theme

enum Theme {
    private static var mgr: ThemeManager { ThemeManager.shared }

    // MARK: - Colors

    static var background: Color { Color(hex: mgr.backgroundHex) }

    static var surface: Color {
        mgr.lightText ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }
    static var surface2: Color {
        mgr.lightText ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }
    static var border: Color {
        mgr.lightText ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
    }

    static let accent = Color(hex: "D4A44C")
    static var accentDim: Color { accent.opacity(0.12) }

    static var textPrimary: Color {
        mgr.lightText ? Color(hex: "E8E8E8") : Color(hex: "1A1A1A")
    }
    static var textSecondary: Color {
        mgr.lightText ? Color(hex: "999999") : Color(hex: "555555")
    }
    static var textDim: Color {
        mgr.lightText ? Color(hex: "3A3A3A") : Color(hex: "BBBBBB")
    }

    /// For text/icons placed on accent-colored backgrounds (e.g. send button arrow)
    static let onAccent = Color(hex: "0A0A0A")

    static let green = Color(hex: "3DBD6C")
    static let danger = Color(hex: "C0392B")

    static var colorScheme: ColorScheme {
        mgr.lightText ? .dark : .light
    }

    // Participant colors for group chat differentiation
    static let participantColors: [Color] = [
        Color(hex: "D4A44C"),  // warm gold (accent)
        Color(hex: "6CB4EE"),  // soft blue
        Color(hex: "B57EDC"),  // lavender
        Color(hex: "3DBD6C"),  // green
        Color(hex: "E88D67"),  // coral
    ]

    static func participantColor(for id: String) -> Color {
        let hash = abs(id.hashValue)
        return participantColors[hash % participantColors.count]
    }

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

    func toHex() -> String {
        #if os(iOS)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #elseif os(macOS)
        let ns = NSColor(self)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return "000000" }
        return String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        #endif
    }
}
