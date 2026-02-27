import SwiftUI

struct MessageBubble: View {
    let message: Message
    var agentName: String = ""

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
            // Agent label with green dot (assistant only)
            if message.role == .assistant, !agentName.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.green)
                        .frame(width: 5, height: 5)
                        .shadow(color: Theme.green.opacity(0.5), radius: 2)
                    Text(agentName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.leading, 4)
                .padding(.bottom, 2)
            }

            // Tool calls (above the text bubble for assistant messages)
            if message.role == .assistant, !message.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(message.toolCalls) { tc in
                        ToolCallCard(toolCall: tc)
                    }
                }
                .padding(.bottom, 4)
            }

            // Image attachments
            if !message.imageAttachments.isEmpty {
                HStack {
                    if message.role == .user { Spacer(minLength: 60) }
                    HStack(spacing: 6) {
                        ForEach(message.imageAttachments) { img in
                            if let image = PlatformImage(data: img.data) {
                                Image(platformImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(maxWidth: 200, maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                    if message.role == .assistant { Spacer(minLength: 60) }
                }
            }

            // Bubble
            HStack {
                if message.role == .user { Spacer(minLength: 60) }

                HStack(spacing: 0) {
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.system(size: 15, weight: .light, design: .serif))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .lineSpacing(3)
                    }

                    if message.isStreaming {
                        StreamingCursor()
                            .padding(.leading, 1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .overlay(bubbleOverlay)
                // Hide empty bubble when only tool calls are showing
                .opacity(message.content.isEmpty && !message.isStreaming && message.imageAttachments.isEmpty ? 0 : 1)
                .frame(height: message.content.isEmpty && !message.isStreaming && message.imageAttachments.isEmpty ? 0 : nil)

                if message.role == .assistant { Spacer(minLength: 60) }
            }

            // Timestamp
            Text(timeString)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 4)
                .padding(.top, 1)
        }
        .padding(.horizontal, 14)
    }

    private var timeString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: message.timestamp)
    }

    private var bubbleBackground: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: message.role == .assistant ? 5 : 18,
            bottomTrailingRadius: message.role == .user ? 5 : 18,
            topTrailingRadius: 18,
            style: .continuous
        )
        .fill(message.role == .user ? Theme.surface2 : Theme.surface)
    }

    private var bubbleOverlay: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: message.role == .assistant ? 5 : 18,
            bottomTrailingRadius: message.role == .user ? 5 : 18,
            topTrailingRadius: 18,
            style: .continuous
        )
        .strokeBorder(
            message.role == .user
                ? Color.white.opacity(0.06)
                : Theme.border,
            lineWidth: 1
        )
    }
}

// MARK: - Streaming Cursor

private struct StreamingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent)
            .frame(width: 2, height: 16)
            .opacity(visible ? 1 : 0)
            .animation(
                .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                value: visible
            )
            .onAppear { visible = false }
    }
}
