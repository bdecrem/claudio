import SwiftUI

struct MentionOverlay: View {
    let participants: [RoomParticipant]
    let filter: String
    let onSelect: (RoomParticipant) -> Void
    let onDismiss: () -> Void

    private var filtered: [RoomParticipant] {
        if filter.isEmpty { return participants }
        return participants.filter {
            $0.displayName.lowercased().hasPrefix(filter)
        }
    }

    var body: some View {
        VStack {
            Spacer()

            if !filtered.isEmpty {
                VStack(spacing: 0) {
                    ForEach(filtered) { participant in
                        Button {
                            onSelect(participant)
                        } label: {
                            HStack(spacing: 10) {
                                Text(participant.emoji ?? (participant.isAgent ? "🤖" : "👤"))
                                    .font(.system(size: 18))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(participant.displayName)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    if participant.isAgent {
                                        Text("agent")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if participant.id != filtered.last?.id {
                            Divider().background(Theme.border).padding(.leading, 48)
                        }
                    }
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 10, y: -2)
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 70) // Above input bar
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
    }
}
