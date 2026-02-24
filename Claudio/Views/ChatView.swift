import SwiftUI

struct ChatView: View {
    @State private var chatService = ChatService()
    @State private var speechRecognizer = SpeechRecognizer()
    @State private var messageText = ""
    @State private var voiceEnabled = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    AgentPicker(
                        selected: Binding(
                            get: { chatService.selectedAgent },
                            set: { chatService.selectedAgent = $0 }
                        ),
                        agents: chatService.agents
                    )
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, Theme.spacing * 2)
                .padding(.vertical, Theme.spacing)

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        if chatService.messages.isEmpty {
                            VStack(spacing: Theme.spacing * 2) {
                                Spacer(minLength: 100)
                                Text("claudio")
                                    .font(.system(.largeTitle, design: .rounded, weight: .light))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.4))
                                Text("start a conversation")
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.textSecondary.opacity(0.3))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                        } else {
                            LazyVStack(spacing: Theme.spacing * 1.5) {
                                ForEach(chatService.messages) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                }
                            }
                            .padding(.vertical, Theme.spacing * 2)
                        }

                        if chatService.isLoading {
                            HStack(spacing: Theme.spacing) {
                                ProgressView()
                                    .tint(Theme.accent)
                                Text("Thinking...")
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                            }
                            .padding(.horizontal, Theme.spacing * 4)
                            .padding(.vertical, Theme.spacing)
                            .id("loading")
                        }
                    }
                    .onChange(of: chatService.messages.count) {
                        scrollToBottom(proxy: proxy)
                    }
                }

                // Input — always text field, voice is a toggle
                InputBar(
                    text: $messageText,
                    voiceEnabled: voiceEnabled,
                    isListening: speechRecognizer.isListening,
                    audioLevel: speechRecognizer.audioLevel,
                    transcript: speechRecognizer.transcript,
                    isSpeaking: chatService.isSpeaking,
                    onSend: sendTextMessage,
                    onToggleVoice: {
                        HapticsManager.tap()
                        voiceEnabled.toggle()
                        if !voiceEnabled && speechRecognizer.isListening {
                            _ = speechRecognizer.stopListening()
                        }
                    },
                    onMicDown: {
                        HapticsManager.tap()
                        speechRecognizer.startListening()
                    },
                    onMicUp: {
                        let transcript = speechRecognizer.stopListening()
                        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            HapticsManager.success()
                            chatService.sendMessage(text, playVoice: true)
                        }
                    },
                    onStopSpeaking: {
                        chatService.stopSpeaking()
                    }
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(chatService: chatService)
        }
        .onAppear {
            speechRecognizer.requestAuthorization()
            Task { await chatService.fetchAgents() }
        }
        .preferredColorScheme(.dark)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastMessage = chatService.messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    private func sendTextMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        chatService.sendMessage(text, playVoice: voiceEnabled)
    }
}
