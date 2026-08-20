import SwiftUI

@main
struct TranskriberingsApp: App {
    @StateObject private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            CloudRootView()
                .environmentObject(authManager)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - CloudRootView

struct CloudRootView: View {
    @EnvironmentObject private var authManager: AuthManager

    var body: some View {
        if authManager.isLoggedIn {
            ContentView(retentionDays: 30, showFileSplitter: true)
                .environmentObject(authManager)
        } else {
            LoginView()
                .environmentObject(authManager)
        }
    }
}
