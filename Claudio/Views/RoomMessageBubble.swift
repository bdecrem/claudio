import SwiftUI

struct RoomMessageBubble: View {
    let message: Message
    let myUserId: String

    private var isMe: Bool {
        message.senderId == myUserId
    }

    private var senderColor: Color {
        Theme.participantColor(for: message.senderId ?? "")
    }

    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
            // Sender label (not for own messages)
            if !isMe {
                HStack(spacing: 5) {
                    if let emoji = message.senderEmoji {
                        Text(emoji)
                            .font(.system(size: 12))
                    }
                    Text(message.senderDisplayName ?? "Unknown")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(senderColor)
                }
                .padding(.leading, 4)
            }

            // Bubble
            Text(message.content)
                .font(.system(size: 15, weight: .light, design: .serif))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isMe ? bubbleShapeRight.fill(Theme.accent.opacity(0.15))
                         : bubbleShapeLeft.fill(Theme.surface)
                )
                .overlay(
                    isMe ? AnyShape(bubbleShapeRight).strokeBorder(Theme.accent.opacity(0.2), lineWidth: 1)
                         : AnyShape(bubbleShapeLeft).strokeBorder(senderColor.opacity(0.2), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
        .padding(.horizontal, 14)
    }

    private var bubbleShapeLeft: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: 5,
            bottomTrailingRadius: 18,
            topTrailingRadius: 18,
            style: .continuous
        )
    }

    private var bubbleShapeRight: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: 5,
            topTrailingRadius: 18,
            style: .continuous
        )
    }
}

// AnyShape wrapper for overlay type erasure
private struct AnyShape: Shape {
    private let _path: (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        _path = { shape.path(in: $0) }
    }

    func path(in rect: CGRect) -> Path {
        _path(rect)
    }
}

// InsettableShape conformance for strokeBorder
extension AnyShape: InsettableShape {
    func inset(by amount: CGFloat) -> some InsettableShape {
        // For strokeBorder support, return self with inset
        self
    }
}
