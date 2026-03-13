import SwiftUI

struct JoinRoomSheet: View {
    @Environment(\.dismiss) private var dismiss
    let roomService: RoomService

    enum JoinMode: String, CaseIterable {
        case browse = "Browse"
        case inviteCode = "Invite Code"
    }

    @State private var mode: JoinMode = .browse
    @State private var inviteCode = ""
    @State private var isJoining = false
    @State private var errorMessage: String?

    // Browse state
    @State private var publicRooms: [Room] = []
    @State private var isLoadingPublic = false
    @State private var joiningRoomId: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(JoinMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                switch mode {
                case .browse:
                    browseTab
                case .inviteCode:
                    inviteCodeTab
                }
            }
            .background(Theme.background)
            .navigationTitle("Join Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                if mode == .inviteCode {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Join") {
                            joinWithInviteCode()
                        }
                        .foregroundStyle(Theme.accent)
                        .disabled(inviteCode.count < 8 || isJoining)
                    }
                }
            }
            .foregroundStyle(Theme.textPrimary)
        }
        .preferredColorScheme(Theme.colorScheme)
    }

    // MARK: - Browse Tab

    private var browseTab: some View {
        Group {
            if isLoadingPublic {
                Spacer()
                ProgressView()
                    .tint(Theme.textSecondary)
                Spacer()
            } else if publicRooms.isEmpty {
                Spacer()
                Text("No public rooms available")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textDim)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(publicRooms) { room in
                            publicRoomRow(room)
                        }
                    }
                }
            }
        }
        .task {
            await loadPublicRooms()
        }
    }

    private func publicRoomRow(_ room: Room) -> some View {
        let alreadyJoined = roomService.rooms.contains { $0.id == room.id }
        let isJoiningThis = joiningRoomId == room.id

        return Button {
            guard !alreadyJoined, !isJoiningThis else { return }
            joinPublicRoom(room)
        } label: {
            HStack(spacing: 12) {
                Text(room.emoji ?? "💬")
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(room.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        if alreadyJoined {
                            Text("Joined")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.accent.opacity(0.15), in: Capsule())
                        } else if isJoiningThis {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(Theme.textSecondary)
                        }
                    }

                    HStack {
                        if let lm = room.lastMessage {
                            Text("\(lm.senderName): \(lm.content)")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        } else {
                            Text("\(room.participantCount) participants")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textDim)
                        }

                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Invite Code Tab

    private var inviteCodeTab: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Invite Code")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)

                TextField("", text: $inviteCode, prompt:
                    Text("Enter 8-character code")
                        .foregroundStyle(Theme.textDim)
                )
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onChange(of: inviteCode) { _, newValue in
                    inviteCode = String(newValue.prefix(8)).uppercased()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 16)
            }

            Spacer()
        }
    }

    // MARK: - Actions

    private func loadPublicRooms() async {
        isLoadingPublic = true
        publicRooms = await roomService.fetchPublicRooms()
        isLoadingPublic = false
    }

    private func joinPublicRoom(_ room: Room) {
        joiningRoomId = room.id
        Task {
            if let _ = await roomService.joinPublicRoom(roomId: room.id) {
                dismiss()
            }
            joiningRoomId = nil
        }
    }

    private func joinWithInviteCode() {
        isJoining = true
        errorMessage = nil
        Task {
            if let _ = await roomService.joinRoom(inviteCode: inviteCode) {
                dismiss()
            } else {
                errorMessage = "Invalid or expired invite code."
            }
            isJoining = false
        }
    }
}
