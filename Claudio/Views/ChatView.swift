import SwiftUI
import PhotosUI
#if os(macOS)
import AppKit
#endif

struct ChatView: View {
    @Bindable var chatService: ChatService
    @State private var roomService = RoomService()
    @State private var speechRecognizer = SpeechRecognizer()
    @State private var voiceService = VoiceService()
    @State private var messageText = ""
    @State private var voiceEnabled = false
    @State private var showSettings = false
    @State private var showVoiceSession = false
    @State private var pendingImages: [ImageAttachment] = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var selectedRoom: Room?
    @State private var showLobby = false
    @State private var showNotificationPrompt = false
    @State private var showRoomSettings = false

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            if !chatService.hasServer {
                // No server — onboarding
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        lobbyButton
                        settingsButton
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    Theme.border.frame(height: 1)

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
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, Theme.spacing * 3)
                                .padding(.vertical, Theme.spacing * 1.5)
                                .background(Theme.accent, in: Capsule())
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            } else if let room = selectedRoom {
                // Room chat mode (inline, only when picker row is active)
                VStack(spacing: 0) {
                    // Header — matches agent header layout
                    VStack(spacing: 0) {
                        ZStack {
                            VStack(spacing: 2) {
                                Text(room.name)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(roomService.activeRoom?.participants.count ?? 0) participants")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                            }

                            HStack {
                                Spacer()
                                settingsButton
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 10)

                        Theme.border.frame(height: 1)
                    }

                    pickerSection
                    RoomChatView(
                        roomService: roomService,
                        chatService: chatService,
                        room: room,
                        hideHeader: true,
                        onOpenSettings: { showRoomSettings = true }
                    )
                }
            } else {
                // Agent chat mode
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 0) {
                        ZStack {
                            // Title: centered to full screen width
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

                            // Icons: pinned to trailing edge
                            HStack {
                                Spacer()

                                if !needsPickerRow {
                                    lobbyButton
                                }

                                settingsButton
                                    .contextMenu {
                                        if chatService.savedServers.count > 1 {
                                            ForEach(Array(chatService.savedServers.enumerated()), id: \.offset) { index, server in
                                                let name = server.nickname.isEmpty ? serverDisplayName(for: server.url) : server.nickname
                                                Button {
                                                    chatService.switchServer(to: index)
                                                } label: {
                                                    if index == chatService.activeServerIndex {
                                                        Label(name, systemImage: "checkmark")
                                                    } else {
                                                        Text(name)
                                                    }
                                                }
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 10)

                        Theme.border.frame(height: 1)
                    }

                    // Agent/room picker (only when multiple agents or joined rooms)
                    pickerSection

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
                                                agentName: message.role == .assistant ? currentAgentName : "",
                                                serverURL: chatService.httpBaseURL,
                                                serverToken: chatService.selectedServer?.token ?? ""
                                            )
                                            .id(message.id)
                                            .padding(.bottom, 12)
                                        }
                                    }
                                    .padding(.vertical, 16)
                                    .frame(maxWidth: 720)
                                    .frame(maxWidth: .infinity)
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
                            .scrollDismissesKeyboard(.interactively)
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
                                        if let swiftImage = platformImage(from: img.data) {
                                            swiftImage
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
                                                .foregroundStyle(Theme.onAccent)
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

                    // Pairing required banner
                    if chatService.wsConnectionState == .pairingRequired {
                        VStack(spacing: 12) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.accent)

                            Text("Device Pairing Required")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)

                            Text("On your server, run:")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)

                            Text("openclaw devices approve")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Theme.border, lineWidth: 1)
                                )

                            Button {
                                chatService.retryConnection()
                            } label: {
                                Text("Retry")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.onAccent)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 10)
                                    .background(Theme.accent, in: Capsule())
                            }
                            .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.background)
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
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .background(Theme.background)
        .sheet(isPresented: $showSettings) {
            SettingsView(chatService: chatService, roomService: roomService) {
                ensureRoomServiceConnected()
                showLobby = true
            }
        }
        .sheet(isPresented: $showRoomSettings) {
            if let room = selectedRoom {
                RoomSettingsView(roomService: roomService, chatService: chatService, room: room, onLeave: {
                    selectedRoom = nil
                    showRoomSettings = false
                })
            }
        }
        .sheet(isPresented: $showLobby) {
            RoomChatView(
                roomService: roomService,
                chatService: chatService,
                room: Self.lobbyRoom,
                isModal: true,
                onDismiss: { showLobby = false },
                displayNameOverride: "The Lounge"
            )
            .background(Theme.background)
            .preferredColorScheme(Theme.colorScheme)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .onChange(of: selectedPhotos) { _, items in
            Task { await loadSelectedPhotos(items) }
            selectedPhotos = []
        }
        .platformFullScreen(isPresented: $showVoiceSession) {
            VoiceSessionView(
                voiceService: voiceService,
                onDismiss: { endVoiceSession() }
            )
            .background(Theme.background)
            .preferredColorScheme(Theme.colorScheme)
        }
        .alert("Enable Notifications?", isPresented: $showNotificationPrompt) {
            Button("Enable") {
                Task {
                    await NotificationService.shared.requestPermission()
                    NotificationService.shared.notificationsEnabled = true
                }
                NotificationService.shared.hasPromptedForNotifications = true
            }
            Button("Not Now", role: .cancel) {
                NotificationService.shared.hasPromptedForNotifications = true
            }
        } message: {
            Text("Get notified when agents respond to you.")
        }
        .onChange(of: chatService.messages.count) {
            // Prompt after the first assistant response if not yet prompted
            if !NotificationService.shared.hasPromptedForNotifications,
               chatService.messages.contains(where: { $0.role == .user }),
               chatService.messages.contains(where: { $0.role == .assistant && !$0.isStreaming }) {
                showNotificationPrompt = true
            }
        }
        .onChange(of: selectedRoom?.id) { _, newRoomId in
            if newRoomId != nil {
                ensureRoomServiceConnected()
            }
        }
        .onAppear {
            speechRecognizer.requestAuthorization()
            if chatService.hasServer {
                chatService.connectWebSocket()
            }
            if roomService.hasBackend {
                roomService.connect()
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
        .preferredColorScheme(Theme.colorScheme)
    }

    // MARK: - Lobby

    private static let lobbyRoom = Room(
        id: "lobby",
        name: "The Lounge",
        emoji: nil,
        isPublic: true
    )

    /// Rooms the user has explicitly joined (not counting lobby)
    private var joinedRooms: [Room] {
        roomService.rooms.filter { $0.id != Self.lobbyRoom.id }
    }

    /// Rooms to show in the picker: user's rooms + lobby (always without emoji)
    private var pickerRooms: [Room] {
        var result = roomService.rooms.map { room in
            if room.id == Self.lobbyRoom.id {
                return Room(id: room.id, name: room.name, emoji: nil, isPublic: room.isPublic)
            }
            return room
        }
        if !result.contains(where: { $0.id == Self.lobbyRoom.id }) {
            result.append(Self.lobbyRoom)
        }
        return result
    }

    /// Whether to show the full pill-row picker (multiple agents or any joined rooms)
    private var needsPickerRow: Bool {
        chatService.visibleAgents.count > 1 || !joinedRooms.isEmpty
    }

    // MARK: - Picker Section

    @ViewBuilder
    private var pickerSection: some View {
        if needsPickerRow {
            ScrollView(.horizontal, showsIndicators: false) {
                AgentPicker(
                    selected: Binding(
                        get: { chatService.selectedAgent },
                        set: { chatService.selectedAgent = $0 }
                    ),
                    agents: chatService.visibleAgents,
                    unreadAgentIds: chatService.unreadAgentIds,
                    rooms: pickerRooms,
                    selectedRoom: $selectedRoom
                )
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Color.white.opacity(0.03).frame(height: 1)
            }
        }
    }

    // MARK: - Top Bar Buttons

    private var lobbyButton: some View {
        Button {
            ensureRoomServiceConnected()
            showLobby = true
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .padding(6)
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 18))
                .foregroundStyle(Theme.textSecondary)
                .padding(6)
                .platformHoverEffect()
        }
        .keyboardShortcut(",", modifiers: .command)
    }

    // MARK: - Computed Properties

    private var hasStreamingMessage: Bool {
        chatService.messages.contains { $0.isStreaming }
    }

    private var streamingContent: String {
        chatService.messages.last(where: { $0.isStreaming })?.content ?? ""
    }

    private var currentAgentName: String {
        // Match by composite id first, then fall back to raw agentId
        if let agent = chatService.agents.first(where: { $0.id == chatService.selectedAgent })
            ?? chatService.agents.first(where: { $0.agentId == chatService.selectedAgent }) {
            return agent.name
        }
        return chatService.selectedAgent.isEmpty ? "Claudio" : chatService.selectedAgent
    }

    private var connectionStatusColor: Color {
        if chatService.isHTTPMode { return Theme.green }
        switch chatService.wsConnectionState {
        case .connected: return Theme.green
        case .connecting: return Theme.accent
        case .error, .pairingRequired: return Theme.danger
        case .disconnected: return Theme.textSecondary
        }
    }

    private var connectionStatusText: String {
        if chatService.isHTTPMode { return "online" }
        switch chatService.wsConnectionState {
        case .connected: return "online"
        case .connecting: return "connecting"
        case .error: return "error"
        case .pairingRequired: return "pairing needed"
        case .disconnected: return "offline"
        }
    }

    private func serverDisplayName(for url: String) -> String {
        var name = url
        for prefix in ["https://", "http://"] {
            if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        }
        return name
    }

    // MARK: - Actions

    private static let productionBackendURL = "claudio-server-production.up.railway.app"

    private func ensureRoomServiceConnected() {
        guard !roomService.isConnected else { return }
        if !roomService.hasBackend {
            roomService.backendURL = Self.productionBackendURL
        }
        roomService.connect()
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
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.7)
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: newSize))
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        #endif
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
