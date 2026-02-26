import SwiftUI

struct AgentPicker: View {
    @Binding var selected: String
    let agents: [ChatService.Agent]
    var unreadAgentIds: Set<String> = []

    var body: some View {
        if agents.isEmpty {
            if !selected.isEmpty {
                Text(selected)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, Theme.spacing * 1.5)
                    .padding(.vertical, Theme.spacing * 0.75)
                    .background(Theme.accentDim, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1))
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(agents) { agent in
                        let isSelected = selected == agent.id

                        Button {
                            HapticsManager.selection()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selected = agent.id
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(isSelected ? Theme.accent : Theme.textSecondary)
                                    .frame(width: 5, height: 5)
                                    .opacity(0.7)

                                Text(agent.name)
                                    .font(.system(.caption2, design: .monospaced))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                            .background(isSelected ? Theme.accentDim : Color.clear)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        isSelected ? Theme.accent : Theme.border,
                                        lineWidth: 1
                                    )
                            )
                            .overlay(alignment: .topTrailing) {
                                if !isSelected && unreadAgentIds.contains(agent.id) {
                                    Circle()
                                        .fill(Theme.accent)
                                        .frame(width: 6, height: 6)
                                        .offset(x: -2, y: -1)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
