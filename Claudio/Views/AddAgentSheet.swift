import SwiftUI

struct AddAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let roomService: RoomService
    let roomId: String

    @State private var serverURL = ""
    @State private var serverToken = ""
    @State private var agentId = ""
    @State private var agentName = ""
    @State private var agentEmoji = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    // Fetch agents from the OpenClaw server
    @State private var availableAgents: [WSAgent] = []
    @State private var isFetchingAgents = false
    @State private var selectedAgent: WSAgent?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Server connection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OpenClaw Server")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)

                        VStack(spacing: 0) {
                            TextField("", text: $serverURL, prompt:
                                Text("server.example.com")
                                    .foregroundStyle(Theme.textDim)
                            )
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textPrimary)
                            .tint(Theme.accent)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(14)

                            Divider().background(Theme.border)

                            SecureField("Bearer token", text: $serverToken)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                                .tint(Theme.accent)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(14)
                        }
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button {
                            fetchAgents()
                        } label: {
                            HStack {
                                Text("Fetch Agents")
                                    .font(.system(size: 14, weight: .medium))
                                if isFetchingAgents {
                                    ProgressView().scaleEffect(0.7).tint(Theme.accent)
                                }
                            }
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(serverURL.isEmpty || isFetchingAgents)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)

                    // Agent list
                    if !availableAgents.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Select Agent")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 4)

                            VStack(spacing: 0) {
                                ForEach(availableAgents, id: \.id) { agent in
                                    if agent.id != availableAgents.first?.id {
                                        Divider().background(Theme.border).padding(.leading, 48)
                                    }
                                    Button {
                                        selectedAgent = agent
                                        agentId = agent.id
                                        agentName = agent.name
                                        agentEmoji = agent.emoji ?? ""
                                    } label: {
                                        HStack(spacing: 12) {
                                            Text(agent.emoji ?? "🤖")
                                                .font(.system(size: 20))
                                            Text(agent.name)
                                                .font(.system(size: 15))
                                                .foregroundStyle(Theme.textPrimary)
                                            Spacer()
                                            if selectedAgent?.id == agent.id {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 15))
                                                    .foregroundStyle(Theme.accent)
                                            }
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .padding(.horizontal, 16)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.danger)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 16)
            }
            .background(Theme.background)
            .navigationTitle("Add Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        addAgent()
                    }
                    .foregroundStyle(Theme.accent)
                    .disabled(agentId.isEmpty || serverURL.isEmpty || isAdding)
                }
            }
            .foregroundStyle(Theme.textPrimary)
        }
        .preferredColorScheme(.dark)
    }

    private func fetchAgents() {
        isFetchingAgents = true
        errorMessage = nil
        Task {
            let client = WebSocketClient()
            await client.setCallbacks(
                onStateChange: { _ in },
                onChatEvent: { _ in },
                onAgentEvent: { _ in }
            )

            // Quick connect + fetch
            var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.hasPrefix("http") && !url.hasPrefix("ws") {
                url = "https://" + url
            }

            await client.connect(serverURL: url, token: serverToken)

            // Wait for connection
            try? await Task.sleep(for: .seconds(3))

            do {
                let agents = try await client.agentsList()
                await MainActor.run {
                    availableAgents = agents
                    if agents.isEmpty {
                        errorMessage = "No agents found on this server."
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to connect: \(error.localizedDescription)"
                }
            }
            await client.disconnect()
            await MainActor.run { isFetchingAgents = false }
        }
    }

    private func addAgent() {
        isAdding = true
        errorMessage = nil
        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasPrefix("http") && !url.hasPrefix("ws") {
            url = "https://" + url
        }
        Task {
            let success = await roomService.addAgent(
                roomId: roomId,
                openclawUrl: url,
                openclawToken: serverToken,
                agentId: agentId,
                agentName: agentName,
                agentEmoji: agentEmoji
            )
            if success {
                dismiss()
            } else {
                errorMessage = "Failed to add agent."
            }
            isAdding = false
        }
    }
}
