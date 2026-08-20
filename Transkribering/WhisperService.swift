import Foundation
import AVFoundation

// MARK: - WhisperService
// Anropar den lokala Flask-servern (localhost:5000/transcribe) istället för OpenAI API.

class WhisperService: ObservableObject {
    @Published var progress:    Double = 0
    @Published var statusText:  String = ""
    @Published var isRunning:   Bool   = false

    private var currentTask: Task<Void, Never>?

    // MARK: - Avbryt

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isRunning  = false
        progress   = 0
        statusText = ""
    }

    // MARK: - Transkribera

    func transcribe(
        url: URL,
        language: String,
        completion: @escaping (Result<[TranscriptSegment], Error>) -> Void
    ) {
        isRunning = true
        progress  = 0

        currentTask = Task {
            do {
                await setStatus("Förbereder fil…", progress: 0.05)
                let audioURL = try await prepareAudio(url: url)

                await setStatus("Skickar till lokal Whisper-server…", progress: 0.10)
                let segments = try await sendToLocalServer(audioURL: audioURL, language: language)

                await setStatus("Klart!", progress: 1.0)
                await MainActor.run {
                    self.isRunning = false
                    completion(.success(segments))
                }

                if audioURL != url {
                    try? FileManager.default.removeItem(at: audioURL)
                }

            } catch {
                await MainActor.run {
                    self.isRunning = false
                    if Task.isCancelled { return }
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - HTTP-anrop mot localhost

    private func sendToLocalServer(audioURL: URL, language: String) async throws -> [TranscriptSegment] {

        let endpoint = URL(string: "http://127.0.0.1:5000/transcribe")!
        var request  = URLRequest(url: endpoint)
        request.httpMethod      = "POST"
        request.timeoutInterval = 600          // 10 min — långa inspelningar kan ta tid

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        // Bygg multipart-kropp
        let data = try Data(contentsOf: audioURL)
        let ext  = audioURL.pathExtension.lowercased()
        var body = Data()

        // Fil
        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\n"
        body += "Content-Type: audio/\(ext)\r\n\r\n"
        body.append(data)
        body += "\r\n"

        // Språk
        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"language\"\r\n\r\n"
        body += language + "\r\n"

        body += "--\(boundary)--\r\n"
        request.httpBody = body

        // Animera framsteg under väntetiden — ökar långsammare mot 97 % för att
        // inte frysa synbart medan servern jobbar på sista bitar.
        await setStatus("Transkriberar med Whisper (lokal)…", progress: 0.20)
        let progressTask = Task {
            var p = 0.20
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 s
                elapsed += 5
                // Steg krymper ju närmre 97 % vi kommer
                let step = p < 0.70 ? 0.05 : (p < 0.90 ? 0.02 : 0.005)
                p = min(p + step, 0.97)
                let mins = elapsed / 60
                let secs = elapsed % 60
                let timeStr = mins > 0 ? "\(mins) min \(secs) s" : "\(secs) s"
                await setStatus("Transkriberar… \(timeStr) elapsed", progress: p)
            }
        }
        defer { progressTask.cancel() }

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw WhisperError.networkError
        }
        guard http.statusCode == 200 else {
            let msg = String(data: responseData, encoding: .utf8) ?? "Okänt serverfel"
            throw WhisperError.serverError("Serverfel \(http.statusCode): \(msg)")
        }

        let decoded = try JSONDecoder().decode(TranscribeResponse.self, from: responseData)
        return decoded.segments.map {
            TranscriptSegment(
                start:       $0.start,
                end:         $0.end,
                speaker:     $0.speaker,
                speakerName: $0.speakerName,
                text:        $0.text
            )
        }
    }

    // MARK: - Förbered ljudfil (konvertera om nödvändigt)

    private func prepareAudio(url: URL) async throws -> URL {
        let ext       = url.pathExtension.lowercased()
        let supported = ["mp3", "mp4", "m4a", "wav", "ogg", "flac", "webm", "aac"]
        if supported.contains(ext) { return url }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        let asset   = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset,
                                                  presetName: AVAssetExportPresetAppleM4A) else {
            throw WhisperError.conversionFailed
        }
        session.outputURL      = tempURL
        session.outputFileType = .m4a
        await session.export()
        if session.status != .completed { throw WhisperError.conversionFailed }
        return tempURL
    }

    // MARK: - Hjälpare

    private func setStatus(_ text: String, progress: Double) async {
        await MainActor.run {
            self.statusText = text
            self.progress   = progress
        }
    }
}

// MARK: - Svarsmodeller

private struct TranscribeResponse: Decodable {
    let segments: [ServerSegment]
}

private struct ServerSegment: Decodable {
    let start:       Double
    let end:         Double
    let speaker:     String
    let speakerName: String
    let text:        String
}

// MARK: - Fel

enum WhisperError: LocalizedError {
    case networkError
    case conversionFailed
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .networkError:         return "Nätverksfel — kontrollera att servern körs (localhost:5000)."
        case .conversionFailed:     return "Kunde inte konvertera ljudfilen."
        case .serverError(let msg): return msg
        }
    }
}

// MARK: - Data-hjälpare

private func += (lhs: inout Data, rhs: String) {
    if let d = rhs.data(using: .utf8) { lhs.append(d) }
}
