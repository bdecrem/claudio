import SwiftUI

struct VoiceSessionView: View {
    let eviService: EVIService
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with close button
                HStack {
                    Spacer()
                    Button {
                        HapticsManager.tap()
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 36, height: 36)
                            .background(Theme.surface, in: Circle())
                    }
                }
                .padding(.horizontal, Theme.spacing * 2)
                .padding(.top, Theme.spacing * 2)

                Spacer()

                // Main content
                switch eviService.state {
                case .connecting:
                    connectingView

                case .error(let message):
                    errorView(message: message)

                case .listening, .thinking, .speaking:
                    voiceActiveView

                case .idle:
                    // Shouldn't normally be visible, but handle gracefully
                    connectingView
                }

                Spacer()

                // State label
                stateLabel
                    .padding(.bottom, Theme.spacing * 6)
            }
        }
        .preferredColorScheme(.dark)
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

    private var voiceActiveView: some View {
        VoiceOrb(
            isListening: eviService.state == .listening,
            audioLevel: eviService.audioLevel,
            transcript: eviService.transcript,
            onTap: {}
        )
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
