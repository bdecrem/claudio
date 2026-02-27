import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let chatService: ChatService
    var roomService: RoomService?

    @State private var editingIndex: Int?
    @State private var editURL = ""
    @State private var editToken = ""
    @State private var dangerousSkipPermissions = UserDefaults.standard.bool(forKey: "dangerouslySkipPermissions")
    @State private var dangerousTogglePending = false
    @State private var showDangerousConfirm = false
    @State private var dangerousExpanded = false

    private let cardRadius: CGFloat = 14

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {

                    // MARK: - Servers
                    SettingsSection(title: "Servers") {
                        Button {
                            editingIndex = -1
                            editURL = ""
                            editToken = ""
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } content: {
                        VStack(spacing: 0) {
                            ForEach(Array(chatService.savedServers.enumerated()), id: \.offset) { index, server in
                                let isActive = index == chatService.activeServerIndex

                                if index > 0 {
                                    Divider()
                                        .background(Theme.border)
                                        .padding(.leading, 16)
                                }

                                Button {
                                    if !isActive {
                                        chatService.switchServer(to: index)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Circle()
                                            .fill(isActive ? Theme.green : Theme.textSecondary.opacity(0.3))
                                            .frame(width: 8, height: 8)
                                            .shadow(color: isActive ? Theme.green.opacity(0.5) : .clear, radius: 3)

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(displayName(for: server.url))
                                                .font(.system(size: 15))
                                                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                                                .lineLimit(1)

                                            Text(server.token.isEmpty ? "No token" : "Bearer ••••\(String(server.token.suffix(4)))")
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(Theme.textSecondary)
                                        }

                                        Spacer()

                                        if isActive {
                                            ConnectionDot(state: chatService.wsConnectionState)
                                        }
                                    }
                                    .padding(14)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        editingIndex = index
                                        editURL = server.url
                                        editToken = server.token
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    if !isActive {
                                        Button(role: .destructive) {
                                            chatService.removeServer(at: index)
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                    }

                    // MARK: - Agents
                    if !chatService.agents.isEmpty {
                        SettingsSection(title: "Agents") {
                            VStack(spacing: 0) {
                                ForEach(Array(chatService.agents.enumerated()), id: \.element.id) { index, agent in
                                    if index > 0 {
                                        Divider()
                                            .background(Theme.border)
                                            .padding(.leading, 16)
                                    }

                                    let isHidden = chatService.hiddenAgentIds.contains(agent.id)

                                    Button {
                                        chatService.selectedAgent = agent.id
                                    } label: {
                                        HStack(spacing: 12) {
                                            if let emoji = agent.emoji {
                                                Text(emoji)
                                                    .font(.system(size: 20))
                                            }
                                            Text(agent.name)
                                                .font(.system(size: 15))
                                                .foregroundStyle(Theme.textPrimary)

                                            Spacer()

                                            Button {
                                                chatService.toggleAgentVisibility(agent.id)
                                            } label: {
                                                Image(systemName: isHidden ? "eye.slash" : "eye")
                                                    .font(.system(size: 15))
                                                    .foregroundStyle(isHidden ? Theme.textDim : Theme.textSecondary)
                                                    .frame(width: 32, height: 32)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)

                                            if chatService.selectedAgent == agent.id {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 17))
                                                    .foregroundStyle(Theme.accent)
                                            }
                                        }
                                        .padding(14)
                                        .contentShape(Rectangle())
                                        .opacity(isHidden ? 0.4 : 1.0)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                        }
                    }

                    // MARK: - Notifications
                    NotificationSettingsSection(cardRadius: cardRadius)

                    // MARK: - Claudio Backend (Rooms)
                    if let roomService {
                        ClaudioBackendSection(roomService: roomService, cardRadius: cardRadius)
                    }

                    if chatService.agentFetchFailed {
                        SettingsSection(title: "Agent") {
                            VStack(alignment: .leading, spacing: Theme.spacing) {
                                Text("Agent Name")
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                TextField("e.g. mave", text: Binding(
                                    get: { chatService.selectedAgent },
                                    set: { chatService.selectedAgent = $0 }
                                ))
                                .font(Theme.body)
                                .foregroundStyle(Theme.textPrimary)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            }
                            .padding(14)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))

                            Text(chatService.connectionError ?? "Couldn't reach server.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 4)
                                .padding(.top, 4)
                        }
                    }

                    // MARK: - Clear
                    if !chatService.messages.isEmpty {
                        VStack(spacing: 0) {
                            Button {
                                chatService.clearMessages()
                                dismiss()
                            } label: {
                                HStack {
                                    Text("Clear Conversation")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Theme.danger.opacity(0.7))
                                    Spacer()
                                }
                                .padding(14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                        .padding(.horizontal, 16)
                    }

                    // MARK: - Advanced
                    VStack(spacing: 10) {
                        // Divider
                        HStack(spacing: 10) {
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [.clear, Theme.danger.opacity(0.08), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(height: 1)
                            Text("ADVANCED")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.danger.opacity(0.4))
                                .kerning(2)
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [.clear, Theme.danger.opacity(0.08), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(height: 1)
                        }
                        .padding(.horizontal, 4)

                        // Card
                        VStack(spacing: 0) {
                            // Header row
                            Button {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    dangerousExpanded.toggle()
                                }
                            } label: {
                                HStack {
                                    Text("For advanced users only")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.textDim.opacity(0.8))
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 13))
                                        .foregroundStyle(dangerousExpanded ? Theme.danger.opacity(0.5) : Theme.textDim)
                                        .rotationEffect(.degrees(dangerousExpanded ? 0 : -90))
                                }
                                .padding(14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            // Expanded content
                            if dangerousExpanded {
                                Divider()
                                    .background(Color.white.opacity(0.04))

                                VStack(alignment: .leading, spacing: Theme.spacing) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("--dangerously-skip-permissions")
                                                .font(.system(size: 13, design: .monospaced))
                                                .foregroundStyle(dangerousSkipPermissions ? Theme.danger.opacity(0.5) : Theme.danger.opacity(0.85))

                                            VStack(alignment: .leading, spacing: 2) {
                                                if dangerousSkipPermissions {
                                                    Text("⚠ active — no guardrails. no confirmations.")
                                                        .font(.system(size: 10, design: .monospaced))
                                                        .foregroundStyle(Theme.danger.opacity(0.45))
                                                    Text("you have been warned.")
                                                        .font(.system(size: 10, design: .monospaced))
                                                        .foregroundStyle(Theme.danger.opacity(0.45))
                                                } else {
                                                    Text("skips all permission prompts.")
                                                        .font(.system(size: 11, design: .monospaced))
                                                        .foregroundStyle(Theme.textDim)
                                                    Text("claudio will not ask. claudio will act.")
                                                        .font(.system(size: 11, design: .monospaced))
                                                        .foregroundStyle(Theme.textDim)
                                                }
                                            }
                                        }

                                        Spacer()

                                        Toggle("", isOn: dangerousSkipPermissions ? .constant(true) : $dangerousTogglePending)
                                            .labelsHidden()
                                            .tint(Theme.danger)
                                            .disabled(dangerousSkipPermissions)
                                            .onChange(of: dangerousTogglePending) { _, newValue in
                                                if newValue { showDangerousConfirm = true }
                                            }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .background(
                            dangerousSkipPermissions
                                ? LinearGradient(
                                    colors: [Theme.surface, Theme.danger.opacity(0.04)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [Theme.surface, Theme.surface],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                                .strokeBorder(
                                    dangerousSkipPermissions ? Theme.danger.opacity(0.3) : .clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(Theme.background)
            .navigationBarHidden(true)
            .safeAreaInset(edge: .top) {
                HStack {
                    // Balance spacer for centering
                    Color.clear.frame(width: 56, height: 1)

                    Spacer()

                    Text("Settings")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    Spacer()

                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .background(Theme.background)
            }
            .sheet(item: $editingIndex) { index in
                ServerEditSheet(
                    isNew: index == -1,
                    url: $editURL,
                    token: $editToken,
                    onSave: {
                        if index == -1 {
                            chatService.addServer(url: editURL, token: editToken)
                        } else {
                            chatService.updateServer(at: index, url: editURL, token: editToken)
                        }
                        editingIndex = nil
                    },
                    onCancel: { editingIndex = nil }
                )
            }
        }
        .onAppear {
            if chatService.hasServer && !chatService.isConnected {
                chatService.connectWebSocket()
            }
        }
        .alert("Are you sure?", isPresented: $showDangerousConfirm) {
            Button("Enable", role: .destructive) {
                dangerousSkipPermissions = true
                UserDefaults.standard.set(true, forKey: "dangerouslySkipPermissions")
            }
            Button("Cancel", role: .cancel) {
                dangerousTogglePending = false
            }
        } message: {
            Text("May introduce unexpected behavior. Claudio will not ask. Claudio will act.")
        }
        .preferredColorScheme(.dark)
    }

    private func displayName(for url: String) -> String {
        var name = url
        for prefix in ["https://", "http://"] {
            if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        }
        return name
    }
}

// MARK: - Settings Section

private struct SettingsSection<Trailing: View, Content: View>: View {
    let title: String
    var trailing: Trailing? = nil
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, 4)

            content
        }
        .padding(.horizontal, 16)
    }
}

extension SettingsSection where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = nil
        self.content = content()
    }
}

// MARK: - Make Int work with .sheet(item:)
extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

// MARK: - Server Edit Sheet

private struct ServerEditSheet: View {
    let isNew: Bool
    @Binding var url: String
    @Binding var token: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: Theme.spacing) {
                        Text("Server URL")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        ZStack(alignment: .leading) {
                            if url.isEmpty {
                                Text("your-server.example.com")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.4))
                            }
                            TextField("", text: $url)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                                .tint(Theme.accent)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                    .padding(14)

                    Divider().background(Theme.border)

                    VStack(alignment: .leading, spacing: Theme.spacing) {
                        Text("Token")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        SecureField("Bearer token", text: $token)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textPrimary)
                            .tint(Theme.accent)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(14)
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Text("Your server token authenticates all requests.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            .background(Theme.background)
            .navigationTitle(isNew ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: onSave)
                        .foregroundStyle(Theme.accent)
                        .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .foregroundStyle(Theme.textPrimary)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Notification Settings

private struct NotificationSettingsSection: View {
    let cardRadius: CGFloat
    private var notificationService: NotificationService { .shared }

    var body: some View {
        SettingsSection(title: "Notifications") {
            VStack(spacing: 0) {
                // Master toggle
                HStack {
                    Text("Push Notifications")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { notificationService.notificationsEnabled },
                        set: { newValue in
                            if newValue {
                                Task {
                                    if notificationService.permissionState == .denied {
                                        openAppSettings()
                                    } else {
                                        await notificationService.requestPermission()
                                        if notificationService.permissionState == .authorized {
                                            notificationService.notificationsEnabled = true
                                        }
                                    }
                                }
                            } else {
                                notificationService.notificationsEnabled = false
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(Theme.accent)
                }
                .padding(14)

                if notificationService.notificationsEnabled {
                    Divider().background(Theme.border).padding(.leading, 16)

                    // Sub-toggles
                    notificationToggle("Agent Messages", isOn: Binding(
                        get: { notificationService.notifyAgentMessages },
                        set: { notificationService.notifyAgentMessages = $0 }
                    ))

                    Divider().background(Theme.border).padding(.leading, 16)

                    notificationToggle("Mentions", isOn: Binding(
                        get: { notificationService.notifyMentions },
                        set: { notificationService.notifyMentions = $0 }
                    ))

                    Divider().background(Theme.border).padding(.leading, 16)

                    notificationToggle("All Events", isOn: Binding(
                        get: { notificationService.notifyAllEvents },
                        set: { notificationService.notifyAllEvents = $0 }
                    ))
                }

                if notificationService.permissionState == .denied {
                    Divider().background(Theme.border).padding(.leading, 16)

                    Button { openAppSettings() } label: {
                        HStack {
                            Text("Notifications disabled in system settings")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        }
    }

    private func notificationToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Claudio Backend Section

private struct ClaudioBackendSection: View {
    let roomService: RoomService
    let cardRadius: CGFloat

    @State private var url: String = ""
    @State private var token: String = ""
    @State private var displayName: String = ""
    @State private var avatarEmoji: String = ""

    var body: some View {
        SettingsSection(title: "Claudio Backend") {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    Text("Server URL")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    ZStack(alignment: .leading) {
                        if url.isEmpty {
                            Text("claudio-server.example.com")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textSecondary.opacity(0.4))
                        }
                        TextField("", text: $url)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textPrimary)
                            .tint(Theme.accent)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: url) { _, newValue in
                                roomService.backendURL = newValue
                            }
                    }
                }
                .padding(14)

                Divider().background(Theme.border)

                VStack(alignment: .leading, spacing: Theme.spacing) {
                    Text("Token (optional)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    SecureField("Bearer token", text: $token)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: token) { _, newValue in
                            roomService.backendToken = newValue
                        }
                }
                .padding(14)

                Divider().background(Theme.border)

                VStack(alignment: .leading, spacing: Theme.spacing) {
                    Text("Display Name")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("", text: $displayName, prompt:
                        Text("Your name in rooms")
                            .foregroundStyle(Theme.textDim)
                    )
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
                    .autocorrectionDisabled()
                    .onChange(of: displayName) { _, newValue in
                        roomService.displayName = newValue
                    }
                }
                .padding(14)

                Divider().background(Theme.border)

                VStack(alignment: .leading, spacing: Theme.spacing) {
                    Text("Avatar Emoji")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("", text: $avatarEmoji, prompt:
                        Text("e.g. 😎")
                            .foregroundStyle(Theme.textDim)
                    )
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .onChange(of: avatarEmoji) { _, newValue in
                        roomService.avatarEmoji = newValue
                    }
                }
                .padding(14)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))

            if roomService.hasBackend {
                Button {
                    if roomService.isConnected {
                        Task { await roomService.updateProfile() }
                    } else {
                        roomService.connect()
                    }
                } label: {
                    Text(roomService.isConnected ? "Update Profile" : "Connect")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .onAppear {
            url = roomService.backendURL
            token = roomService.backendToken
            displayName = roomService.displayName
            avatarEmoji = roomService.avatarEmoji
        }
    }
}

// MARK: - Connection Status Dot

private struct ConnectionDot: View {
    let state: WebSocketClient.ConnectionState

    var body: some View {
        switch state {
        case .connected:
            Circle()
                .fill(Theme.green)
                .frame(width: 8, height: 8)
                .shadow(color: Theme.green.opacity(0.5), radius: 3)
        case .connecting:
            ProgressView()
                .scaleEffect(0.7)
                .tint(Theme.accent)
        case .pairingRequired:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
        case .error:
            Circle()
                .fill(Theme.danger)
                .frame(width: 8, height: 8)
        case .disconnected:
            Circle()
                .fill(Theme.textSecondary.opacity(0.3))
                .frame(width: 8, height: 8)
        }
    }
}
