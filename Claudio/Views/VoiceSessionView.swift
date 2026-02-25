import SwiftUI

struct VoiceSessionView: View {
    let voiceService: VoiceService
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Conversation transcript
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Theme.spacing * 1.5) {
                            ForEach(voiceService.sessionMessages.indices, id: \.self) { i in
                                let msg = voiceService.sessionMessages[i]
                                voiceMessageBubble(role: msg.role, content: msg.content)
                                    .id("msg-\(i)")
                            }

                            if !voiceService.liveText.isEmpty {
                                voiceMessageBubble(
                                    role: voiceService.state == .listening ? "user" : "assistant",
                                    content: voiceService.liveText
                                )
                                .opacity(0.6)
                                .id("live")
                            }
                        }
                        .padding(.vertical, Theme.spacing * 2)
                    }
                    .onChange(of: voiceService.sessionMessages.count) {
                        let target = voiceService.liveText.isEmpty
                            ? "msg-\(voiceService.sessionMessages.count - 1)"
                            : "live"
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .bottom)
                        }
                    }
                    .onChange(of: voiceService.liveText) {
                        if !voiceService.liveText.isEmpty {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("live", anchor: .bottom)
                            }
                        }
                    }
                }

                // Voice orb + state
                switch voiceService.state {
                case .error(let message):
                    errorView(message: message)
                        .padding(.bottom, Theme.spacing * 2)

                case .listening, .sending, .speaking:
                    VoiceOrb(
                        isListening: voiceService.state == .listening,
                        audioLevel: voiceService.audioLevel,
                        transcript: "",
                        onTap: {}
                    )
                    .frame(height: 200)

                case .idle:
                    connectingView
                        .padding(.bottom, Theme.spacing * 2)
                }

                stateLabel
                    .padding(.bottom, Theme.spacing * 4)
            }

            // Stop button
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
                            .background(Color(red: 0.75, green: 0.28, blue: 0.25), in: Circle())
                    }
                }
                .padding(.trailing, 36)
                .padding(.bottom, 48)
            }
        }
        .preferredColorScheme(.dark)
    }

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

    private var connectingView: some View {
        VStack(spacing: Theme.spacing * 2) {
            ProgressView()
                .tint(Theme.accent)
                .scaleEffect(1.5)
            Text("Starting...")
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

            Text("Tap to close")
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
        switch voiceService.state {
        case .listening:
            Text("Listening")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.accent)
                .transition(.opacity)

        case .sending:
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
