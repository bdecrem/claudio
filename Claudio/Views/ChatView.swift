import SwiftUI
import PhotosUI

struct ChatView: View {
    @State private var chatService = ChatService()
    @State private var speechRecognizer = SpeechRecognizer()
    @State private var voiceService = VoiceService()
    @State private var messageText = ""
    @State private var voiceEnabled = false
    @State private var showSettings = false
    @State private var showVoiceSession = false
    @State private var pendingImages: [ImageAttachment] = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            if !chatService.hasServer {
                VStack(spacing: Theme.spacing * 3) {
                    Spacer()

                    Text("claudio")
                        .font(.system(.largeTitle, design: .rounded, weight: .light))
                        .foregroundStyle(Theme.textSecondary.opacity(0.4))

                    Text("Connect to your server to get started.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                        .multilineTextAlignment(.center)

                    Button {
                        showSettings = true
                    } label: {
                        Text("Add Server")
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .foregroundStyle(Theme.background)
                            .padding(.horizontal, Theme.spacing * 3)
                            .padding(.vertical, Theme.spacing * 1.5)
                            .background(Theme.accent, in: Capsule())
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                                .frame(width: 32)

                            Spacer()

                            // Centered agent name
                            VStack(spacing: 2) {
                                Text(currentAgentName)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)

                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(connectionStatusColor)
                                        .frame(width: 6, height: 6)
                                        .shadow(color: connectionStatusColor.opacity(0.6), radius: 3)
                                        .modifier(PulseOpacity())
                                    Text(connectionStatusText)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }

                            Spacer()

                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(6)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 10)

                        Theme.border.frame(height: 1)
                    }

                    // Agent switcher pills
                    if chatService.visibleAgents.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            AgentPicker(
                                selected: Binding(
                                    get: { chatService.selectedAgent },
                                    set: { chatService.selectedAgent = $0 }
                                ),
                                agents: chatService.visibleAgents,
                                unreadAgentIds: chatService.unreadAgentIds
                            )
                            .padding(.horizontal, 16)
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            Color.white.opacity(0.03).frame(height: 1)
                        }
                    }

                    // Messages with fade edges
                    ZStack {
                        ScrollViewReader { proxy in
                            ScrollView {
                                if chatService.messages.isEmpty {
                                    VStack(spacing: Theme.spacing * 2) {
                                        Spacer(minLength: 100)
                                        Text("claudio")
                                            .font(.system(.largeTitle, design: .rounded, weight: .light))
                                            .foregroundStyle(Theme.textSecondary.opacity(0.4))
                                        Text("start a conversation")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Theme.textDim)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 120)
                                } else {
                                    LazyVStack(spacing: 0) {
                                        ForEach(chatService.messages) { message in
                                            MessageBubble(
                                                message: message,
                                                agentName: message.role == .assistant ? currentAgentName : ""
                                            )
                                            .id(message.id)
                                            .padding(.bottom, 12)
                                        }
                                    }
                                    .padding(.vertical, 16)
                                }

                                if chatService.isLoading && !hasStreamingMessage {
                                    // Agent label above thinking bubble
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(Theme.green)
                                                .frame(width: 5, height: 5)
                                                .shadow(color: Theme.green.opacity(0.5), radius: 2)
                                            Text(currentAgentName)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                        .padding(.leading, 4)

                                        HStack(spacing: 10) {
                                            ThinkingDots()
                                            Text("working")
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(Theme.textDim)
                                                .italic()
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(
                                            UnevenRoundedRectangle(
                                                topLeadingRadius: 18,
                                                bottomLeadingRadius: 5,
                                                bottomTrailingRadius: 18,
                                                topTrailingRadius: 18,
                                                style: .continuous
                                            )
                                            .fill(Theme.surface)
                                        )
                                        .overlay(
                                            UnevenRoundedRectangle(
                                                topLeadingRadius: 18,
                                                bottomLeadingRadius: 5,
                                                bottomTrailingRadius: 18,
                                                topTrailingRadius: 18,
                                                style: .continuous
                                            )
                                            .strokeBorder(Theme.border, lineWidth: 1)
                                        )
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 20)
                                    .id("loading")
                                }
                            }
                            .defaultScrollAnchor(.bottom)
                            .onChange(of: chatService.messages.count) {
                                scrollToBottom(proxy: proxy)
                            }
                            .onChange(of: streamingContent) {
                                scrollToBottom(proxy: proxy)
                            }
                            .onChange(of: chatService.isLoading) {
                                if chatService.isLoading && !hasStreamingMessage {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo("loading", anchor: .bottom)
                                    }
                                }
                            }
                        }

                        // Top fade
                        VStack {
                            LinearGradient(
                                colors: [Theme.background, Theme.background.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 28)
                            .allowsHitTesting(false)

                            Spacer()

                            // Bottom fade
                            LinearGradient(
                                colors: [Theme.background.opacity(0), Theme.background],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 28)
                            .allowsHitTesting(false)
                        }
                    }

                    // Pending image thumbnails
                    if !pendingImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(pendingImages) { img in
                                    ZStack(alignment: .topTrailing) {
                                        if let image = PlatformImage(data: img.data) {
                                            Image(platformImage: image)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 56, height: 56)
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        }
                                        Button {
                                            pendingImages.removeAll { $0.id == img.id }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(Theme.background)
                                                .frame(width: 16, height: 16)
                                                .background(Theme.textSecondary, in: Circle())
                                        }
                                        .offset(x: 4, y: -4)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.bottom, 4)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Input
                    InputBar(
                        text: $messageText,
                        agentName: currentAgentName,
                        voiceEnabled: voiceEnabled,
                        voiceSessionActive: showVoiceSession,
                        isListening: speechRecognizer.isListening,
                        audioLevel: speechRecognizer.audioLevel,
                        transcript: speechRecognizer.transcript,
                        isSpeaking: chatService.isSpeaking,
                        pendingImageCount: pendingImages.count,
                        onSend: sendTextMessage,
                        onToggleVoice: {
                            HapticsManager.tap()
                            startVoiceSession()
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
                        },
                        onPickImage: {
                            showPhotoPicker = true
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(chatService: chatService)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .onChange(of: selectedPhotos) { _, items in
            Task { await loadSelectedPhotos(items) }
            selectedPhotos = []
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showVoiceSession) {
            VoiceSessionView(
                voiceService: voiceService,
                onDismiss: { endVoiceSession() }
            )
            .background(Theme.background)
            .preferredColorScheme(.dark)
        }
        #else
        .sheet(isPresented: $showVoiceSession) {
            VoiceSessionView(
                voiceService: voiceService,
                onDismiss: { endVoiceSession() }
            )
            .background(Theme.background)
            .preferredColorScheme(.dark)
            .frame(minWidth: 400, minHeight: 500)
        }
        #endif
        .onAppear {
            speechRecognizer.requestAuthorization()
            if chatService.hasServer {
                chatService.connectWebSocket()
            }
            if ChaosService.shared.shouldCheckNow {
                Task {
                    if let instruction = await ChaosService.shared.fetchInstruction() {
                        chatService.sendMessage(instruction, playVoice: false)
                        ChaosService.shared.markTriggered()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var hasStreamingMessage: Bool {
        chatService.messages.contains { $0.isStreaming }
    }

    private var streamingContent: String {
        chatService.messages.last(where: { $0.isStreaming })?.content ?? ""
    }

    private var currentAgentName: String {
        if let agent = chatService.agents.first(where: { $0.id == chatService.selectedAgent }) {
            return agent.name
        }
        return chatService.selectedAgent.isEmpty ? "Claudio" : chatService.selectedAgent
    }

    private var connectionStatusColor: Color {
        switch chatService.wsConnectionState {
        case .connected: return Theme.green
        case .connecting: return Theme.accent
        case .error, .pairingRequired: return Theme.danger
        case .disconnected: return Theme.textSecondary
        }
    }

    private var connectionStatusText: String {
        switch chatService.wsConnectionState {
        case .connected: return "online"
        case .connecting: return "connecting"
        case .error: return "error"
        case .pairingRequired: return "pairing needed"
        case .disconnected: return "offline"
        }
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
        guard !text.isEmpty || !pendingImages.isEmpty else { return }
        let images = pendingImages
        messageText = ""
        pendingImages = []
        chatService.sendMessage(
            text.isEmpty ? "What's in this image?" : text,
            playVoice: voiceEnabled,
            imageAttachments: images
        )
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            guard let resized = resizeImageData(data, maxDimension: 1024) else { continue }
            let attachment = ImageAttachment(
                filename: "photo.jpg",
                contentType: "image/jpeg",
                data: resized
            )
            await MainActor.run { pendingImages.append(attachment) }
        }
    }

    private func resizeImageData(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let cgImage = cgImageFromData(data) else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let scale = min(maxDimension / max(width, height), 1.0)
        let newWidth = Int(width * scale)
        let newHeight = Int(height * scale)

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: newWidth,
                  height: newHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let resizedCG = context.makeImage() else { return nil }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, resizedCG, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private func cgImageFromData(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func startVoiceSession() {
        guard let server = chatService.selectedServer else { return }

        if speechRecognizer.isListening {
            _ = speechRecognizer.stopListening()
        }
        chatService.stopSpeaking()

        showVoiceSession = true

        let agentId = chatService.selectedAgentId
        let chatHistory = chatService.messages.map { $0.apiRepresentation }

        voiceService.start(
            agentId: agentId,
            chatHistory: chatHistory,
            speechRecognizer: speechRecognizer,
            sendHandler: { [chatService] messages async throws -> String in
                try await chatService.sendForVoice(
                    serverURL: server.url,
                    token: server.token,
                    agentId: agentId,
                    messages: messages
                )
            },
            ttsHandler: { [chatService] text async in
                await chatService.playTTSPublic(for: text, agentId: agentId, server: server)
            }
        )
    }

    private func endVoiceSession() {
        voiceService.flushPending()

        for msg in voiceService.sessionMessages {
            let role: Message.Role = msg.role == "user" ? .user : .assistant
            chatService.appendVoiceMessage(role: role, content: msg.content)
        }

        showVoiceSession = false
        voiceService.stop()
        voiceService.sessionMessages = []
    }
}

// MARK: - Thinking Dots

private struct ThinkingDots: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: 5, height: 5)
                    .scaleEffect(animate ? 1.0 : 0.8)
                    .opacity(animate ? 1.0 : 0.2)
                    .animation(
                        .easeInOut(duration: 1.2)
                            .repeatForever()
                            .delay(Double(i) * 0.2),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

// MARK: - Pulse Opacity (for status dot)

private struct PulseOpacity: ViewModifier {
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(pulsing ? 1.0 : 0.4)
            .animation(
                .easeInOut(duration: 2.5).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}
