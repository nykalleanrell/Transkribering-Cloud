import SwiftUI

@main
struct TranskriberingsApp: App {
    @StateObject private var authManager   = AuthManager()
    @StateObject private var serverManager = ServerManager()
    @State private var setupComplete = ServerManager.isSetupComplete()

    var body: some Scene {
        WindowGroup {
            RootView(setupComplete: $setupComplete)
                .environmentObject(authManager)
                .environmentObject(serverManager)
                .environment(\.speakerMode, false)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - RootView

struct RootView: View {
    @EnvironmentObject private var authManager:   AuthManager
    @EnvironmentObject private var serverManager: ServerManager
    @Binding var setupComplete: Bool

    var body: some View {
        Group {
            if !setupComplete {
                FirstRunView(setupComplete: $setupComplete)
            } else if authManager.isLoggedIn {
                ContentView()
                    .environmentObject(authManager)
                    .environmentObject(serverManager)
                    .overlay(serverStatusBanner, alignment: .bottom)
            } else {
                LoginView()
                    .environmentObject(authManager)
            }
        }
        .onChange(of: setupComplete) { done in
            if done { serverManager.start() }
        }
        .onChange(of: authManager.isLoggedIn) { loggedIn in
            if loggedIn, setupComplete { serverManager.start() }
        }
        .onAppear {
            if setupComplete { serverManager.start() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)
        ) { _ in
            serverManager.stop()
        }
    }

    @ViewBuilder
    private var serverStatusBanner: some View {
        if serverManager.isStarting {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Startar lokal server...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .padding(.bottom, 8)
        }
    }
}
