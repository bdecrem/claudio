import SwiftUI

@main
struct ClaudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showLaunch = true
    @State private var chatService = ChatService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                ChatView(chatService: chatService)

                if showLaunch {
                    LaunchScreen()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.5), value: showLaunch)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showLaunch = false
                }
                ThemeManager.shared.applyTitleBarStyle()
            }
            .onChange(of: NotificationService.shared.pendingAgentId) { _, newValue in
                guard let agentId = newValue else { return }
                // Find the composite ID for this raw agentId
                if let agent = chatService.agents.first(where: { $0.agentId == agentId }) {
                    chatService.selectedAgent = agent.id
                }
                NotificationService.shared.pendingAgentId = nil
            }
            .onChange(of: chatService.selectedAgentId) { _, newValue in
                appDelegate.currentlySelectedAgentId = newValue
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    NotificationService.shared.clearBadge()
                }
            }
        }
        .defaultSize(width: 600, height: 820)
        .windowResizability(.contentSize)
    }
}
