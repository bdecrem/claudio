import SwiftUI

struct JoinRoomSheet: View {
    @Environment(\.dismiss) private var dismiss
    let roomService: RoomService

    @State private var inviteCode = ""
    @State private var isJoining = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
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
            .background(Theme.background)
            .navigationTitle("Join Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Join") {
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
                    .foregroundStyle(Theme.accent)
                    .disabled(inviteCode.count < 8 || isJoining)
                }
            }
            .foregroundStyle(Theme.textPrimary)
        }
        .preferredColorScheme(.dark)
    }
}
