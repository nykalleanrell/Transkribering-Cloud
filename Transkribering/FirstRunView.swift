import SwiftUI

// MARK: - FirstRunView
// Visas första gången appen öppnas och installerar Python-paketen.

struct FirstRunView: View {
    @Binding var setupComplete: Bool

    @State private var phase: Phase = .ready
    @State private var progress: Double = 0
    @State private var statusText = ""
    @State private var errorMessage = ""
    @State private var lastLines: [String] = []   // för felsökning


    enum Phase {
        case ready        // Visa "Installera"-knappen
        case installing   // Pågår
        case done         // Klart
        case failed       // Fel
    }

    // MARK: - Kropp

    var body: some View {
        VStack(spacing: 28) {

            // Ikon
            Image(systemName: "cpu.fill")
                .font(.system(size: 56))
                .foregroundStyle(.linearGradient(
                    colors: [Color(red: 0.45, green: 0.55, blue: 0.95),
                             Color(red: 0.25, green: 0.35, blue: 0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))

            // Rubrik
            VStack(spacing: 8) {
                Text("Installerar lokala AI-modeller")
                    .font(.system(size: 22, weight: .bold))
                Text("Det här händer bara en gång.\nAI-modellerna (KB-Whisper Medium, Small + Whisper Medium) laddas ned (~3,5 GB)\noch installeras i bakgrunden.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Tidsinformation
            if phase == .ready {
                infoRow(icon: "clock",     text: "Tar 15–25 minuter beroende på uppkoppling")
                infoRow(icon: "lock.fill", text: "Kräver aldrig OpenAI-nyckel – allt sker lokalt")
                infoRow(icon: "wifi",      text: "Internetåtkomst krävs bara vid installation")
            }

            // Progress
            if phase == .installing {
                VStack(spacing: 10) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 360)

                    Text(statusText.isEmpty ? "Startar…" : statusText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: 360, alignment: .leading)
                }
                .padding(.top, 4)
            }

            // Felmeddelande
            if !errorMessage.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
                .frame(maxWidth: 380)
            }

            // Knappar
            switch phase {
            case .ready:
                Button(action: beginInstallation) {
                    Label("Installera nu", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return)

            case .installing:
                Button("Avbryt") { cancelInstallation() }
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))

            case .failed:
                Button(action: beginInstallation) {
                    Label("Försök igen", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .done:
                EmptyView()
            }
        }
        .padding(44)
        .frame(width: 520, height: phase == .ready ? 420 : 380)
    }

    // MARK: - Hjälpvyer

    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    // MARK: - Installation

    private func beginInstallation() {
        guard let scriptPath = Bundle.main.path(forResource: "setup", ofType: "sh") else {
            errorMessage = "setup.sh hittades inte i app-bunten."
            phase = .failed
            return
        }

        phase        = .installing
        progress     = 0
        statusText   = "Startar…"
        errorMessage = ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments     = [scriptPath]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        // Läs stdout rad för rad
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData, encoding: .utf8) else { return }
            for raw in text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                DispatchQueue.main.async {
                    self.lastLines.append(line)
                    if self.lastLines.count > 30 { self.lastLines.removeFirst() }
                    self.handle(line: line)
                }
            }
        }

        // Fånga stderr separat
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            DispatchQueue.main.async {
                let short = text.components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .prefix(4)
                    .joined(separator: "\n")
                self.lastLines.append("[stderr] " + short)
                if self.lastLines.count > 30 { self.lastLines.removeFirst() }
            }
        }

        proc.terminationHandler = { [self] p in
            // Töm pipe-buffrar innan vi avslutar
            let remaining = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errRemaining = errPipe.fileHandleForReading.readDataToEndOfFile()

            DispatchQueue.main.async {
                // Bearbeta eventuellt kvarvarande stdout
                if let text = String(data: remaining, encoding: .utf8) {
                    for raw in text.components(separatedBy: "\n") {
                        let line = raw.trimmingCharacters(in: .whitespaces)
                        guard !line.isEmpty else { continue }
                        self.handle(line: line)
                    }
                }

                if self.phase == .installing {
                    if p.terminationStatus != 0 {
                        // Visa sista stderr-raden som felmeddelande
                        let errText = String(data: errRemaining, encoding: .utf8) ?? ""
                        let lastErr = errText.components(separatedBy: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                            .suffix(3)
                            .joined(separator: "\n")
                        let debugLog = self.lastLines.suffix(8).joined(separator: "\n")
                        self.errorMessage = lastErr.isEmpty
                            ? "Exit \(p.terminationStatus). Senaste utmatning:\n\(debugLog)"
                            : lastErr
                        self.phase = .failed
                    }
                }
            }
        }

        do {
            try proc.run()
        } catch {
            errorMessage = "Kunde inte köra setup.sh: \(error.localizedDescription)"
            phase = .failed
        }
    }

    private func handle(line: String) {
        if line.hasPrefix("PROGRESS:") {
            // Format: PROGRESS:0.35:Installerar PyTorch...
            let rest  = String(line.dropFirst("PROGRESS:".count))
            let parts = rest.split(separator: ":", maxSplits: 1)
            if let val = Double(parts[0]) {
                progress = val
            }
            if parts.count > 1 {
                statusText = String(parts[1])
            }

        } else if line == "DONE" {
            progress   = 1.0
            statusText = "Klart!"
            phase      = .done
            // Kort fördröjning så "Klart!" syns en sekund
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.setupComplete = true
            }

        } else if line.hasPrefix("ERROR:") {
            errorMessage = String(line.dropFirst("ERROR:".count))
            phase = .failed
        }
    }

    private func cancelInstallation() {
        phase = .ready
        statusText   = ""
        errorMessage = ""
        progress     = 0
    }
}
