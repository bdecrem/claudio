import SwiftUI

struct AddAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let roomService: RoomService
    let chatService: ChatService
    let roomId: String

    @State private var selectedAgentIds: Set<String> = []
    @State private var isAdding = false
    @State private var errorMessage: String?

    // Agents already in the room (to exclude from the list)
    var existingAgentIds: Set<String>

    private var availableAgents: [ChatService.Agent] {
        chatService.agents.filter { !existingAgentIds.contains($0.name) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if availableAgents.isEmpty {
                        Text("No agents available. Connect a server in Settings first.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(32)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Select Agents")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 4)

                            VStack(spacing: 0) {
                                ForEach(Array(availableAgents.enumerated()), id: \.element.id) { index, agent in
                                    if index > 0 {
                                        Divider().background(Theme.border).padding(.leading, 48)
                                    }
                                    Button {
                                        if selectedAgentIds.contains(agent.id) {
                                            selectedAgentIds.remove(agent.id)
                                        } else {
                                            selectedAgentIds.insert(agent.id)
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Text(agent.emoji ?? "🤖")
                                                .font(.system(size: 20))
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(agent.name)
                                                    .font(.system(size: 15))
                                                    .foregroundStyle(Theme.textPrimary)
                                                Text(serverName(for: agent))
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(Theme.textDim)
                                            }
                                            Spacer()
                                            Image(systemName: selectedAgentIds.contains(agent.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 20))
                                                .foregroundStyle(selectedAgentIds.contains(agent.id) ? Theme.accent : Theme.textDim)
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
            .navigationTitle("Add Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        addSelectedAgents()
                    }
                    .foregroundStyle(Theme.accent)
                    .disabled(selectedAgentIds.isEmpty || isAdding)
                }
            }
            .foregroundStyle(Theme.textPrimary)
        }
        .preferredColorScheme(.dark)
    }

    private func serverName(for agent: ChatService.Agent) -> String {
        let idx = agent.serverIndex
        guard idx < chatService.savedServers.count else { return "" }
        var name = chatService.savedServers[idx].url
        for prefix in ["wss://", "ws://", "https://", "http://"] {
            if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        }
        return name
    }

    private func addSelectedAgents() {
        isAdding = true
        errorMessage = nil
        Task {
            var failed = 0
            for agentId in selectedAgentIds {
                guard let agent = availableAgents.first(where: { $0.id == agentId }) else { continue }
                let serverIdx = agent.serverIndex
                guard serverIdx < chatService.savedServers.count else { continue }

                let server = chatService.savedServers[serverIdx]
                let success = await roomService.addAgent(
                    roomId: roomId,
                    openclawUrl: server.url,
                    openclawToken: server.token,
                    agentId: agent.agentId,
                    agentName: agent.name,
                    agentEmoji: agent.emoji ?? ""
                )
                if !success { failed += 1 }
            }
            if failed > 0 {
                errorMessage = "Failed to add \(failed) agent(s)."
            } else {
                dismiss()
            }
            isAdding = false
        }
    }
}
