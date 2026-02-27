import SwiftUI

struct RoomChatView: View {
    let roomService: RoomService
    let chatService: ChatService
    let room: Room

    @State private var messageText = ""
    @State private var showSettings = false
    @State private var showMentions = false
    @State private var mentionFilter = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                roomHeader

                // Messages
                ZStack {
                    messageList

                    // Fade edges
                    VStack {
                        LinearGradient(
                            colors: [Theme.background, Theme.background.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 20)
                        .allowsHitTesting(false)
                        Spacer()
                        LinearGradient(
                            colors: [Theme.background.opacity(0), Theme.background],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 20)
                        .allowsHitTesting(false)
                    }
                }

                // Typing indicator
                if let typing = roomService.typingIndicator {
                    HStack {
                        Text(typing)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .italic()
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .transition(.opacity)
                }

                // Input
                roomInputBar
            }

            // Mention overlay
            if showMentions {
                MentionOverlay(
                    participants: room.participants,
                    filter: mentionFilter,
                    onSelect: { participant in
                        insertMention(participant)
                    },
                    onDismiss: {
                        showMentions = false
                    }
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            RoomSettingsView(roomService: roomService, chatService: chatService, room: room, onLeave: {})
        }
        .task {
            await roomService.enterRoom(room)
        }
        .onDisappear {
            roomService.exitRoom()
        }
    }

    // MARK: - Header

    private var roomHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                    .frame(width: 32)

                Spacer()

                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        if let emoji = room.emoji {
                            Text(emoji)
                                .font(.system(size: 16))
                        }
                        Text(room.name)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text("\(room.participants.count) participants")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Button { showSettings = true } label: {
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
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if roomService.activeRoomMessages.isEmpty {
                    VStack(spacing: Theme.spacing * 2) {
                        Spacer(minLength: 100)
                        Text(room.emoji ?? "💬")
                            .font(.system(size: 48))
                        Text("no messages yet")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(roomService.activeRoomMessages) { message in
                            RoomMessageBubble(
                                message: message,
                                myUserId: roomService.myUserId
                            )
                            .id(message.id)
                            .padding(.bottom, 8)
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
            .contentMargins(.top, 60, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: roomService.activeRoomMessages.count) {
                if let last = roomService.activeRoomMessages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input

    private var roomInputBar: some View {
        HStack(spacing: Theme.spacing) {
            HStack(spacing: Theme.spacing) {
                TextField("", text: $messageText, prompt:
                    Text("message…")
                        .font(.system(size: 15, weight: .light, design: .serif).italic())
                        .foregroundStyle(Theme.textDim)
                )
                .font(.system(size: 15, weight: .light, design: .serif))
                .foregroundStyle(Theme.textPrimary)
                .focused($inputFocused)
                .tint(Theme.accent)
                .submitLabel(.return)
                .onSubmit { sendMessage() }
                .onChange(of: messageText) { _, newValue in
                    detectMention(newValue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        inputFocused ? Theme.accent.opacity(0.25) : Theme.border,
                        lineWidth: 1
                    )
            )

            Button { sendMessage() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent, in: Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.background)
        .overlay(alignment: .top) {
            Theme.border.frame(height: 1)
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let mentions = extractMentionIds(from: text)
        messageText = ""
        Task {
            await roomService.sendMessage(content: text, mentions: mentions)
        }
    }

    private func detectMention(_ text: String) {
        // Find the last @ that starts a word
        guard let atIndex = text.lastIndex(of: "@") else {
            showMentions = false
            return
        }
        let afterAt = text[text.index(after: atIndex)...]
        // If there's a space after the @, dismiss
        if afterAt.contains(" ") {
            showMentions = false
            return
        }
        mentionFilter = String(afterAt).lowercased()
        showMentions = true
    }

    private func insertMention(_ participant: RoomParticipant) {
        // Replace the current @partial with @Name
        if let atIndex = messageText.lastIndex(of: "@") {
            messageText = String(messageText[..<atIndex]) + "@\(participant.displayName) "
        }
        showMentions = false
    }

    private func extractMentionIds(from text: String) -> [String] {
        var ids: [String] = []
        let lower = text.lowercased()
        for participant in room.participants {
            if lower.contains("@\(participant.displayName.lowercased())") {
                ids.append(participant.id)
            }
        }
        return ids
    }
}
