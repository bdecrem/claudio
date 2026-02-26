import SwiftUI

struct VoiceOrb: View {
    let isListening: Bool
    let audioLevel: Float
    let transcript: String
    let onTap: () -> Void

    @State private var pulse = false

    var body: some View {
        VStack(spacing: Theme.spacing * 3) {
            ZStack {
                // Outer ring
                Circle()
                    .fill(Theme.accent.opacity(0.08))
                    .frame(width: 160, height: 160)
                    .scaleEffect(pulse ? 1.15 : 1.0)
                    .scaleEffect(1.0 + CGFloat(audioLevel) * 0.2)
                    .opacity(pulse ? 0.6 : 0.3)

                // Middle ring
                Circle()
                    .fill(Theme.accent.opacity(0.15))
                    .frame(width: 120, height: 120)
                    .scaleEffect(pulse ? 1.1 : 1.0)
                    .scaleEffect(1.0 + CGFloat(audioLevel) * 0.15)
                    .opacity(pulse ? 0.7 : 0.5)

                // Core orb
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Theme.accent.opacity(0.9),
                                Theme.accent.opacity(0.5)
                            ],
                            center: .center,
                            startRadius: 10,
                            endRadius: 40
                        )
                    )
                    .frame(width: 80, height: 80)
                    .scaleEffect(1.0 + CGFloat(audioLevel) * 0.1)
                    .shadow(color: Theme.accent.opacity(0.4), radius: isListening ? 30 : 15)
            }
            .onTapGesture {
                HapticsManager.tap()
                onTap()
            }

            if !transcript.isEmpty {
                Text(transcript)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, Theme.spacing * 4)
                    .transition(.opacity)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .animation(.easeInOut(duration: 0.1), value: audioLevel)
    }
}
