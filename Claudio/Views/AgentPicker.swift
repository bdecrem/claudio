import SwiftUI

struct AgentPicker: View {
    @Binding var selected: String
    let agents: [ChatService.Agent]

    var body: some View {
        if agents.isEmpty {
            // Show the raw agent name if set manually
            if !selected.isEmpty {
                Text(selected)
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, Theme.spacing * 2)
                    .padding(.vertical, Theme.spacing * 0.75)
                    .background(Theme.surface, in: Capsule())
            }
        } else {
            HStack(spacing: 0) {
                ForEach(agents) { agent in
                    Button {
                        HapticsManager.selection()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selected = agent.id
                        }
                    } label: {
                        Text(agent.name)
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(selected == agent.id ? Theme.background : Theme.textSecondary)
                            .padding(.horizontal, Theme.spacing * 2)
                            .padding(.vertical, Theme.spacing * 0.75)
                            .background {
                                if selected == agent.id {
                                    Capsule()
                                        .fill(Theme.accent)
                                }
                            }
                    }
                }
            }
            .padding(3)
            .background(Theme.surface, in: Capsule())
        }
    }
}
