import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var serverManager: ServerManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inställningar")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Klar") { dismiss() }
                    .keyboardShortcut(.return)
            }
            .padding(20)

            Divider()

            Form {
                Section("Konto") {
                    LabeledContent("Namn",   value: auth.currentUser?.name  ?? "")
                    LabeledContent("E-post", value: auth.currentUser?.email ?? "")
                    Button("Logga ut", role: .destructive) {
                        auth.signOut()
                        dismiss()
                    }
                }

                Section("Lokal server") {
                    serverStatusRow
                    Button("Starta om server") {
                        serverManager.stop()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            serverManager.start()
                        }
                    }
                    .disabled(serverManager.isStarting)
                }

                Section("Om") {
                    LabeledContent("Version", value: "1.0")
                    LabeledContent("Motor",   value: "KB-Whisper (sv) / Whisper Medium (en)")
                    LabeledContent("Kostnad", value: "Gratis – körs lokalt")
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)
        }
        .frame(width: 420, height: 360)
    }

    private var serverStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(serverManager.isRunning  ? Color.green :
                      serverManager.isStarting ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
            Text(serverManager.isRunning  ? "Kör på localhost:5000" :
                 serverManager.isStarting ? "Startar..." : "Stoppad")
                .font(.system(size: 13))
        }
    }
}
