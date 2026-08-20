import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var serverManager: ServerManager
    @Environment(\.dismiss) var dismiss

    @AppStorage("openai_api_key") private var apiKey = ""
    @State private var showKey = false

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

                Section {
                    HStack {
                        if showKey {
                            TextField("sk-...", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        } else {
                            SecureField("sk-...", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(action: { showKey.toggle() }) {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if !apiKey.isEmpty {
                        Label("Nyckel angiven", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                    } else {
                        Text("Hämta din nyckel på platform.openai.com")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("OpenAI API-nyckel")
                }

                Section("Om") {
                    LabeledContent("Version", value: "2.0")
                    LabeledContent("Motor",   value: "KB-Whisper (lokalt) + GPT-4o")
                    LabeledContent("Kostnad", value: "Gratis transkribering, GPT-4o för talare & tvätt")
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)
        }
        .frame(width: 420, height: 460)
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
