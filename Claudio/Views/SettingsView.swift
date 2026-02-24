import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let chatService: ChatService

    @State private var isFetching = false
    @State private var isAddingServer = false
    @State private var newServerURL = ""

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Servers
                Section {
                    ForEach(Array(chatService.savedServers.enumerated()), id: \.offset) { index, server in
                        let isActive = server == chatService.serverAddress

                        Button {
                            if !isActive {
                                isFetching = true
                                chatService.switchServer(to: server)
                                Task {
                                    await chatService.fetchAgents()
                                    isFetching = false
                                }
                            }
                        } label: {
                            HStack(spacing: Theme.spacing * 1.5) {
                                // Connection dot
                                Circle()
                                    .fill(isActive ? Color.green : Theme.textSecondary.opacity(0.3))
                                    .frame(width: 7, height: 7)

                                Text(displayName(for: server))
                                    .font(Theme.body)
                                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                                    .lineLimit(1)

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
                        }
                    }

                    // Add server — inline
                    if isAddingServer {
                        HStack(spacing: Theme.spacing) {
                            TextField("https://...", text: $newServerURL)
                                .font(Theme.body)
                                .textContentType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .onSubmit { commitNewServer() }

                            Button {
                                commitNewServer()
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(
                                        newServerURL.trimmingCharacters(in: .whitespaces).isEmpty
                                            ? Theme.textSecondary.opacity(0.3)
                                            : Theme.accent
                                    )
                            }
                            .disabled(newServerURL.trimmingCharacters(in: .whitespaces).isEmpty)

                            Button {
                                isAddingServer = false
                                newServerURL = ""
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                } header: {
                    HStack {
                        Text("Server")
                        Spacer()
                        if !isAddingServer {
                            Button {
                                isAddingServer = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                } footer: {
                    if chatService.savedServers.count > 1 {
                        Text("Swipe to remove inactive servers.")
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
                                HStack {
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
                        Text("Couldn't reach server. Enter a name manually.")
                            .font(Theme.caption)
                    }
                }

                // MARK: - Danger zone
                Section {
                    Button("Clear Conversation") {
                        chatService.clearMessages()
                        dismiss()
                    }
                    .foregroundStyle(.red)
                    .listRowBackground(Theme.surface)
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
        }
        .onAppear {
            if chatService.agents.isEmpty {
                isFetching = true
                Task {
                    await chatService.fetchAgents()
                    isFetching = false
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func commitNewServer() {
        chatService.addServer(newServerURL)
        newServerURL = ""
        isAddingServer = false
    }

    /// Strip protocol for display — show the hostname
    private func displayName(for url: String) -> String {
        var name = url
        for prefix in ["https://", "http://"] {
            if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        }
        return name
    }
}
