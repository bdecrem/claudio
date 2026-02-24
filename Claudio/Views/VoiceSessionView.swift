import SwiftUI

struct VoiceSessionView: View {
    let eviService: EVIService
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Conversation transcript — starts at top, scrolls down
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Theme.spacing * 1.5) {
                            // All finalized messages
                            ForEach(eviService.sessionMessages.indices, id: \.self) { i in
                                let msg = eviService.sessionMessages[i]
                                voiceMessageBubble(role: msg.role, content: msg.content)
                                    .id("msg-\(i)")
                            }

                            // Live in-progress text (interim speech or streaming response)
                            if !eviService.liveText.isEmpty {
                                voiceMessageBubble(
                                    role: eviService.liveRole,
                                    content: eviService.liveText
                                )
                                .opacity(0.6)
                                .id("live")
                            }
                        }
                        .padding(.vertical, Theme.spacing * 2)
                    }
                    .onChange(of: eviService.sessionMessages.count) {
                        let target = eviService.liveText.isEmpty
                            ? "msg-\(eviService.sessionMessages.count - 1)"
                            : "live"
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .bottom)
                        }
                    }
                    .onChange(of: eviService.liveText) {
                        if !eviService.liveText.isEmpty {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("live", anchor: .bottom)
                            }
                        }
                    }
                }

                // Voice orb + state indicator
                switch eviService.state {
                case .connecting:
                    connectingView
                        .padding(.bottom, Theme.spacing * 2)

                case .error(let message):
                    errorView(message: message)
                        .padding(.bottom, Theme.spacing * 2)

                case .listening, .thinking, .speaking:
                    VoiceOrb(
                        isListening: eviService.state == .listening,
                        audioLevel: eviService.audioLevel,
                        transcript: "",
                        onTap: {}
                    )
                    .frame(height: 200)

                case .idle:
                    connectingView
                        .padding(.bottom, Theme.spacing * 2)
                }

                // State label
                stateLabel
                    .padding(.bottom, Theme.spacing * 4)
            }

            // Stop button — bottom right
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        HapticsManager.tap()
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(Color.red, in: Circle())
                    }
                }
                .padding(.horizontal, Theme.spacing * 3)
                .padding(.bottom, Theme.spacing * 4)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Message bubble matching main chat style

    private func voiceMessageBubble(role: String, content: String) -> some View {
        HStack {
            if role == "user" { Spacer(minLength: 60) }

            Text(content)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.spacing * 2)
                .padding(.vertical, Theme.spacing * 1.5)
                .background(
                    role == "user"
                        ? Theme.accent.opacity(0.15)
                        : Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                )

            if role == "assistant" { Spacer(minLength: 60) }
        }
        .padding(.horizontal, Theme.spacing * 2)
    }

    // MARK: - Sub-views

    private var connectingView: some View {
        VStack(spacing: Theme.spacing * 2) {
            ProgressView()
                .tint(Theme.accent)
                .scaleEffect(1.5)
            Text("Connecting...")
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: Theme.spacing * 2) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent.opacity(0.6))

            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacing * 4)

            Text("Tap to reconnect")
                .font(Theme.caption)
                .foregroundStyle(Theme.accent.opacity(0.6))
        }
        .onTapGesture {
            HapticsManager.tap()
            onDismiss()
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch eviService.state {
        case .listening:
            Text("Listening")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.accent)
                .transition(.opacity)

        case .thinking:
            HStack(spacing: Theme.spacing) {
                ProgressView()
                    .tint(Theme.accent)
                Text("Thinking...")
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .transition(.opacity)

        case .speaking:
            Text("Speaking")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.accent)
                .transition(.opacity)

        default:
            EmptyView()
        }
    }
}
