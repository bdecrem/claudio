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

            // Bubble
            HStack {
                if message.role == .user { Spacer(minLength: 60) }

                Text(message.content)
                    .font(.system(size: 15, weight: .light, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .overlay(bubbleOverlay)

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
