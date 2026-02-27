import SwiftUI

struct RoomListView: View {
    let roomService: RoomService
    @State private var showCreateRoom = false
    @State private var showJoinRoom = false
    @State private var selectedRoom: Room?

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            if !roomService.hasBackend {
                noBackendView
            } else if roomService.rooms.isEmpty {
                emptyView
            } else {
                roomList
            }
        }
        .sheet(isPresented: $showCreateRoom) {
            CreateRoomSheet(roomService: roomService)
        }
        .sheet(isPresented: $showJoinRoom) {
            JoinRoomSheet(roomService: roomService)
        }
        .fullScreenCover(item: $selectedRoom) { room in
            RoomChatView(roomService: roomService, room: room, onDismiss: {
                selectedRoom = nil
            })
            .preferredColorScheme(.dark)
        }
    }

    private var noBackendView: some View {
        VStack(spacing: Theme.spacing * 3) {
            Spacer()
            Text("rooms")
                .font(.system(.largeTitle, design: .rounded, weight: .light))
                .foregroundStyle(Theme.textSecondary.opacity(0.4))
            Text("Add a Claudio backend server\nin Settings to use group rooms.")
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack(spacing: Theme.spacing * 3) {
            Spacer()
            Text("no rooms yet")
                .font(.system(.title3, design: .rounded, weight: .light))
                .foregroundStyle(Theme.textSecondary.opacity(0.4))

            HStack(spacing: 12) {
                Button {
                    showCreateRoom = true
                } label: {
                    Text("Create")
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, Theme.spacing * 3)
                        .padding(.vertical, Theme.spacing * 1.5)
                        .background(Theme.accent, in: Capsule())
                }

                Button {
                    showJoinRoom = true
                } label: {
                    Text("Join")
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, Theme.spacing * 3)
                        .padding(.vertical, Theme.spacing * 1.5)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
            }
            Spacer()
        }
    }

    private var roomList: some View {
        VStack(spacing: 0) {
            // Action buttons
            HStack(spacing: 8) {
                Button {
                    showCreateRoom = true
                } label: {
                    Label("Create", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    showJoinRoom = true
                } label: {
                    Label("Join", systemImage: "link")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(roomService.rooms) { room in
                        Button {
                            selectedRoom = room
                        } label: {
                            RoomRow(room: room)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct RoomRow: View {
    let room: Room

    var body: some View {
        HStack(spacing: 12) {
            // Room emoji/icon
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

                    if let lm = room.lastMessage {
                        Text(relativeTime(lm.createdAt))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
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

                    if room.unreadCount > 0 {
                        Text("\(room.unreadCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Theme.accent, in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func relativeTime(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: dateString) else { return "" }

        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}
