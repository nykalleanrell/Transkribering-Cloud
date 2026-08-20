import Foundation

// MARK: - ServerManager
// Startar och stoppar den lokala Flask-servern i bakgrunden.

class ServerManager: ObservableObject {

    @Published var isRunning  = false
    @Published var isStarting = false
    @Published var errorMessage: String?

    private var serverProcess: Process?
    private var startTask: Task<Void, Never>?

    // MARK: - Sökvägar

    static var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transkribering")
    }

    static var venvPythonPath: String {
        appSupportURL.appendingPathComponent("venv/bin/python3").path
    }

    static var setupMarkerPath: String {
        appSupportURL.appendingPathComponent("venv/.setup_kbwhisper_v2").path
    }

    /// Returnerar true först när setup.sh har kört klart (markörfilen finns)
    static func isSetupComplete() -> Bool {
        FileManager.default.fileExists(atPath: setupMarkerPath)
    }

    // MARK: - Starta

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting   = true
        errorMessage = nil

        startTask = Task { [weak self] in
            await self?.launchServer()
        }
    }

    private func launchServer() async {
        let pythonPath = ServerManager.venvPythonPath

        guard FileManager.default.fileExists(atPath: pythonPath) else {
            await fail("Python-miljön saknas. Kör installation igen.")
            return
        }

        guard let appPyPath = Bundle.main.path(forResource: "app", ofType: "py") else {
            await fail("app.py hittades inte i app-bunten.")
            return
        }

        let venvDir      = ServerManager.appSupportURL.appendingPathComponent("venv").path
        let activatePath = "\(venvDir)/bin/activate"

        // Använd bash + source activate för att garantera att venv-site-packages hittas.
        // `exec python3` ersätter bash-processen med python — terminate() fungerar korrekt.
        let cmd = """
            source "\(activatePath)" && exec python3 "\(appPyPath)"
            """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments     = ["-c", cmd]
        proc.environment   = buildEnvironment()

        // Logga Flask-utmatning till Xcode-konsolen
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                print("[Flask] \(line)", terminator: "")
            }
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isRunning  = false
                self?.isStarting = false
                self?.serverProcess = nil
            }
        }

        do {
            try proc.run()
        } catch {
            await fail("Kunde inte starta servern: \(error.localizedDescription)")
            return
        }

        serverProcess = proc
        await waitUntilReady()
    }

    private func waitUntilReady() async {
        // Vänta max 15 min (1800 × 0,5 s) — large-modellen tar ~1–2 min att ladda in i minnet
        for attempt in 0..<1800 {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0,5 s

            if await pingHealth() {
                await MainActor.run {
                    self.isRunning  = true
                    self.isStarting = false
                    self.errorMessage = nil
                }
                return
            }

            // Visa förfluten tid i UI var 5:e sekund
            if attempt % 10 == 9 {
                let elapsed = (attempt + 1) / 2
                let msg: String
                switch elapsed {
                case ..<30:  msg = "Laddar Whisper large-modell…"
                case ..<120: msg = "Laddar modell i minnet… (\(elapsed)s)"
                default:     msg = "Fortfarande igång… (\(elapsed)s)"
                }
                await MainActor.run { self.errorMessage = msg }
            }
        }

        await fail("Servern svarar inte efter 15 minuter. Starta om appen.")
        serverProcess?.terminate()
    }

    private func pingHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:5000/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Stoppa

    func stop() {
        startTask?.cancel()
        startTask = nil
        serverProcess?.terminate()
        serverProcess = nil
        isRunning  = false
        isStarting = false
    }

    // MARK: - Hjälpare

    private func buildEnvironment() -> [String: String] {
        var env  = ProcessInfo.processInfo.environment
        let bins = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let path = (bins + [(env["PATH"] ?? "")]).joined(separator: ":")
        env["PATH"] = path
        return env
    }

    @MainActor
    private func fail(_ message: String) {
        errorMessage = message
        isStarting   = false
        isRunning    = false
    }
}
