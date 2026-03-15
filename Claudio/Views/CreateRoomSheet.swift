import SwiftUI

struct CreateRoomSheet: View {
    @Environment(\.dismiss) private var dismiss
    let roomService: RoomService

    @State private var name = ""
    @State private var emoji = "💬"
    @State private var isPublic = false
    @State private var isCreating = false

    private let emojiOptions = ["💬", "🚀", "🎯", "🧠", "⚡", "🌊", "🔥", "🎨", "🛠", "🎵"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Emoji picker
                    VStack(spacing: 8) {
                        Text(emoji)
                            .font(.system(size: 56))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(emojiOptions, id: \.self) { e in
                                    Button {
                                        emoji = e
                                    } label: {
                                        Text(e)
                                            .font(.system(size: 24))
                                            .frame(width: 40, height: 40)
                                            .background(
                                                emoji == e ? Theme.accent.opacity(0.2) : Theme.surface,
                                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            )
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 16)

                    // Name field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Room Name")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)

                        TextField("", text: $name, prompt:
                            Text("e.g. Project Alpha")
                                .foregroundStyle(Theme.textDim)
                        )
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .padding(.horizontal, 16)

                    // Public toggle
                    Toggle(isOn: $isPublic) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Public Room")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Anyone can discover and join")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .tint(Theme.accent)
                    .padding(.horizontal, 16)
                }
            }
            .background(Theme.background)
            .navigationTitle("New Room")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .compatLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .compatTrailing) {
                    Button("Create") {
                        isCreating = true
                        Task {
                            if let _ = await roomService.createRoom(name: name, emoji: emoji, isPublic: isPublic) {
                                dismiss()
                            }
                            isCreating = false
                        }
                    }
                    .foregroundStyle(Theme.accent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
            .foregroundStyle(Theme.textPrimary)
        }
        .preferredColorScheme(Theme.colorScheme)
    }
}
