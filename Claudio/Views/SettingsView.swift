import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let chatService: ChatService

    @State private var isFetching = false
    @State private var editingIndex: Int?
    @State private var editURL = ""
    @State private var editToken = ""
    @State private var dangerousSkipPermissions = UserDefaults.standard.bool(forKey: "dangerouslySkipPermissions")
    @State private var dangerousTogglePending = false
    @State private var showDangerousConfirm = false
    @State private var dangerousExpanded = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Servers
                Section {
                    ForEach(Array(chatService.savedServers.enumerated()), id: \.offset) { index, server in
                        let isActive = index == chatService.activeServerIndex

                        Button {
                            if !isActive {
                                chatService.switchServer(to: index)
                            }
                        } label: {
                            HStack(spacing: Theme.spacing * 1.5) {
                                Circle()
                                    .fill(isActive ? Color.green : Theme.textSecondary.opacity(0.3))
                                    .frame(width: 7, height: 7)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayName(for: server.url))
                                        .font(Theme.body)
                                        .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                                        .lineLimit(1)

                                    Text(server.token.isEmpty ? "No token" : "Bearer ••••\(String(server.token.suffix(4)))")
                                        .font(Theme.caption)
                                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                                }

                                Spacer()

                                if isActive && isFetching {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .tint(Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(isActive ? Theme.accent.opacity(0.08) : Theme.surface)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !isActive {
                                Button(role: .destructive) {
                                    chatService.removeServer(at: index)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            Button {
                                editingIndex = index
                                editURL = server.url
                                editToken = server.token
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(Theme.accent)
                        }
                    }
                } header: {
                    HStack {
                        Text("Servers")
                        Spacer()
                        Button {
                            editingIndex = -1  // -1 = adding new
                            editURL = ""
                            editToken = ""
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                } footer: {
                    if chatService.savedServers.count > 1 {
                        Text("Swipe to edit or remove.")
                            .font(Theme.caption)
                    }
                }

                // MARK: - Agents
                if !chatService.agents.isEmpty {
                    Section {
                        ForEach(chatService.agents) { agent in
                            Button {
                                chatService.selectedAgent = agent.id
                            } label: {
                                HStack(spacing: Theme.spacing) {
                                    if let emoji = agent.emoji {
                                        Text(emoji)
                                    }
                                    Text(agent.name)
                                        .font(Theme.body)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    if chatService.selectedAgent == agent.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .listRowBackground(Theme.surface)
                        }
                    } header: {
                        Text("Agents")
                    }
                }

                if chatService.agentFetchFailed {
                    Section {
                        VStack(alignment: .leading, spacing: Theme.spacing) {
                            Text("Agent Name")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textSecondary)
                            TextField("e.g. mave", text: Binding(
                                get: { chatService.selectedAgent },
                                set: { chatService.selectedAgent = $0 }
                            ))
                            .font(Theme.body)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        }
                        .listRowBackground(Theme.surface)
                    } header: {
                        Text("Agent")
                    } footer: {
                        Text(chatService.connectionError ?? "Couldn't reach server.")
                            .font(Theme.caption)
                    }
                }

                // MARK: - Clear
                if !chatService.messages.isEmpty {
                    Section {
                        Button("Clear Conversation") {
                            chatService.clearMessages()
                            dismiss()
                        }
                        .foregroundStyle(.red)
                        .listRowBackground(Theme.surface)
                    }
                }

                // MARK: - Advanced
                Section {
                    DisclosureGroup(isExpanded: $dangerousExpanded) {
                        VStack(alignment: .leading, spacing: Theme.spacing) {
                            Toggle(isOn: dangerousSkipPermissions ? .constant(true) : $dangerousTogglePending) {
                                Text("--dangerously-skip-permissions")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(dangerousSkipPermissions ? .red.opacity(0.5) : .red.opacity(0.7))
                            }
                            .tint(.red.opacity(0.5))
                            .disabled(dangerousSkipPermissions)
                            .onChange(of: dangerousTogglePending) { _, newValue in
                                if newValue { showDangerousConfirm = true }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(dangerousSkipPermissions
                                     ? "permissions skipped."
                                     : "skips all permission prompts.")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.35))
                                Text(dangerousSkipPermissions
                                     ? "reinstall to undo."
                                     : "claudio will not ask. claudio will act.")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.35))
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("For advanced users only")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary.opacity(0.3))
                    }
                    .tint(.red.opacity(0.4))
                    .listRowBackground(Theme.surface)
                } header: {
                    HStack(spacing: Theme.spacing) {
                        Rectangle()
                            .fill(Theme.textSecondary.opacity(0.1))
                            .frame(height: 0.5)
                        Text("ADVANCED")
                            .font(.system(.caption2, design: .rounded, weight: .medium))
                            .foregroundStyle(.red.opacity(0.5))
                            .kerning(3)
                        Rectangle()
                            .fill(Theme.textSecondary.opacity(0.1))
                            .frame(height: 0.5)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .sheet(item: $editingIndex) { index in
                ServerEditSheet(
                    isNew: index == -1,
                    url: $editURL,
                    token: $editToken,
                    isFetching: $isFetching,
                    onSave: {
                        if index == -1 {
                            chatService.addServer(url: editURL, token: editToken)
                        } else {
                            chatService.updateServer(at: index, url: editURL, token: editToken)
                        }
                        isFetching = true
                        Task {
                            await chatService.fetchAgents()
                            isFetching = false
                        }
                        editingIndex = nil
                    },
                    onCancel: { editingIndex = nil }
                )
            }
        }
        .onAppear {
            if chatService.hasServer && chatService.agents.isEmpty {
                isFetching = true
                Task {
                    await chatService.fetchAgents()
                    isFetching = false
                }
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
            Text("This will skip all permission prompts. Only do this if you know what you're doing.")
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

// Make Int work with .sheet(item:)
extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

// MARK: - Server Edit Sheet

private struct ServerEditSheet: View {
    let isNew: Bool
    @Binding var url: String
    @Binding var token: String
    @Binding var isFetching: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Theme.spacing) {
                        Text("Server URL")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                        ZStack(alignment: .leading) {
                            if url.isEmpty {
                                Text("your-server.example.com")
                                    .font(Theme.body)
                                    .foregroundStyle(Theme.textSecondary.opacity(0.4))
                            }
                            TextField("", text: $url)
                                .font(Theme.body)
                                .foregroundStyle(Theme.textPrimary)
                                .tint(Theme.accent)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                    .listRowBackground(Theme.surface)

                    VStack(alignment: .leading, spacing: Theme.spacing) {
                        Text("Token")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                        SecureField("Bearer token", text: $token)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                            .tint(Theme.accent)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .listRowBackground(Theme.surface)
                } footer: {
                    Text("Your server token authenticates all requests.")
                        .font(Theme.caption)
                }
            }
            .scrollContentBackground(.hidden)
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
