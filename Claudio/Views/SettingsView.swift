import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let chatService: ChatService

    @State private var isFetching = false
    @State private var editingIndex: Int?
    @State private var editURL = ""
    @State private var editToken = ""

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
                        TextField("https://your-server.ngrok.io", text: $url)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                            .tint(Theme.accent)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .listRowBackground(Theme.surface)

                    VStack(alignment: .leading, spacing: Theme.spacing) {
                        Text("Token")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                        SecureField("Bearer token", text: $token)
                            .font(Theme.body)
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
