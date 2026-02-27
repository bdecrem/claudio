#if os(iOS)
import UIKit

enum HapticsManager {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
#else
enum HapticsManager {
    static func tap() {}
    static func success() {}
    static func selection() {}
}
#endif
