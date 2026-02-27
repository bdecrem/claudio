import SwiftUI

struct RoomSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let roomService: RoomService
    let room: Room
    let onLeave: () -> Void

    @State private var inviteCode: String?
    @State private var isGeneratingCode = false
    @State private var showAddAgent = false
    @State private var showLeaveConfirm = false
    @State private var roomInfo: Room?

    private var displayRoom: Room { roomInfo ?? room }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // Room header
                    VStack(spacing: 8) {
                        Text(displayRoom.emoji ?? "💬")
                            .font(.system(size: 56))
                        Text(displayRoom.name)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.top, 16)

                    // Invite code
                    SettingsSectionView(title: "Invite") {
                        VStack(spacing: 12) {
                            if let code = inviteCode {
                                HStack {
                                    Text(code)
                                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Theme.accent)
                                        .kerning(2)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = code
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 15))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            } else {
                                Button {
                                    isGeneratingCode = true
                                    Task {
                                        inviteCode = await roomService.createInvite(roomId: displayRoom.id)
                                        isGeneratingCode = false
                                    }
                                } label: {
                                    HStack {
                                        Text("Generate Invite Code")
                                            .font(.system(size: 15))
                                            .foregroundStyle(Theme.accent)
                                        Spacer()
                                        if isGeneratingCode {
                                            ProgressView().scaleEffect(0.7).tint(Theme.accent)
                                        }
                                    }
                                }
                                .disabled(isGeneratingCode)
                            }
                        }
                        .padding(14)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    // Participants
                    SettingsSectionView(title: "Participants") {
                        VStack(spacing: 0) {
                            ForEach(Array(displayRoom.participants.enumerated()), id: \.element.id) { index, participant in
                                if index > 0 {
                                    Divider().background(Theme.border).padding(.leading, 48)
                                }
                                HStack(spacing: 12) {
                                    Text(participant.emoji ?? (participant.isAgent ? "🤖" : "👤"))
                                        .font(.system(size: 20))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(participant.displayName)
                                            .font(.system(size: 15))
                                            .foregroundStyle(Theme.textPrimary)
                                        HStack(spacing: 6) {
                                            if participant.isAgent {
                                                Text("agent")
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(Theme.textSecondary)
                                            }
                                            Text(participant.role)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(Theme.textDim)
                                        }
                                    }
                                    Spacer()
                                    if !participant.isAgent && participant.isOnline {
                                        Circle()
                                            .fill(Theme.green)
                                            .frame(width: 8, height: 8)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            }
                        }
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    // Add Agent button
                    Button { showAddAgent = true } label: {
                        HStack {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .medium))
                            Text("Add Agent")
                                .font(.system(size: 15))
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(Theme.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)

                    // Leave room
                    Button {
                        showLeaveConfirm = true
                    } label: {
                        Text("Leave Room")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.danger.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 40)
            }
            .background(Theme.background)
            .navigationBarHidden(true)
            .safeAreaInset(edge: .top) {
                HStack {
                    Color.clear.frame(width: 56, height: 1)
                    Spacer()
                    Text("Room Settings")
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
        }
        .sheet(isPresented: $showAddAgent) {
            AddAgentSheet(roomService: roomService, roomId: displayRoom.id)
        }
        .alert("Leave Room?", isPresented: $showLeaveConfirm) {
            Button("Leave", role: .destructive) {
                Task {
                    await roomService.leaveRoom(displayRoom.id)
                    dismiss()
                    onLeave()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need a new invite code to rejoin.")
        }
        .task {
            roomInfo = await roomService.fetchRoomInfo(displayRoom.id)
        }
        .preferredColorScheme(.dark)
    }
}

private struct SettingsSectionView<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)
                .padding(.horizontal, 4)
            content
        }
        .padding(.horizontal, 16)
    }
}
