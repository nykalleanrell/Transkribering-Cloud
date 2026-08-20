import SwiftUI

@main
struct TranskriberingsApp: App {
    @StateObject private var authManager   = AuthManager()
    @StateObject private var serverManager = ServerManager()

    var body: some Scene {
        WindowGroup {
            PMRootView()
                .environmentObject(authManager)
                .environmentObject(serverManager)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct PMRootView: View {
    @EnvironmentObject private var authManager:   AuthManager
    @EnvironmentObject private var serverManager: ServerManager

    @State private var setupComplete = ServerManager.isSetupComplete()

    var body: some View {
        if !setupComplete {
            FirstRunView(setupComplete: $setupComplete)
        } else if authManager.isLoggedIn {
            ContentView(showFileSplitter: true)
                .environmentObject(authManager)
                .environment(\.speakerMode, true)
                .onAppear { serverManager.start() }
        } else {
            LoginView()
                .environmentObject(authManager)
        }
    }
}
