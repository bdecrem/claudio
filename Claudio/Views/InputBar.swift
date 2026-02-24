import SwiftUI

struct InputBar: View {
    @Binding var text: String
    let voiceEnabled: Bool
    let voiceSessionActive: Bool
    let isListening: Bool
    let audioLevel: Float
    let transcript: String
    let isSpeaking: Bool
    let onSend: () -> Void
    let onToggleVoice: () -> Void
    let onMicDown: () -> Void
    let onMicUp: () -> Void
    let onStopSpeaking: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: Theme.spacing) {
            // Live transcript while recording
            if isListening, !transcript.isEmpty {
                Text(transcript)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.spacing * 2)
                    .transition(.opacity)
            }

            // Speaking indicator
            if isSpeaking {
                HStack(spacing: Theme.spacing) {
                    SpeakingWave()
                        .frame(width: 24, height: 16)
                    Text("Speaking...")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Button {
                        onStopSpeaking()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(Theme.surface, in: Circle())
                    }
                }
                .padding(.horizontal, Theme.spacing * 2)
                .transition(.opacity)
            }

            // Input row — always present
            HStack(spacing: Theme.spacing) {
                // Text field
                HStack(spacing: Theme.spacing) {
                    TextField("Message", text: $text)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                        .focused($isFocused)
                        .tint(Theme.accent)
                        .disabled(isListening)
                        .submitLabel(.send)
                        .onSubmit {
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                onSend()
                            }
                        }
                }
                .padding(.horizontal, Theme.spacing * 1.5)
                .padding(.vertical, Theme.spacing * 1.25)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                // Mic (hold to speak) or Send
                if !text.isEmpty {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 36, height: 36)
                            .background(Theme.accent, in: Circle())
                    }
                    .transition(.scale.combined(with: .opacity))
                } else if voiceEnabled {
                    micButton
                        .transition(.scale.combined(with: .opacity))
                }

                // Voice mode toggle (right side)
                Button {
                    onToggleVoice()
                } label: {
                    Image(systemName: voiceSessionActive ? "waveform.circle.fill" : "waveform")
                        .font(.system(size: voiceSessionActive ? 22 : 17))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Theme.accent, in: Circle())
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: text.isEmpty)
        }
        .padding(.horizontal, Theme.spacing * 2)
        .padding(.vertical, Theme.spacing * 1.5)
        .background(Theme.background)
    }

    private var micButton: some View {
        Image(systemName: isListening ? "mic.fill" : "mic")
            .font(.system(size: 16))
            .foregroundStyle(isListening ? Theme.background : Theme.accent)
            .frame(width: 36, height: 36)
            .background(
                isListening ? Theme.accent : Theme.accent.opacity(0.15),
                in: Circle()
            )
            .scaleEffect(isListening ? 1.1 + CGFloat(audioLevel) * 0.15 : 1.0)
            .animation(.easeOut(duration: 0.1), value: audioLevel)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isListening { onMicDown() }
                    }
                    .onEnded { _ in
                        if isListening { onMicUp() }
                    }
            )
    }
}

// MARK: - Speaking Wave

private struct SpeakingWave: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 3, height: animate ? CGFloat.random(in: 6...16) : 4)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever()
                            .delay(Double(i) * 0.1),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}
