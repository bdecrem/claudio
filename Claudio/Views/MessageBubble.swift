import SwiftUI

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            Text(message.content)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, Theme.spacing * 2)
                .padding(.vertical, Theme.spacing * 1.5)
                .background(
                    message.role == .user
                        ? Theme.accent.opacity(0.15)
                        : Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                )

            if message.role == .assistant { Spacer(minLength: 60) }
        }
        .padding(.horizontal, Theme.spacing * 2)
    }
}
