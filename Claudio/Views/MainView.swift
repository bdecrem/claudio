import SwiftUI

enum MainTab: String, CaseIterable {
    case agents = "Agents"
    case rooms = "Rooms"
}

struct MainView: View {
    @State private var selectedTab: MainTab = .agents
    @State private var roomService = RoomService()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Theme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                switch selectedTab {
                case .agents:
                    ChatView(roomService: roomService)
                case .rooms:
                    RoomListView(roomService: roomService)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            tabHeader
        }
        .onAppear {
            if roomService.hasBackend {
                roomService.connect()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var tabHeader: some View {
        HStack(spacing: 0) {
            // Tab picker
            HStack(spacing: 2) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = tab
                        }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(selectedTab == tab ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selectedTab == tab ? Theme.surface2 : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Theme.surface, in: Capsule())

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.background)
    }
}
