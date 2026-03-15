import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Cross-platform toolbar placement

extension ToolbarItemPlacement {
    #if os(macOS)
    /// Maps to .cancellationAction on macOS (topBarLeading equivalent)
    static var compatLeading: ToolbarItemPlacement { .cancellationAction }
    /// Maps to .confirmationAction on macOS (topBarTrailing equivalent)
    static var compatTrailing: ToolbarItemPlacement { .confirmationAction }
    #else
    static var compatLeading: ToolbarItemPlacement { .topBarLeading }
    static var compatTrailing: ToolbarItemPlacement { .topBarTrailing }
    #endif
}

// MARK: - Cross-platform view modifiers

extension View {
    /// .navigationBarTitleDisplayMode(.inline) on iOS, no-op on macOS
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// .textInputAutocapitalization on iOS, no-op on macOS
    @ViewBuilder
    func platformAutocapitalization(_ style: PlatformAutocapStyle) -> some View {
        #if os(iOS)
        switch style {
        case .never:
            self.textInputAutocapitalization(.never)
        case .words:
            self.textInputAutocapitalization(.words)
        case .characters:
            self.textInputAutocapitalization(.characters)
        }
        #else
        self
        #endif
    }

    /// .fullScreenCover on iOS, .sheet on macOS
    @ViewBuilder
    func platformFullScreen<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }

    /// .fullScreenCover(item:) on iOS, .sheet(item:) on macOS
    @ViewBuilder
    func platformFullScreen<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item, content: content)
        #endif
    }

    /// .hoverEffect on iOS, no-op on macOS (macOS handles hover natively)
    @ViewBuilder
    func platformHoverEffect() -> some View {
        #if os(iOS)
        self.hoverEffect(.lift)
        #else
        self
        #endif
    }
}

/// Creates a SwiftUI Image from raw data, cross-platform
func platformImage(from data: Data) -> Image? {
    guard let img = PlatformImage(data: data) else { return nil }
    #if os(iOS)
    return Image(uiImage: img)
    #elseif os(macOS)
    return Image(nsImage: img)
    #endif
}

enum PlatformAutocapStyle {
    case never, words, characters
}

// MARK: - Cross-platform clipboard

func copyToClipboard(_ string: String) {
    #if os(iOS)
    UIPasteboard.general.string = string
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #endif
}
