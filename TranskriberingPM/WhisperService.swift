import Foundation
import AVFoundation

// MARK: - WhisperService (PM)
// Steg 1: Lokal Flask-server (KB-Whisper) → råsegment
// Steg 2: GPT-4o talaridentifiering
// Steg 3: GPT-4o språktvättning

class WhisperService: ObservableObject {
    @Published var progress:   Double = 0
    @Published var statusText: String = ""
    @Published var isRunning:  Bool   = false

    private var currentTask: Task<Void, Never>?
    var serverManager: ServerManager?

    private var apiKey: String {
        UserDefaults.standard.string(forKey: "openai_api_key") ?? ""
    }

    private var modelSize: String {
        UserDefaults.standard.string(forKey: "pm_model_size") ?? "small"
    }

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
        speakerCount: Int = 0,
        completion: @escaping (Result<[TranscriptSegment], Error>) -> Void
    ) {
        isRunning = true
        progress  = 0

        currentTask = Task {
            do {
                await setStatus("Förbereder fil…", progress: 0.05)
                let audioURL = try await prepareAudio(url: url)
                defer { if audioURL != url { try? FileManager.default.removeItem(at: audioURL) } }

                await setStatus("Skickar till lokal Whisper-server…", progress: 0.10)
                let raw = try await sendToLocalServer(audioURL: audioURL, language: language)

                await setStatus("Analyserar talare med GPT-4o…", progress: 0.87)
                let assigned = try await assignSpeakersWithGPT(raw, speakerCount: speakerCount)

                await setStatus("Tvättar språket med GPT-4o…", progress: 0.93)
                let polished = try await polishTranscript(assigned)

                await setStatus("Klart!", progress: 1.0)
                await MainActor.run {
                    self.isRunning = false
                    completion(.success(polished))
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Steg 1: Lokal Flask-server

    private func sendToLocalServer(audioURL: URL, language: String) async throws -> [RawSegment] {
        let endpoint = URL(string: "http://127.0.0.1:5000/transcribe")!
        var request  = URLRequest(url: endpoint)
        request.httpMethod      = "POST"
        request.timeoutInterval = 3600   // 60 min — ger utrymme för modelladdning + transkribering

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Läs filen på en bakgrundstråd för att inte blockera Swift concurrency
        let (data, ext): (Data, String) = try await Task.detached(priority: .userInitiated) {
            (try Data(contentsOf: audioURL), audioURL.pathExtension.lowercased())
        }.value
        var body = Data()

        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\n"
        body += "Content-Type: audio/\(ext)\r\n\r\n"
        body.append(data)
        body += "\r\n"

        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"language\"\r\n\r\n"
        body += language + "\r\n"

        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"model_size\"\r\n\r\n"
        body += modelSize + "\r\n"

        body += "--\(boundary)--\r\n"
        request.httpBody = body

        // Progressanimation under transkribering
        let modelLabel = modelSize == "small" ? "Small" : "Medium"
        await setStatus("Transkriberar med KB-Whisper \(modelLabel) (lokal)…", progress: 0.15)
        let progressTask = Task {
            var p = 0.15
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                elapsed += 5
                let step = p < 0.60 ? 0.05 : (p < 0.80 ? 0.02 : 0.005)
                p = min(p + step, 0.84)
                let mins = elapsed / 60
                let secs = elapsed % 60
                let t = mins > 0 ? "\(mins) min \(secs) s" : "\(secs) s"
                await setStatus("Transkriberar… \(t)", progress: p)
            }
        }
        defer { progressTask.cancel() }

        // Kör HTTP-anrop och watchdog parallellt
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { try await URLSession.shared.data(for: request) }
                group.addTask { try await self.watchdog(); throw PMError.serverHung }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch PMError.serverHung, is CancellationError {
            return try await restartAndRetry(request: request)
        } catch let err as URLError where err.code == .timedOut {
            return try await restartAndRetry(request: request)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: responseData, encoding: .utf8) ?? "Okänt serverfel"
            throw PMError.serverError("Lokal server: \(msg)")
        }

        let decoded = try JSONDecoder().decode(LocalResponse.self, from: responseData)
        return decoded.segments.map { RawSegment(start: $0.start, end: $0.end, text: $0.text) }
    }

    // MARK: - Steg 2: GPT-4o talaridentifiering

    private func assignSpeakersWithGPT(_ segments: [RawSegment], speakerCount: Int) async throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }

        let lines = segments.enumerated().map { i, seg in
            let t = Int(seg.start)
            return "[\(i)] \(t/60):\(String(format: "%02d", t%60)) \(seg.text.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n")

        let speakerHint = speakerCount > 0
            ? "Det är exakt \(speakerCount) talare i inspelningen."
            : "Antalet talare är okänt — använd det antal som verkar rimligt."

        let systemPrompt = """
        Du är en expert på talaridentifiering. Givet ett transkript med numrerade segment, tilldela varje segment ett talarnummer (0-baserat).
        \(speakerHint)
        Analysera samtalsdynamiken: vem ställer frågor, vem svarar, ton, ämnesbyten, meningsbyggnad.
        Svara ENBART med ett JSON-objekt där nyckeln är segmentets index (sträng) och värdet är talarnumret (heltal). Exempel: {"0":0,"1":1,"2":0}
        """

        let body: [String: Any] = [
            "model": "gpt-4o",
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": lines]
            ]
        ]

        let text = try await callGPT(body: body, timeout: 120)

        let jsonStr: String
        if let s = text.range(of: "{"), let e = text.range(of: "}", options: .backwards) {
            jsonStr = String(text[s.lowerBound..<e.upperBound])
        } else { jsonStr = text }

        let assignments = (try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Int]) ?? [:]
        let usedSpeakers = Array(Set(assignments.values)).sorted()
        var speakerNames: [Int: String] = [:]
        for (rank, spNum) in usedSpeakers.enumerated() {
            speakerNames[spNum] = "Talare \(rank + 1)"
        }

        return segments.enumerated().map { i, seg in
            let spNum  = assignments["\(i)"] ?? 0
            let spName = speakerNames[spNum] ?? "Talare 1"
            return TranscriptSegment(
                start:       seg.start,
                end:         seg.end,
                speaker:     "speaker_\(spNum)",
                speakerName: spName,
                text:        seg.text.trimmingCharacters(in: .whitespaces)
            )
        }
    }

    // MARK: - Steg 3: GPT-4o språktvättning

    private func polishTranscript(_ segments: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }

        let lines = segments.enumerated().map { i, seg in "[\(i)] \(seg.text)" }.joined(separator: "\n")

        let systemPrompt = """
        Du är en expert på att redigera talspråk till läsbar text på svenska. \
        Du får en numrerad lista med transkriberade segment från ett samtal.
        Din uppgift:
        • Rätta uppenbara transkriptionsfel (förväxlade ord, felstavningar).
        • Ta bort utfyllnadsord och stakningar (öh, eh, liksom, alltså när det används som utfyllnad, mm, hmm).
        • Lägg till punktuation och stor bokstav där det saknas.
        • Behåll talspråklig ton och meningsinnehåll — ändra INTE vad personen faktiskt säger.
        • Slå INTE ihop segment — varje index ska ha exakt ett svar.
        Svara ENBART med ett JSON-objekt: {"0":"polerad text","1":"polerad text",...}
        """

        let body: [String: Any] = [
            "model": "gpt-4o",
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": lines]
            ]
        ]

        let text = try await callGPT(body: body, timeout: 180)

        let jsonStr: String
        if let s = text.range(of: "{"), let e = text.range(of: "}", options: .backwards) {
            jsonStr = String(text[s.lowerBound..<e.upperBound])
        } else { jsonStr = text }

        let polished = (try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: String]) ?? [:]

        return segments.enumerated().map { i, seg in
            var updated = seg
            if let clean = polished["\(i)"], !clean.isEmpty { updated.text = clean }
            return updated
        }
    }

    // MARK: - Watchdog: pingar servern var 30:e sekund, kastar om den slutar svara

    private func watchdog() async throws {
        var failures = 0
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            let ok = await pingHealth()
            if ok { failures = 0 } else { failures += 1 }
            if failures >= 2 { throw PMError.serverHung }
        }
    }

    private func pingHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:5000/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    private func restartAndRetry(request: URLRequest) async throws -> [RawSegment] {
        guard let sm = serverManager else {
            throw PMError.serverError("Servern slutade svara. Starta om den via Inställningar och försök igen.")
        }
        await setStatus("Servern hängde sig — startar om automatiskt…", progress: 0.12)
        await MainActor.run { sm.stop() }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await MainActor.run { sm.start() }
        for _ in 0..<1200 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await MainActor.run(body: { sm.isRunning }) { break }
        }
        guard await MainActor.run(body: { sm.isRunning }) else {
            throw PMError.serverError("Servern kunde inte startas om. Kontrollera Inställningar.")
        }
        await setStatus("Servern omstartad — försöker igen…", progress: 0.14)
        let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
        guard let http = retryResponse as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: retryData, encoding: .utf8) ?? "Okänt serverfel"
            throw PMError.serverError("Lokal server: \(msg)")
        }
        let decoded = try JSONDecoder().decode(LocalResponse.self, from: retryData)
        return decoded.segments.map { RawSegment(start: $0.start, end: $0.end, text: $0.text) }
    }

    // MARK: - Gemensamt GPT-anrop

    private func callGPT(body: [String: Any], timeout: TimeInterval) async throws -> String {
        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request  = URLRequest(url: endpoint)
        request.httpMethod      = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw PMError.serverError("GPT-4o-fel: \(msg)")
        }

        let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        return (content?["content"] as? String) ?? ""
    }

    // MARK: - Förbered ljudfil

    private func prepareAudio(url: URL) async throws -> URL {
        let ext       = url.pathExtension.lowercased()
        let supported = ["mp3", "mp4", "m4a", "wav", "ogg", "flac", "webm", "aac"]
        if supported.contains(ext) { return url }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        let asset   = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw PMError.conversionFailed
        }
        session.outputURL      = tempURL
        session.outputFileType = .m4a
        await session.export()
        if session.status != .completed { throw PMError.conversionFailed }
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

// MARK: - Modeller

private struct RawSegment {
    let start: Double
    let end:   Double
    let text:  String
}

private struct LocalResponse: Decodable {
    let segments: [LocalSegment]
}

private struct LocalSegment: Decodable {
    let start: Double
    let end:   Double
    let text:  String
}

// MARK: - Fel

enum PMError: LocalizedError {
    case conversionFailed
    case serverError(String)
    case serverHung

    var errorDescription: String? {
        switch self {
        case .conversionFailed:     return "Kunde inte konvertera ljudfilen."
        case .serverError(let msg): return msg
        case .serverHung:           return "Servern hängde sig."
        }
    }
}

// MARK: - Data-hjälpare

private func += (lhs: inout Data, rhs: String) {
    if let d = rhs.data(using: .utf8) { lhs.append(d) }
}
